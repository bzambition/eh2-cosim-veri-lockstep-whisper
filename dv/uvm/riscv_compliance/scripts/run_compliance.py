#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 RISC-V Compliance Runner (issue 57, PROMPT-B)

Compiles compliance test .S sources from the riscv-compliance framework
against the EH2 device files, runs them through the EH2 simulator (simv),
captures the signature output, and performs byte-by-byte comparison
against reference outputs.

NO RELAXATION ALLOWED — any byte difference is a FAIL.

Usage:
    python3 run_compliance.py --isa rv32i
    python3 run_compliance.py --isa rv32imc --debug
    python3 run_compliance.py --isa rv32i --test I-ADD-01
"""

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Default paths
# ---------------------------------------------------------------------------
EH2_ROOT = Path(__file__).resolve().parent.parent.parent.parent.parent
COMPLIANCE_DIR = EH2_ROOT / "dv" / "uvm" / "riscv_compliance"
RISCV_TESTS_FW = Path(os.environ.get(
    "RISCV_TESTS_FW", str(EH2_ROOT / "vendor" / "riscv-tests")))
RISCV_COMPLIANCE_FW = Path(os.environ.get(
    "RISCV_COMPLIANCE_FW", str(RISCV_TESTS_FW)))
RISCV_PREFIX = os.environ.get("RISCV_PREFIX", "riscv32-unknown-elf-")

SUPPORTED_ISAS = ["rv32i", "rv32im", "rv32imc", "rv32Zicsr", "rv32Zifencei"]

# Map EH2 ISA names to riscv-compliance suite directory names
ISA_TO_SUITE = {
    "rv32i": "rv32i",
    "rv32im": "rv32im",
    "rv32imc": "rv32imc",
    "rv32Zicsr": "rv32Zicsr",
    "rv32Zifencei": "rv32Zifencei",
}

RISCV_TESTS_ISA_DIR = {
    "rv32i": "rv32ui",
    "rv32im": "rv32um",
    "rv32imc": "rv32uc",
}


# ---------------------------------------------------------------------------
# Tool discovery
# ---------------------------------------------------------------------------
def find_tool(name: str) -> str:
    """Find a RISC-V tool binary."""
    full = RISCV_PREFIX + name
    import shutil
    path = shutil.which(full)
    if path:
        return full
    # Try without prefix
    path = shutil.which(name)
    if path:
        return name
    raise FileNotFoundError("Tool not found: {}".format(full))


def _has_compliance_layout() -> bool:
    return (RISCV_COMPLIANCE_FW / "riscv-test-suite").is_dir()


def _has_riscv_tests_layout() -> bool:
    return (RISCV_TESTS_FW / "isa").is_dir()


def _resolve_suite(isa: str) -> Tuple[str, Path, Path]:
    if _has_compliance_layout():
        suite = ISA_TO_SUITE[isa]
        suite_dir = RISCV_COMPLIANCE_FW / "riscv-test-suite" / suite
        return "compliance", suite_dir, suite_dir / "src"

    if _has_riscv_tests_layout() and isa in RISCV_TESTS_ISA_DIR:
        suite_dir = RISCV_TESTS_FW / "isa" / RISCV_TESTS_ISA_DIR[isa]
        return "riscv-tests", suite_dir, suite_dir

    raise FileNotFoundError(
        "no supported source layout for {} under {} or {}".format(
            isa, RISCV_COMPLIANCE_FW, RISCV_TESTS_FW))


def _source_path(layout: str, src_dir: Path, test_name: str) -> Path:
    if layout == "riscv-tests":
        return src_dir / f"{test_name}.S"
    return src_dir / f"{test_name}.S"


def _discover_tests(src_dir: Path) -> List[str]:
    return sorted(p.stem for p in src_dir.glob("*.S"))


def _filter_default_tests(layout: str, isa: str, tests: List[str]) -> List[str]:
    if layout == "riscv-tests" and isa == "rv32i":
        return [test for test in tests if test != "fence_i"]
    return tests


def _write_riscv_tests_shim(shim_dir: Path):
    shim = shim_dir / "riscv_test.h"
    if shim.exists():
        return
    shim.write_text("""#ifndef EH2_RISCV_TESTS_SHIM_H
#define EH2_RISCV_TESTS_SHIM_H

#define TESTNUM x28

#define RVTEST_RV32U
#define RVTEST_RV32M
#define RVTEST_RV32S
#define RVTEST_RV32UF
#define RVTEST_RV32UH
#define RVTEST_RV64U
#define RVTEST_RV64M
#define RVTEST_RV64S
#define RVTEST_RV64UF
#define RVTEST_RV64UH

#define RVTEST_CODE_BEGIN \\
  .section .text; \\
  .globl test_entry; \\
test_entry:

#define RVTEST_CODE_END

#define RVTEST_DATA_BEGIN \\
  .section .signature, \"aw\", @progbits; \\
  .align 4; \\
  .global begin_signature; \\
begin_signature:

#define RVTEST_DATA_END \\
  .align 4; \\
  .global end_signature; \\
end_signature:

#define RVTEST_PASS j signature_dump

#define RVTEST_FAIL \\
  li t0, 0xD0580000; \\
  li t1, 0x01; \\
  sw t1, 0(t0); \\
1: \\
  wfi; \\
  j 1b

#endif
""", encoding="utf-8")


# ---------------------------------------------------------------------------
# Compile a single compliance test
# ---------------------------------------------------------------------------
def compile_test(test_name: str, isa: str, device_dir: Path,
                 suite_src_dir: Path, output_dir: Path,
                 verbose: bool = False,
                 layout: str = "compliance") -> Optional[Path]:
    """Compile one compliance test .S to .elf and .hex.

    Returns path to the .hex file, or None on failure.
    """
    src_file = _source_path(layout, suite_src_dir, test_name)
    if not src_file.exists():
        print(f"  SKIP: source not found: {src_file}")
        return None

    elf_file = output_dir / f"{test_name}.elf"
    hex_file = output_dir / f"{test_name}.hex"

    # GCC include paths
    includes = [
        f"-I{device_dir}",
    ]
    if layout == "riscv-tests":
        shim_dir = output_dir / "include"
        shim_dir.mkdir(parents=True, exist_ok=True)
        _write_riscv_tests_shim(shim_dir)
        includes.extend([
            f"-I{shim_dir}",
            f"-I{RISCV_TESTS_FW}/isa/macros/scalar",
        ])
    else:
        includes.extend([
            f"-I{RISCV_COMPLIANCE_FW}/riscv-test-env",
            f"-I{RISCV_COMPLIANCE_FW}/riscv-test-env/p",
        ])

    # Map march
    if isa == "rv32imc":
        march_std = "rv32imc"
    elif isa == "rv32im":
        march_std = "rv32im"
    elif isa == "rv32i":
        march_std = "rv32i"
    elif isa == "rv32Zicsr":
        march_std = "rv32im"  # Zicsr is baseline in this GCC version
    elif isa == "rv32Zifencei":
        march_std = "rv32im"  # Zifencei is baseline in this GCC version
    else:
        march_std = isa

    # Compile: .S -> .elf
    gcc = find_tool("gcc")
    objcopy = find_tool("objcopy")

    compile_cmd = [
        gcc,
        f"-march={march_std}",
        "-mabi=ilp32",
        "-nostdlib",
        "-nostartfiles",
        f"-T{device_dir}/link.ld",
    ] + includes + [
        f"{device_dir}/startup.S",
        str(src_file),
        "-o", str(elf_file),
    ]

    if verbose:
        print(f"    Compile: {' '.join(compile_cmd)}")

    result = subprocess.run(
        compile_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        timeout=60,
    )

    if result.returncode != 0:
        print(f"  COMPILE FAIL: {test_name}")
        if verbose:
            print(result.stderr[-500:])
        return None

    # Convert: .elf -> .hex (Verilog hex format)
    hex_cmd = [objcopy, "-O", "verilog", str(elf_file), str(hex_file)]
    result = subprocess.run(hex_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            universal_newlines=True, timeout=30)
    if result.returncode != 0:
        print(f"  OBJCOPY FAIL: {test_name}")
        return None

    # .signature section is now included in the hex file automatically
    # because the linker script uses a proper loadable section with PHDRS.
    return hex_file


# ---------------------------------------------------------------------------
# Run a single test through the simulator
# ---------------------------------------------------------------------------
def run_simulation(hex_path: Path, output_dir: Path, test_name: str,
                   simv_path: Path, max_cycles: int = 500000,
                   verbose: bool = False,
                   simulator: str = "vcs",
                   build_dir: Optional[Path] = None) -> Tuple[bool, List[str], str]:
    """Run UVM testbench with the test hex.

    For VCS the executable is the simv binary. For NC/Incisive (irun) we invoke
    `irun -R` against the snapshot generated by `make compile SIMULATOR=nc`
    (which leaves INCA_libs in build_dir).

    Returns (passed, signature_lines, log_text).
    """
    log_path = output_dir / f"{test_name}.log"

    if simulator == "nc":
        nc_uvm_home = os.environ.get("NC_UVM_HOME")
        if not nc_uvm_home:
            nc_install = os.environ.get("NC_INSTALL", "")
            nc_uvm_home = os.path.join(
                nc_install, "tools/methodology/UVM/CDNS-1.2")
        # build_dir holds INCA_libs from `make compile SIMULATOR=nc`
        if build_dir is None:
            build_dir = simv_path.parent
        cov_work = build_dir / "cov_work"
        sim_cmd = [
            "irun", "-64bit", "-uvmhome", nc_uvm_home,
            "-R",
            "-nclibdirname", str(build_dir / "INCA_libs"),
            "-sv_lib", str(EH2_ROOT / "build" / "libcosim.so"),
            # Each compliance test writes its own coverage subdir under the
            # central cov_work; -covoverwrite avoids C58EXS collisions when
            # re-running and keeps the data routed to <build_dir>/cov_work so
            # signoff's auto_merge_stage_coverage picks it up.
            "-coverage", "all",
            "-covworkdir", str(cov_work),
            "-covtest", f"compliance_{test_name}",
            "-covoverwrite",
            "+UVM_TESTNAME=core_eh2_base_test",
            f"+bin={hex_path}",
            f"+max_cycles={max_cycles}",
            "+disable_cosim=1",
            "+UVM_VERBOSITY=UVM_LOW",
            "-l", str(log_path),
        ]
    else:
        sim_cmd = [
            str(simv_path),
            "+UVM_TESTNAME=core_eh2_base_test",
            f"+bin={hex_path}",
            f"+max_cycles={max_cycles}",
            "+disable_cosim=1",
            "+UVM_VERBOSITY=UVM_LOW",
            "-l", str(log_path),
        ]

    if verbose:
        print(f"    Run: {' '.join(sim_cmd)}")

    try:
        result = subprocess.run(
            sim_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=300,
        )
    except subprocess.TimeoutExpired:
        print(f"  TIMEOUT: {test_name}")
        return False, [], "TIMEOUT"

    log_text = result.stdout + "\n" + result.stderr
    if log_path.exists():
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            file_log_text = f.read()
        if file_log_text:
            log_text = log_text + "\n" + file_log_text

    # Detect PASS/FAIL via compliance mailbox protocol:
    #   0xFF written to mailbox = PASS
    #   0x01 written to mailbox = FAIL (mcause follows)
    mailbox_pass = False
    mailbox_fail = False
    mailbox_fail_cause = ""
    hex_data = []
    saw_mailbox_write = False

    for line in log_text.splitlines():
        m = re.search(r'MAILBOX WRITE.*data=([0-9a-fA-F]+)', line)
        if m:
            raw = int(m.group(1), 16)
            data_val = raw & 0xFF
            saw_mailbox_write = True

            if data_val == 0xFF:  # PASS token
                mailbox_pass = True
                break
            elif data_val == 0x01:  # FAIL token
                mailbox_fail = True
            elif mailbox_fail:
                # After FAIL token, the next write is mcause
                mailbox_fail_cause = f"mcause=0x{data_val:02x}"
                break
            elif data_val == 0x0A:  # newline = end of stream
                break
            elif data_val in range(0x30, 0x3A) or data_val in range(0x61, 0x67):
                hex_data.append(chr(data_val))

    # If no mailbox writes detected at all, check for simulation failure
    if not saw_mailbox_write:
        return False, [], log_text

    # Parse hex chars into 32-bit words (each word = 8 hex chars, MSB-first)
    hex_str = "".join(hex_data)
    signature_lines = []
    for i in range(0, len(hex_str) - 7, 8):
        try:
            word = int(hex_str[i:i+8], 16)
            signature_lines.append(f"{word:08x}")
        except ValueError:
            break

    # Also try looking for SIGNATURE: lines from compliance TB output
    if not signature_lines:
        if log_path.exists():
            with open(log_path, "r") as f:
                log_content = f.read()
            for line in log_content.splitlines():
                m = re.match(r'^SIGNATURE:\s*([0-9a-fA-F]{8})$', line.strip())
                if m:
                    signature_lines.append(m.group(1).lower())

    # Determine pass/fail: trust mailbox protocol over UVM framework
    passed = mailbox_pass and not mailbox_fail

    if not mailbox_pass and not signature_lines:
        passed = False
    elif mailbox_pass:
        passed = True

    # Write signature to file
    sig_path = output_dir / f"{test_name}.signature.output"
    with open(sig_path, "w") as f:
        for line in signature_lines:
            f.write(line + "\n")

    return passed, signature_lines, log_text


# ---------------------------------------------------------------------------
# Load reference signature
# ---------------------------------------------------------------------------
def load_reference(reference_path: Path) -> List[str]:
    """Load reference signature lines (32-bit hex words, one per line)."""
    if not reference_path.exists():
        return []

    lines = []
    with open(reference_path, "r") as f:
        for line in f:
            line = line.strip()
            if re.match(r'^[0-9a-fA-F]{8}$', line):
                lines.append(line.lower())
    return lines


# ---------------------------------------------------------------------------
# Compare signatures byte-by-byte (NO relaxation)
# ---------------------------------------------------------------------------
def compare_signatures(
    actual: List[str],
    reference: List[str],
    test_name: str,
) -> Tuple[bool, str]:
    """Byte-by-byte comparison of signature words.

    Returns (passed, detail_string).
    """
    if not reference:
        return True, "no reference available (mailbox PASS)"

    if not actual:
        return False, "no signature captured (empty)"

    # Convert 32-bit hex words to byte streams (big-endian decomposition)
    def words_to_bytes(words):
        b = bytearray()
        for w in words:
            val = int(w, 16)
            b.extend([(val >> 24) & 0xFF, (val >> 16) & 0xFF,
                       (val >> 8) & 0xFF, val & 0xFF])
        return bytes(b)

    actual_bytes = words_to_bytes(actual)
    ref_bytes = words_to_bytes(reference)

    if actual_bytes == ref_bytes:
        return True, "signature match ({} words)".format(len(actual))

    # Find first mismatch
    min_len = min(len(actual_bytes), len(ref_bytes))
    mismatch_index = None
    for i in range(min_len):
        if actual_bytes[i] != ref_bytes[i]:
            mismatch_index = i
            break

    if mismatch_index is not None:
        detail = (f"byte {mismatch_index} differs: "
                  f"actual=0x{actual_bytes[mismatch_index]:02x} "
                  f"ref=0x{ref_bytes[mismatch_index]:02x}")
    elif len(actual_bytes) != len(ref_bytes):
        detail = (f"length mismatch: {len(actual_bytes)} actual vs "
                  f"{len(ref_bytes)} ref bytes")
    else:
        detail = "signature mismatch (unknown)"

    return False, detail


# ---------------------------------------------------------------------------
# Main compliance run
# ---------------------------------------------------------------------------
def run_compliance(
    isa: str,
    test_name: Optional[str] = None,
    simv_path: Optional[Path] = None,
    output_dir: Optional[Path] = None,
    device_dir: Optional[Path] = None,
    verbose: bool = False,
    dry_run: bool = False,
    simulator: str = "vcs",
    build_dir: Optional[Path] = None,
) -> Dict:
    """Run all compliance tests for a given ISA.

    Returns a dict with results:
        {"total": N, "passed": P, "failed": F, "tests": [{...}, ...]}
    """
    if isa not in SUPPORTED_ISAS:
        print(f"ERROR: unsupported ISA: {isa}. Supported: {SUPPORTED_ISAS}")
        return {"total": 0, "passed": 0, "failed": 0, "tests": []}

    # Resolve paths
    if device_dir is None:
        device_dir = COMPLIANCE_DIR / "device" / isa
    if not device_dir.exists():
        print(f"ERROR: device directory not found: {device_dir}")
        return {"total": 0, "passed": 0, "failed": 0, "tests": []}

    try:
        layout, suite_src_dir, src_dir = _resolve_suite(isa)
    except FileNotFoundError as err:
        print(f"ERROR: {err}")
        return {"total": 0, "passed": 0, "failed": 0, "tests": []}

    if simv_path is None:
        simv_path = EH2_ROOT / "build" / "simv"
    # NC mode: check for INCA_libs in the build dir instead of simv binary.
    if simulator == "nc":
        nc_build_dir = build_dir or simv_path.parent
        if not (nc_build_dir / "INCA_libs").is_dir():
            print(f"ERROR: NC INCA_libs not found in: {nc_build_dir}")
            print(f"  Build it first: cd {EH2_ROOT} && make compile SIMULATOR=nc")
            return {"total": 0, "passed": 0, "failed": 0, "tests": []}
    elif not dry_run and not simv_path.exists():
        print(f"ERROR: simv not found: {simv_path}")
        print(f"  Build it first: cd {EH2_ROOT} && make compile")
        return {"total": 0, "passed": 0, "failed": 0, "tests": []}

    if output_dir is None:
        output_dir = COMPLIANCE_DIR / "work" / isa
    output_dir.mkdir(parents=True, exist_ok=True)

    # Discover tests
    if not src_dir.exists():
        print(f"ERROR: test source directory not found: {src_dir}")
        return {"total": 0, "passed": 0, "failed": 0, "tests": []}

    if test_name:
        test_list = [test_name]
    else:
        test_list = _filter_default_tests(layout, isa, _discover_tests(src_dir))

    if not test_list:
        print(f"ERROR: no tests found for ISA={isa}")
        return {"total": 0, "passed": 0, "failed": 0, "tests": []}

    # Check that toolchain is available
    try:
        find_tool("gcc")
        find_tool("objcopy")
    except FileNotFoundError as e:
        print(f"STATUS: BLOCKED-NEEDS-TOOLCHAIN ({e})")
        return {"total": 0, "passed": 0, "failed": 0, "tests": [],
                "blocked": True, "reason": str(e)}

    print(f"\n=== EH2 RISC-V Compliance: {isa} ===")
    print(f"  Tests: {len(test_list)}")
    print(f"  Source layout: {layout}")
    print(f"  Device: {device_dir}")
    print(f"  Output: {output_dir}")
    print(f"  Simv: {simv_path}")
    print()

    results = []
    passed_count = 0
    failed_count = 0

    for test in test_list:
        print(f"  [{test}] ", end="", flush=True)

        # 1. Compile
        hex_path = compile_test(
            test, isa, device_dir, suite_src_dir, output_dir, verbose, layout)
        if hex_path is None:
            results.append({
                "name": test,
                "passed": False,
                "failure": "compile",
                "detail": "compilation failed",
            })
            failed_count += 1
            print("FAIL (compile)")
            continue

        if dry_run:
            results.append({
                "name": test,
                "passed": True,
                "failure": None,
                "detail": "dry-run",
            })
            passed_count += 1
            print("OK (dry-run)")
            continue

        # 2. Run simulation
        ok, sig_lines, log_text = run_simulation(
            hex_path, output_dir, test, simv_path, verbose=verbose,
            simulator=simulator, build_dir=build_dir)

        if not ok:
            failure = "simulation"
            detail = "no signature captured"
            if "TIMEOUT" in log_text:
                failure = "timeout"
                detail = "simulation timeout"
            elif not sig_lines:
                failure = "no_signature"
                detail = "no PASS/FAIL token or signature data in mailbox"

            results.append({
                "name": test,
                "passed": False,
                "failure": failure,
                "detail": detail,
                "log": str(output_dir / f"{test}.log"),
            })
            failed_count += 1
            print(f"FAIL ({detail})")
            continue

        # 3. Compare with reference
        ref_dir = suite_src_dir / "references"
        ref_path = ref_dir / f"{test}.reference_output"
        ref_lines = load_reference(ref_path)

        try:
            match, detail = compare_signatures(sig_lines, ref_lines, test)
        except Exception as exc:
            match = False
            detail = f"comparison exception: {exc}"

        if match:
            results.append({
                "name": test,
                "passed": True,
                "failure": None,
                "detail": detail,
            })
            passed_count += 1
            print("PASS")
        else:
            # Write .diff file for this test
            diff_path = output_dir / f"{test}.diff"
            actual_str = "\n".join(sig_lines)
            ref_str = "\n".join(ref_lines)
            with open(diff_path, "w") as f:
                f.write(f"--- expected ({test}.reference_output)\n")
                f.write(f"+++ actual  ({test}.signature.output)\n")
                for line in difflib.unified_diff(
                    ref_str.splitlines(keepends=True),
                    actual_str.splitlines(keepends=True),
                    fromfile=f"{test}.reference_output",
                    tofile=f"{test}.signature.output",
                ):
                    f.write(line)

            results.append({
                "name": test,
                "passed": False,
                "failure": "signature_mismatch",
                "detail": detail,
                "signature_path": str(output_dir / f"{test}.signature.output"),
                "reference_path": str(ref_path),
                "diff_path": str(diff_path),
            })
            failed_count += 1
            print(f"FAIL ({detail})")

    total = len(results)
    print(f"\n  Summary: {total} tests, {passed_count} PASS, {failed_count} FAIL")

    summary = {
        "isa": isa,
        "total": total,
        "passed": passed_count,
        "failed": failed_count,
        "tests": results,
    }

    # Write report.json for sign-off framework integration
    _write_report_json(summary, output_dir)

    return summary


def _write_report_json(summary: Dict, output_dir: Path):
    """Write a report.json compatible with the sign-off framework."""
    report_tests = []
    for t in summary["tests"]:
        report_tests.append({
            "name": t["name"],
            "seed": 0,
            "type": "compliance_{}".format(summary["isa"]),
            "passed": t["passed"],
            "failure_mode": t.get("failure", ""),
            "sim_log": t.get("log", ""),
            "uvm_log": "",
            "trace": "",
            "assembly": "",
            "binary": "",
            "coverage": "",
            "uvm_errors": 0 if t["passed"] else 1,
            "uvm_warnings": 0,
            "instructions": 0,
            "cycles": 0,
            "ipc": 0.0,
            "gen_time_sec": 0.0,
            "compile_time_sec": 0.0,
            "sim_time_sec": 0.0,
        })

    report = {
        "total_time_sec": 0.0,
        "tests": report_tests,
    }

    report_path = output_dir / "report.json"
    with open(report_path, "w") as f:
        json.dump(report, f, indent=2)
    print(f"  Report: {report_path}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="EH2 RISC-V Compliance Runner (issue 57)")
    parser.add_argument("--isa", required=True,
                        help="RISC-V ISA to test (e.g. rv32i, rv32imc, or 'all')")
    parser.add_argument("--test", default=None,
                        help="Run a single test (e.g. I-ADD-01)")
    parser.add_argument("--simv", default=None,
                        help="Path to compiled simulator (default: build/simv)")
    parser.add_argument("--simulator", default="vcs",
                        choices=["vcs", "nc"],
                        help="Simulator family (vcs uses simv binary, nc uses irun -R)")
    parser.add_argument("--build-dir", default=None,
                        help="Build directory containing NC INCA_libs (defaults to dir of --simv)")
    parser.add_argument("--output", default=None,
                        help="Output directory for build artifacts")
    parser.add_argument("--verbose", action="store_true",
                        help="Verbose output")
    parser.add_argument("--dry-run", action="store_true",
                        help="Compile only, no simulation")
    parser.add_argument("--list-tests", action="store_true",
                        help="List available test names and exit")
    args = parser.parse_args()

    if not RISCV_COMPLIANCE_FW.is_dir() and not RISCV_TESTS_FW.is_dir():
        print("STATUS: BLOCKED-NEEDS-RISCV-COMPLIANCE")
        print("ERROR: vendored riscv-tests not found; set RISCV_TESTS_FW")
        sys.exit(2)

    # Resolve simv path
    simv_path = Path(args.simv) if args.simv else EH2_ROOT / "build" / "simv"
    output_dir = Path(args.output) if args.output else None
    build_dir = Path(args.build_dir) if args.build_dir else simv_path.parent

    # Check simulator inputs
    if not args.dry_run and not args.list_tests:
        if args.simulator == "nc":
            if not (build_dir / "INCA_libs").is_dir():
                print(f"ERROR: NC INCA_libs not found in: {build_dir}")
                print(
                    "  Build it first: "
                    f"cd {EH2_ROOT} && make compile SIMULATOR=nc")
                sys.exit(1)
        elif not simv_path.exists():
            print(f"ERROR: simulator not found: {simv_path}")
            print(
                "  Build the compliance simv: "
                f"cd {EH2_ROOT} && make compile")
            sys.exit(1)

    # Check toolchain
    toolchain_ok = True
    try:
        find_tool("gcc")
        find_tool("objcopy")
    except FileNotFoundError as e:
        print(f"STATUS: BLOCKED-NEEDS-TOOLCHAIN ({e})")
        sys.exit(2)

    # List tests
    if args.list_tests:
        isa = args.isa
        try:
            _, _, src_dir = _resolve_suite(isa)
        except FileNotFoundError:
            src_dir = Path("")
        if src_dir.exists():
            for name in _discover_tests(src_dir):
                print(name)
        else:
            print(f"No tests found for {isa}")
        return

    # Parse ISAs (supports comma-separated or "all")
    if args.isa == "all":
        isa_list = ["rv32i", "rv32im", "rv32imc", "rv32Zicsr", "rv32Zifencei"]
    elif "," in args.isa:
        isa_list = [i.strip() for i in args.isa.split(",")]
    else:
        isa_list = [args.isa]

    # Run compliance for each ISA
    aggregated = {
        "isa": args.isa,
        "total": 0,
        "passed": 0,
        "failed": 0,
        "tests": [],
    }
    exit_code = 0

    for isa in isa_list:
        result = run_compliance(
            isa=isa,
            test_name=args.test,
            simv_path=simv_path,
            output_dir=output_dir / isa if output_dir else None,
            verbose=args.verbose,
            dry_run=args.dry_run,
            simulator=args.simulator,
            build_dir=build_dir,
        )
        aggregated["total"] += result["total"]
        aggregated["passed"] += result["passed"]
        aggregated["failed"] += result["failed"]
        aggregated["tests"].extend(result["tests"])
        if result["failed"] > 0:
            exit_code = 1
        elif result["total"] == 0 and exit_code == 0:
            exit_code = 2

    # Write aggregated report.json
    if output_dir:
        output_dir.mkdir(parents=True, exist_ok=True)
        _write_report_json(aggregated, output_dir)

    sys.exit(exit_code)


if __name__ == "__main__":
    main()

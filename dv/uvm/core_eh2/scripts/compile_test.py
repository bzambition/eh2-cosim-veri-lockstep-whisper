#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 Test Compilation Script

Compiles RISC-V assembly programs to binary for RTL simulation.
Supports both riscv-dv generated tests and directed tests.
"""

import argparse
import contextlib
import os
import sys
import subprocess
import re
from pathlib import Path

from metadata import RegressionMetadata, TestRunResult
from test_entry import read_test_dot_seed
import directed_test_schema


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DV_DIR = os.path.dirname(SCRIPT_DIR)
EH2_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(DV_DIR)))
EXT_DIR = os.path.join(DV_DIR, "riscv_dv_extension")


def find_generated_asm(work_dir: str, test_name: str) -> str:
    """Find riscv-dv generated assembly for an Ibex-style test.seed run."""
    candidates = [
        os.path.join(work_dir, "asm_test", f"{test_name}_0.S"),
        os.path.join(work_dir, f"{test_name}_0.S"),
        os.path.join(work_dir, "test.S"),
    ]
    for path in candidates:
        if os.path.exists(path):
            return path

    for root, _, files in os.walk(work_dir):
        for filename in sorted(files):
            if filename.endswith(".S"):
                return os.path.join(root, filename)
    raise FileNotFoundError(f"No assembly found for {test_name} in {work_dir}")


def directed_testlists(md: RegressionMetadata):
    """Return directed testlists known to metadata, preserving priority."""
    paths = []
    for candidate in [md.directed_test_data,
                      getattr(md, "cosim_test_data", "")]:
        if not candidate:
            continue
        path = Path(candidate)
        if path.exists() and path not in paths:
            paths.append(path)
    return paths


def directed_entry(md: RegressionMetadata, test_name: str):
    """Return directed schema entry for a test name."""
    for testlist in directed_testlists(md):
        model = directed_test_schema.import_model(testlist)
        for test in model.tests:
            if test.test == test_name:
                return test
    return None


def metadata_test_type(md: RegressionMetadata, test_name: str) -> str:
    for name, _, test_type in getattr(md, "tests_and_counts", []):
        if name == test_name:
            return test_type
    return getattr(md, "test_type", "RISCVDV") or "RISCVDV"


def save_compile_failure(md: RegressionMetadata, test_name: str, seed: int,
                         test_dir: Path, log_path: Path,
                         asm_path: Path = None):
    result = TestRunResult()
    result.test_name = test_name
    result.seed = seed
    result.test_type = metadata_test_type(md, test_name)
    result.failure_mode = "COMPILE_ERROR"
    result.sim_log_path = str(log_path)
    if asm_path is not None:
        result.assembly_path = str(asm_path)
    result.binary_path = str(test_dir / "test.hex")
    result.save(str(test_dir / "result"))
    (test_dir / "trr.yaml").write_text(
        "test: {}\nseed: {}\ntype: {}\npassed: False\n"
        "failure_mode: COMPILE_ERROR\nsim_log: {}\n".format(
            test_name, seed, result.test_type, log_path),
        encoding="utf-8")


def compile_from_metadata(dir_metadata: str, test_dot_seed: str) -> bool:
    """Compile one test.seed using Ibex-style metadata."""
    md = RegressionMetadata.construct_from_metadata_dir(Path(dir_metadata))
    test_name, seed = read_test_dot_seed(test_dot_seed)
    test_dir = Path(md.dir_tests) / test_dot_seed
    test_dir.mkdir(parents=True, exist_ok=True)

    entry = directed_entry(md, test_name)
    include_dirs = []
    if entry is not None:
        asm_path = Path(md.eh2_root) / "dv" / "uvm" / "core_eh2" / entry.test_srcs
        generated_asm = test_dir / "test.S"
        if not generated_asm.exists():
            generated_asm.write_text(
                Path(asm_path).read_text(encoding="utf-8"),
                encoding="utf-8")
        linker = entry.ld_script or ""
        if linker and not os.path.isabs(linker):
            linker = str(Path(md.eh2_root) / "dv" / "uvm" / "core_eh2" / linker)
        if entry.includes:
            include_path = entry.includes
            if not os.path.isabs(include_path):
                include_path = str(Path(md.eh2_root) / "dv" / "uvm" /
                                   "core_eh2" / include_path)
            include_dirs.append(include_path)
    else:
        asm_path = Path(find_generated_asm(str(test_dir), test_name))
        linker = str(Path(SCRIPT_DIR) / "link.ld")
        if not os.path.exists(linker):
            create_default_linker_script(linker)

    bin_path = test_dir / "test.bin"
    hex_path = test_dir / "test.hex"
    compile_log = test_dir / "compile.log"
    with compile_log.open("w", encoding="utf-8") as log_fd:
        with contextlib.redirect_stdout(log_fd), \
                contextlib.redirect_stderr(log_fd):
            success = compile_assembly(
                str(asm_path), str(bin_path), linker,
                include_dirs=include_dirs,
                riscv_dv_dir=str(Path(md.eh2_root) / "vendor" /
                                 "google_riscv-dv"),
                hex_path=str(hex_path))

    if not success:
        save_compile_failure(md, test_name, seed, test_dir, compile_log,
                             Path(asm_path))
    return success


def _append_existing_dir(paths: list, path: str):
    """Append an existing directory once, preserving caller order."""
    if not path:
        return
    real_path = os.path.realpath(path)
    if os.path.isdir(real_path) and real_path not in paths:
        paths.append(real_path)


def _looks_like_riscv_dv_dir(path: str) -> bool:
    """Return true when path can provide riscv-dv generated ASM includes."""
    return (
        os.path.exists(os.path.join(path, "run.py")) or
        os.path.exists(os.path.join(path, "user_extension", "user_define.h")) or
        os.path.exists(os.path.join(path, "user_extension", "user_init.s"))
    )


def resolve_riscv_dv_dir(riscv_dv_dir: str = "") -> str:
    """Resolve the riscv-dv root used for assembly include files."""
    candidates = [
        riscv_dv_dir,
        os.environ.get("RISCV_DV_DIR", ""),
        os.path.join(EH2_ROOT, "vendor", "google_riscv-dv"),
    ]
    for candidate in candidates:
        if candidate and _looks_like_riscv_dv_dir(candidate):
            return os.path.realpath(candidate)
    return ""


def default_include_dirs(riscv_dv_dir: str = "") -> list:
    """Return include dirs needed by riscv-dv generated assembly."""
    include_dirs = []
    resolved_riscv_dv_dir = resolve_riscv_dv_dir(riscv_dv_dir)
    if resolved_riscv_dv_dir:
        _append_existing_dir(
            include_dirs, os.path.join(resolved_riscv_dv_dir, "user_extension"))
    _append_existing_dir(include_dirs, EXT_DIR)
    return include_dirs


def _parse_objdump_sections(objdump_text: str) -> list:
    """Parse loadable section metadata from `objdump -h` output."""
    sections = []
    current = None
    section_re = re.compile(
        r"^\s*\d+\s+(\S+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+"
        r"([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+")

    for line in objdump_text.splitlines():
        match = section_re.match(line)
        if match:
            current = {
                "name": match.group(1),
                "size": int(match.group(2), 16),
                "vma": int(match.group(3), 16),
                "file_off": int(match.group(5), 16),
                "flags": "",
            }
            sections.append(current)
            continue
        if current is not None and line.strip():
            current["flags"] = line.strip()
            current = None

    return [
        section for section in sections
        if section["size"] > 0 and
        "CONTENTS" in section["flags"] and
        "ALLOC" in section["flags"] and
        "LOAD" in section["flags"]
    ]


def write_vma_hex_from_elf(elf_path: str, hex_path: str,
                           gcc_prefix: str = "riscv32-unknown-elf") -> bool:
    """Write a byte-addressed verilog hex file using section VMAs."""
    objdump = f"{gcc_prefix}-objdump"
    result = subprocess.run(
        [objdump, "-h", elf_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30
    )
    if result.returncode != 0:
        output = result.stdout.decode("utf-8", errors="replace")
        print(f"objdump failed:\n{output}")
        return False

    sections = _parse_objdump_sections(
        result.stdout.decode("utf-8", errors="replace"))
    if not sections:
        print("Error: ELF has no loadable sections for hex generation")
        return False

    with open(elf_path, "rb") as elf_fd:
        elf_data = elf_fd.read()

    hex_dir = os.path.dirname(hex_path)
    if hex_dir:
        os.makedirs(hex_dir, exist_ok=True)

    with open(hex_path, "w") as hex_fd:
        for section in sections:
            start = section["file_off"]
            end = start + section["size"]
            if end > len(elf_data):
                print(f"Error: Section {section['name']} extends past EOF")
                return False
            data = elf_data[start:end]
            hex_fd.write("@%08X\n" % section["vma"])
            for offset in range(0, len(data), 16):
                hex_fd.write(" ".join("%02X" % byte
                                      for byte in data[offset:offset + 16]))
                hex_fd.write("\n")

    return True


def compile_assembly(asm_path: str, bin_path: str, linker_script: str,
                     gcc_prefix: str = "riscv32-unknown-elf",
                     include_dirs: list = None,
                     riscv_dv_dir: str = "",
                     hex_path: str = "") -> bool:
    """
    Compile RISC-V assembly to binary.

    Args:
        asm_path: Path to assembly file
        bin_path: Output binary path
        linker_script: Linker script path
        gcc_prefix: GCC toolchain prefix

    Returns:
        True if successful
    """
    bin_dir = os.path.dirname(bin_path)
    if bin_dir:
        os.makedirs(bin_dir, exist_ok=True)

    gcc = f"{gcc_prefix}-gcc"
    objcopy = f"{gcc_prefix}-objcopy"

    # Object file path
    obj_path = bin_path.replace(".bin", ".o")
    elf_path = bin_path.replace(".bin", ".elf")
    del obj_path

    compile_include_dirs = default_include_dirs(riscv_dv_dir)
    for include_dir in include_dirs or []:
        _append_existing_dir(compile_include_dirs, include_dir)
    include_opts = [f"-I{include_dir}" for include_dir in compile_include_dirs]

    # Compile assembly to object
    # rv32imac base + zba/zbb bitmanip subsets supported by host gcc 11.1.
    # zbc/zbs need gcc 12+; re-add when the toolchain is upgraded.
    compile_cmd = [
        gcc,
        "-march=rv32imac_zba_zbb",
        "-mabi=ilp32",
        "-static",
        "-mcmodel=medany",
        "-fvisibility=hidden",
        "-nostdlib",
        "-nostartfiles",
        *include_opts,
        "-T", linker_script,
        "-o", elf_path,
        asm_path,
    ]

    print(f"Compiling: {os.path.basename(asm_path)}")

    try:
        result = subprocess.run(
            compile_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60
        )

        if result.returncode != 0:
            output = result.stdout.decode("utf-8", errors="replace")
            print(f"Compilation failed:\n{output}")
            return False

        # Convert ELF to binary
        objcopy_cmd = [
            objcopy,
            "-O", "binary",
            elf_path,
            bin_path,
        ]

        result = subprocess.run(
            objcopy_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30
        )

        if result.returncode != 0:
            output = result.stdout.decode("utf-8", errors="replace")
            print(f"objcopy failed:\n{output}")
            return False

        if hex_path:
            if not write_vma_hex_from_elf(elf_path, hex_path, gcc_prefix):
                return False
            if not os.path.exists(hex_path) or os.path.getsize(hex_path) == 0:
                print("Error: Hex file is empty or missing")
                return False

        # Verify binary exists and has content
        if not os.path.exists(bin_path) or os.path.getsize(bin_path) == 0:
            print(f"Error: Binary file is empty or missing")
            return False

        print(f"Compiled: {bin_path} ({os.path.getsize(bin_path)} bytes)")
        if hex_path:
            print(f"Generated hex: {hex_path} ({os.path.getsize(hex_path)} bytes)")
        return True

    except subprocess.TimeoutExpired:
        print("Compilation timed out")
        return False
    except Exception as e:
        print(f"Compilation error: {e}")
        return False


def create_default_linker_script(path: str):
    """Create a default linker script for EH2 boot address."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("""
OUTPUT_FORMAT("elf32-littleriscv", "elf32-littleriscv", "elf32-littleriscv")
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    FLASH (rxai!w) : ORIGIN = 0x80000000, LENGTH = 64M
    RAM   (wxa!ri)  : ORIGIN = 0x81000000, LENGTH = 16M
}

PHDRS
{
    flash PT_LOAD;
    ram_init PT_LOAD;
}

SECTIONS
{
    .text.init ORIGIN(FLASH) : {
        *(.text.init)
    } > FLASH AT> FLASH : flash

    .text : ALIGN(16) {
        *(.text)
        *(.text.*)
    } > FLASH AT> FLASH : flash

    .data : ALIGN(16) {
        *(.data)
        *(.data.*)
    } > RAM AT> FLASH : ram_init

    .bss : ALIGN(16) {
        *(.bss)
        *(.bss.*)
        *(COMMON)
    } > RAM

    .tohost ALIGN(64) : {
        *(.tohost)
    } > RAM

    .signature ALIGN(64) : {
        *(.signature)
    } > RAM
}
""")


def main():
    parser = argparse.ArgumentParser(description="Compile RISC-V assembly to binary")
    parser.add_argument("--asm", default="", help="Assembly file path")
    parser.add_argument("--bin", default="", help="Output binary path")
    parser.add_argument("--hex", default="", help="Output VMA-addressed hex path")
    parser.add_argument("--linker", default="", help="Linker script")
    parser.add_argument("--gcc-prefix", default="riscv32-unknown-elf",
                        help="GCC toolchain prefix")
    parser.add_argument("--riscv-dv-dir", default="",
                        help="riscv-dv root used for generated assembly includes")
    parser.add_argument("--include-dir", action="append", default=[],
                        help="Additional assembly include directory")
    parser.add_argument("--dir-metadata", default="",
                        help="Ibex-style metadata directory")
    parser.add_argument("--test-dot-seed", default="",
                        help="Ibex-style TEST.SEED selector")
    args = parser.parse_args()

    if args.dir_metadata:
        if not args.test_dot_seed:
            parser.error("--test-dot-seed is required with --dir-metadata")
        success = compile_from_metadata(args.dir_metadata, args.test_dot_seed)
        # Ibex-style staged regressions should continue to collect all
        # per-test failures. compile_from_metadata records COMPILE_ERROR.
        sys.exit(0)

    if not args.asm or not args.bin:
        parser.error("--asm and --bin are required without --dir-metadata")

    # Create default linker script if not provided
    linker_script = args.linker
    if not linker_script:
        linker_script = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "scripts", "link.ld"
        )
        if not os.path.exists(linker_script):
            create_default_linker_script(linker_script)

    success = compile_assembly(args.asm, args.bin, linker_script,
                               args.gcc_prefix, args.include_dir,
                               args.riscv_dv_dir, args.hex)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 Regression Runner

Top-level script that orchestrates the full regression flow:
  1. Generate instruction programs (riscv-dv)
  2. Compile assembly to binary
  3. Run RTL simulations
  4. Check logs and collect results
  5. Generate reports

Usage:
  python3 run_regress.py --testlist testlist.yaml --simulator vcs --iterations 1
  python3 run_regress.py --test riscv_random_instr_test --seed 42
"""

import argparse
import os
import re
import shutil
import sys
import time
import yaml
import subprocess
from concurrent.futures import ProcessPoolExecutor, as_completed

# Add scripts directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from metadata import (
    RegressionMetadata, TestRunResult, RegressionSummary,
    load_testlist
)
from check_logs import check_sim_log
from collect_results import generate_report_json
import directed_test_schema
import rvvi_trace_to_trace_csv
import trace_compare_full


# Paths
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DV_DIR = os.path.dirname(SCRIPT_DIR)
EH2_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(DV_DIR)))
RISCV_DV_DIR = os.path.join(EH2_ROOT, "vendor", "google_riscv-dv")
DEFAULT_TESTLIST = os.path.join(DV_DIR, "riscv_dv_extension", "testlist.yaml")


def find_test_entry(testlist: list, test_name: str) -> dict:
    """Find a test entry in the testlist."""
    for entry in testlist:
        if entry.get("test") == test_name:
            return entry
    return None


def load_regression_testlist(testlist_path: str) -> list:
    """Load riscv-dv or Ibex-style directed testlist entries."""
    raw_entries = load_testlist(testlist_path)
    if not raw_entries:
        return []

    if any(isinstance(entry, dict) and "config" in entry and "test" not in entry
           for entry in raw_entries):
        model = directed_test_schema.import_model(testlist_path)
        raw_by_name = {
            entry.get("test"): entry
            for entry in raw_entries
            if isinstance(entry, dict) and entry.get("test")
        }
        entries = []
        for test in model.tests:
            raw_entry = raw_by_name.get(test.test, {})
            entry = {
                "test": test.test,
                "description": test.desc,
                "test_type": "DIRECTED",
                "asm": test.test_srcs,
                "rtl_test": test.rtl_test,
                "iterations": test.iterations,
                "cosim": "enabled",
            }
            if test.ld_script:
                entry["linker"] = test.ld_script
            for key in ("sim_opts", "gen_opts", "skip_in_signoff"):
                if key in raw_entry:
                    entry[key] = raw_entry[key]
            entries.append(entry)
        return entries

    return raw_entries


def find_generated_asm(work_dir: str, test_name: str) -> str:
    """Find the assembly file produced by riscv-dv for one test/seed.

    riscv-dv writes generated assembly under asm_test/<test>_0.S for a
    single-iteration run.  Some tests (notably CSR tests) can use slightly
    different names, so fall back to the first .S under asm_test.
    """
    candidates = [
        os.path.join(work_dir, "asm_test", f"{test_name}_0.S"),
        os.path.join(work_dir, f"{test_name}_0.S"),
        os.path.join(work_dir, f"{test_name}.S"),
    ]
    for path in candidates:
        if os.path.exists(path):
            return path

    asm_dir = os.path.join(work_dir, "asm_test")
    for root, _, files in os.walk(asm_dir if os.path.isdir(asm_dir) else work_dir):
        for filename in sorted(files):
            if filename.endswith(".S"):
                return os.path.join(root, filename)

    raise FileNotFoundError(f"No generated assembly found for {test_name} in {work_dir}")


def build_sim_opts(test_entry: dict, cli_sim_opts: str = "") -> str:
    """Merge testlist/CLI sim options."""
    pieces = []
    entry_opts = test_entry.get("sim_opts", "")
    if entry_opts:
        pieces.append(str(entry_opts).replace("\n", " ").strip())
    if cli_sim_opts:
        pieces.append(cli_sim_opts.replace("\n", " ").strip())

    sim_opts = " ".join(piece for piece in pieces if piece).strip()
    return add_instr_count_runtime_budget(test_entry, sim_opts)


def _plusarg_int(text: str, name: str):
    match = re.search(r"(?:^|\s)\+{}=(0x[0-9a-fA-F]+|\d+)(?:\s|$)".
                      format(re.escape(name)), text or "")
    if not match:
        return None
    try:
        return int(match.group(1), 0)
    except ValueError:
        return None


def add_instr_count_runtime_budget(test_entry: dict, sim_opts: str) -> str:
    """Size missing runtime plusargs from riscv-dv +instr_cnt.

    Several signoff-sized generated programs retire normally beyond the base
    100k-cycle UVM default.  Add a bounded budget only when the testlist/CLI did
    not already set one, so explicit per-test budgets keep precedence.
    """
    sim_opts = (sim_opts or "").strip()
    instr_cnt = _plusarg_int(test_entry.get("gen_opts", ""), "instr_cnt")
    if not instr_cnt:
        return sim_opts

    pieces = [sim_opts] if sim_opts else []
    cycles = max(100_000, instr_cnt * 50)
    if "+max_cycles=" not in sim_opts:
        pieces.append("+max_cycles={}".format(cycles))
    if "+timeout_ns=" not in sim_opts:
        pieces.append("+timeout_ns={}".format(cycles * 100))
    return " ".join(piece for piece in pieces if piece)


def sim_process_timeout_s(sim_opts: str) -> int:
    """Return a wall-clock timeout for the RTL subprocess."""
    cycles = _plusarg_int(sim_opts, "max_cycles")
    if not cycles:
        return 1800
    return max(1800, int(cycles / 500) + 300)


def add_rvvi_elf_sim_opt(sim_opts: str, binary: str) -> str:
    """Add +rvvi_elf=<matching ELF> for RVVI trace-aware flows.

    Directed/regression runs pass +bin=<hex> to the RTL, while the RVVI
    trace collector keeps the matching ELF path available for downstream
    standalone EH2-Spike trace comparison.
    """
    sim_opts = (sim_opts or "").strip()
    if "+rvvi_elf=" in sim_opts:
        return sim_opts

    root, ext = os.path.splitext(binary)
    elf_path = root + ".elf" if ext in (".hex", ".bin") else binary + ".elf"
    return " ".join(piece for piece in (sim_opts, f"+rvvi_elf={elf_path}") if piece)


def add_rvvi_trace_dump_sim_opts(sim_opts: str, trace_path: str) -> str:
    """Enable the RVVI retire dump unless the caller already configured it."""
    sim_opts = (sim_opts or "").strip()
    pieces = [sim_opts]
    if "+rvvi_trace_dump" not in sim_opts:
        pieces.append("+rvvi_trace_dump")
    if "+rvvi_trace_file=" not in sim_opts:
        pieces.append(f"+rvvi_trace_file={trace_path}")
    return " ".join(piece for piece in pieces if piece)


def rvvi_nhart_from_sim_opts(sim_opts: str) -> int:
    """Extract +rvvi_nhart=N from sim opts, defaulting to one hart."""
    for token in (sim_opts or "").split():
        if token.startswith("+rvvi_nhart="):
            try:
                return max(1, int(token.split("=", 1)[1], 0))
            except ValueError:
                return 1
    return 1


def uses_trace_compare(test_entry: dict) -> bool:
    """Return whether this test is gated by offline trace comparison.

    Default-on keeps the regression checker strong.  Only tests that contain
    asynchronous interrupt/debug delivery may opt out, and the testlist entry
    must document the alternate UVM-agent/signature checker in tracecmp_bypass.
    """
    if str(test_entry.get("cosim", "enabled")).lower() == "rtl_only":
        return False
    return str(test_entry.get("tracecmp", "enabled")).lower() != "disabled"


def write_process_log(path: str, proc: subprocess.CompletedProcess):
    """Write captured subprocess stdout/stderr to a durable log file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        if proc.stdout:
            f.write(proc.stdout)
        if proc.stderr:
            if proc.stdout and not proc.stdout.endswith(b"\n"):
                f.write(b"\n")
            f.write(proc.stderr)


def save_and_return(result: TestRunResult, work_dir: str) -> TestRunResult:
    """Persist a final test result before returning from any path."""
    result.save(os.path.join(work_dir, "result"))
    return result


def run_captured(cmd: list, timeout: int) -> subprocess.CompletedProcess:
    """Run a subprocess with captured output on Python 3.6+."""
    return subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )


def _line_count(path: str) -> int:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return sum(1 for _ in f)


def write_hart_schedule_from_csv(csv_path: str, schedule_path: str) -> int:
    """Write the DUT retire hart sequence for the standalone reference."""
    rows = trace_compare_full.read_trace_csv(csv_path)
    with open(schedule_path, "w", encoding="utf-8") as f:
        for row in rows:
            f.write("{}\n".format(row.hart))
    return len(rows)


def run_trace_compare(work_dir: str, binary: str, nhart: int = 1) -> bool:
    """Run DUT RVVI dump vs standalone EH2-Spike trace comparison."""
    rvvi_trace = os.path.join(work_dir, "rvvi_trace.log")
    dut_csv = os.path.join(work_dir, "dut_trace.csv")
    ref_csv = os.path.join(work_dir, "ref_trace.csv")
    ref_schedule = os.path.join(work_dir, "ref_hart_schedule.txt")
    compare_log = os.path.join(work_dir, "trace_compare.log")
    rvviref_target = os.path.join("build", "rvviref", "spike_rvvi_main")
    rvviref_exe = os.path.join(EH2_ROOT, rvviref_target)

    root, ext = os.path.splitext(binary)
    elf_path = root + ".elf" if ext in (".hex", ".bin") else binary + ".elf"
    if not os.path.exists(rvvi_trace):
        with open(compare_log, "w", encoding="utf-8") as log_f:
            log_f.write("ERROR: missing DUT RVVI trace: {}\n".format(rvvi_trace))
        return False
    if not os.path.exists(elf_path):
        with open(compare_log, "w", encoding="utf-8") as log_f:
            log_f.write("ERROR: missing ELF for EH2-Spike: {}\n".format(elf_path))
        return False

    try:
        rvvi_trace_to_trace_csv.convert_rvvi_trace(rvvi_trace, dut_csv)
    except RuntimeError as err:
        with open(compare_log, "w", encoding="utf-8") as log_f:
            log_f.write("ERROR: DUT trace conversion failed: {}\n".format(err))
        return False

    try:
        steps = max(1, write_hart_schedule_from_csv(dut_csv, ref_schedule))
    except (OSError, ValueError) as err:
        with open(compare_log, "w", encoding="utf-8") as log_f:
            log_f.write("ERROR: DUT hart schedule generation failed: {}\n".format(err))
        return False
    build_ref = run_captured(["make", rvviref_target], 300)
    if build_ref.returncode != 0:
        write_process_log(compare_log, build_ref)
        return False
    ref_proc = run_captured(
        [rvviref_exe, elf_path, ref_csv, str(steps), str(max(1, nhart)),
         ref_schedule], 300)
    if ref_proc.returncode != 0:
        write_process_log(compare_log, ref_proc)
        return False

    try:
        cmp_result = trace_compare_full.compare_trace_csv(
            dut_csv, ref_csv, "dut", "ref", log=compare_log)
    except (OSError, ValueError) as err:
        with open(compare_log, "w", encoding="utf-8") as log_f:
            log_f.write("ERROR: full trace comparison failed: {}\n".format(err))
        return False

    return cmp_result.passed


def run_single_test(test_entry: dict, seed: int, simulator: str,
                    output_dir: str, binary: str = "",
                    cli_sim_opts: str = "",
                    coverage: bool = False,
                    waves: bool = False,
                    fail_on_warnings: bool = False,
                    build_dir: str = None) -> TestRunResult:
    """
    Run a single test: generate, compile, simulate, check.

    Returns:
        TestRunResult
    """
    result = TestRunResult()
    test_name = test_entry["test"]
    result.test_name = test_name
    result.seed = seed
    result.test_type = test_entry.get("test_type", "DIRECTED"
                                      if test_entry.get("asm") or
                                      test_entry.get("test_srcs") else
                                      "RISCVDV")

    work_dir = os.path.join(output_dir, f"{test_name}_s{seed}")
    os.makedirs(work_dir, exist_ok=True)

    gen_opts = test_entry.get("gen_opts", "")
    rtl_test = test_entry.get("rtl_test", "core_eh2_base_test")
    sim_opts = build_sim_opts(test_entry, cli_sim_opts)

    directed_asm = test_entry.get("asm", "") or test_entry.get("test_srcs", "")
    if directed_asm and not os.path.isabs(directed_asm):
        directed_asm = os.path.join(DV_DIR, directed_asm)

    # Step 1: Generate assembly (if no binary or directed assembly provided)
    if not binary and not directed_asm:
        gen_start = time.time()
        gen_cmd = [
            sys.executable, os.path.join(SCRIPT_DIR, "run_instr_gen.py"),
            "--riscv-dv-dir", RISCV_DV_DIR,
            "--work-dir", work_dir,
            "--test", test_name,
            "--gen-opts", gen_opts,
            "--seed", str(seed),
        ]
        try:
            proc = run_captured(gen_cmd, timeout=600)
            result.gen_time_sec = time.time() - gen_start
            gen_log = os.path.join(work_dir, "gen.log")
            write_process_log(gen_log, proc)
            if proc.returncode != 0:
                result.failure_mode = "GEN_ERROR"
                result.sim_log_path = gen_log
                return save_and_return(result, work_dir)
        except subprocess.TimeoutExpired:
            result.failure_mode = "GEN_TIMEOUT"
            timeout_log = os.path.join(work_dir, "gen.log")
            with open(timeout_log, "w") as log_f:
                log_f.write("ERROR: instruction generation timed out\n")
            result.sim_log_path = timeout_log
            return save_and_return(result, work_dir)

        try:
            asm_path = find_generated_asm(work_dir, test_name)
        except FileNotFoundError:
            result.failure_mode = "GEN_NO_ASM"
            result.sim_log_path = os.path.join(work_dir, "gen.log")
            return save_and_return(result, work_dir)

        result.assembly_path = asm_path

    elif directed_asm and not binary:
        if not os.path.exists(directed_asm):
            result.failure_mode = "DIRECTED_ASM_MISSING"
            result.assembly_path = directed_asm
            missing_log = os.path.join(work_dir, "compile.log")
            with open(missing_log, "w") as log_f:
                log_f.write(f"ERROR: directed assembly not found: {directed_asm}\n")
            result.sim_log_path = missing_log
            return save_and_return(result, work_dir)
        result.assembly_path = directed_asm

    if not binary:
        # Step 2: Compile to binary/hex
        compile_start = time.time()
        bin_path = os.path.join(work_dir, f"{test_name}.bin")
        hex_path = os.path.join(work_dir, f"{test_name}.hex")
        asm_for_compile = result.assembly_path
        compile_cmd = [
            sys.executable, os.path.join(SCRIPT_DIR, "compile_test.py"),
            "--asm", asm_for_compile,
            "--bin", bin_path,
            "--hex", hex_path,
        ]
        if test_entry.get("linker"):
            linker = test_entry["linker"]
            if not os.path.isabs(linker):
                linker = os.path.join(DV_DIR, linker)
            compile_cmd.extend(["--linker", linker])
        compile_log = os.path.join(work_dir, "compile.log")
        try:
            proc = run_captured(compile_cmd, timeout=120)
            result.compile_time_sec = time.time() - compile_start
            write_process_log(compile_log, proc)
            if proc.returncode != 0:
                result.failure_mode = "COMPILE_ERROR"
                result.sim_log_path = compile_log
                return save_and_return(result, work_dir)
        except subprocess.TimeoutExpired:
            result.failure_mode = "COMPILE_TIMEOUT"
            with open(compile_log, "w") as log_f:
                log_f.write("ERROR: assembly compilation timed out\n")
            result.sim_log_path = compile_log
            return save_and_return(result, work_dir)

        binary = hex_path

    result.binary_path = binary
    trace_compare_enabled = uses_trace_compare(test_entry)
    if trace_compare_enabled:
        sim_opts = add_rvvi_elf_sim_opt(sim_opts, binary)
        sim_opts = add_rvvi_trace_dump_sim_opts(
            sim_opts, os.path.join(work_dir, "rvvi_trace.log"))

    # Step 3: Run RTL simulation
    sim_start = time.time()
    log_path = os.path.join(work_dir, f"sim_{test_name}_{seed}.log")

    # For now, use a simpler direct command
    sim_cmd = [
        sys.executable, os.path.join(SCRIPT_DIR, "run_rtl.py"),
        "--test", test_name,
        "--seed", str(seed),
        "--binary", binary,
        "--simulator", simulator,
        "--rtl-test", rtl_test,
        "--sim-opts", sim_opts,
        "--build-dir", build_dir or os.path.join(EH2_ROOT, "build", "compile"),
        "--out-dir", work_dir,
        "--process-timeout-s", str(sim_process_timeout_s(sim_opts)),
    ]
    if coverage:
        sim_cmd.append("--coverage")
    if waves:
        sim_cmd.append("--waves")

    try:
        proc = run_captured(sim_cmd, timeout=sim_process_timeout_s(sim_opts) + 120)
        result.sim_time_sec = time.time() - sim_start
        result.sim_returncode = proc.returncode
    except subprocess.TimeoutExpired:
        result.sim_time_sec = time.time() - sim_start
        result.failure_mode = "SIM_TIMEOUT"
        timeout_log = os.path.join(work_dir, "rtl_timeout.log")
        with open(timeout_log, "w") as log_f:
            log_f.write("ERROR: RTL simulation process timed out\n")
        result.sim_log_path = timeout_log
        return save_and_return(result, work_dir)

    # Step 4: Check results
    result.sim_log_path = log_path
    check_result = check_sim_log(log_path, fail_on_warnings=fail_on_warnings,
                                 sim_returncode=proc.returncode)
    result.passed = check_result.passed
    result.failure_mode = check_result.failure_mode
    result.uvm_errors = check_result.uvm_errors
    result.uvm_warnings = check_result.uvm_warnings
    result.num_instructions = check_result.num_instructions
    result.num_cycles = check_result.num_cycles
    result.ipc = check_result.ipc

    if result.passed and trace_compare_enabled:
        if not run_trace_compare(work_dir, binary, rvvi_nhart_from_sim_opts(sim_opts)):
            result.passed = False
            result.failure_mode = "TRACECMP_MISMATCH"

    # Save result
    return save_and_return(result, work_dir)


def run_regression(args) -> RegressionSummary:
    """Run the full regression."""
    summary = RegressionSummary()
    start_time = time.time()

    # Load testlist
    testlist_path = args.testlist or DEFAULT_TESTLIST
    if args.test and args.testlist:
        testlist = [
            entry for entry in load_regression_testlist(testlist_path)
            if entry.get("test") == args.test
        ]
        if not testlist:
            raise ValueError(f"Test {args.test} not found in {testlist_path}")
        if args.rtl_test:
            testlist[0]["rtl_test"] = args.rtl_test
        if args.gen_opts:
            testlist[0]["gen_opts"] = args.gen_opts
    elif args.test:
        # Single test mode
        testlist = [{"test": args.test, "rtl_test": args.rtl_test or "core_eh2_base_test",
                     "gen_opts": args.gen_opts or "", "sim_opts": "",
                     "cosim": "enabled"}]
    else:
        testlist = load_regression_testlist(testlist_path)

    output_dir = args.output or os.path.join(EH2_ROOT, "build", "regression",
                                              time.strftime("%Y%m%d_%H%M%S"))
    os.makedirs(output_dir, exist_ok=True)

    # Build test matrix: (test_entry, seed) pairs
    # Honor skip_in_signoff when running under sign-off (env var set by signoff.py).
    in_signoff = os.environ.get("EH2_SIGNOFF_MODE") == "1"
    test_matrix = []
    skipped_signoff = []
    for entry in testlist:
        if in_signoff and entry.get("skip_in_signoff"):
            skipped_signoff.append(entry["test"])
            continue
        iterations = args.iterations or entry.get("iterations", 1)
        # When iterations >1 each run gets a distinct seed so the iterations
        # actually exercise different stimulus. Previously every iteration
        # reused the same seed (args.seed when given, else just `i+1`),
        # which meant either (a) all iterations ran the identical test, or
        # (b) iterations clobbered each other in the same `<test>_s1/`
        # work-dir, leaving only the last result.yaml/sim_log on disk.
        # Use args.seed as the base and step by i for iteration distinctness.
        base_seed = args.seed if args.seed else 1
        for i in range(iterations):
            seed = base_seed + i
            test_matrix.append((entry, seed))

    if skipped_signoff:
        print(f"\nSkipping {len(skipped_signoff)} test(s) marked skip_in_signoff:")
        for name in skipped_signoff:
            print(f"  - {name}")

    print(f"\n{'='*60}")
    print(f"EH2 Regression: {len(test_matrix)} test runs")
    print(f"Output: {output_dir}")
    print(f"{'='*60}\n")

    # Run tests (sequential for now, parallel later)
    max_workers = args.parallel if hasattr(args, 'parallel') else 1

    if max_workers > 1:
        with ProcessPoolExecutor(max_workers=max_workers) as executor:
            futures = {}
            for entry, seed in test_matrix:
                future = executor.submit(
                    run_single_test, entry, seed, args.simulator,
                    output_dir, args.binary, args.sim_opts,
                    args.coverage, args.waves, args.fail_on_warnings,
                    args.build_dir
                )
                futures[future] = (entry["test"], seed)

            for future in as_completed(futures):
                test_name, seed = futures[future]
                try:
                    result = future.result()
                    summary.add_result(result)
                    status = "PASS" if result.passed else "FAIL"
                    print(f"[{status}] {test_name} seed={seed}")
                except Exception as e:
                    print(f"[ERROR] {test_name} seed={seed}: {e}")
    else:
        for entry, seed in test_matrix:
            test_name = entry["test"]
            print(f"Running: {test_name} seed={seed} ...")
            result = run_single_test(entry, seed, args.simulator,
                                     output_dir, args.binary, args.sim_opts,
                                     args.coverage, args.waves,
                                     args.fail_on_warnings, args.build_dir)
            summary.add_result(result)
            status = "PASS" if result.passed else "FAIL"
            print(f"[{status}] {test_name} seed={seed} "
                  f"({result.sim_time_sec:.0f}s)")

    summary.total_time_sec = time.time() - start_time

    # Generate reports
    summary.to_log(os.path.join(output_dir, "regr.log"))
    summary.to_junit_xml(os.path.join(output_dir, "regr_junit.xml"))
    generate_report_json(summary, os.path.join(output_dir, "report.json"))

    if args.coverage and args.simulator == "vcs":
        cov_db = os.path.join(EH2_ROOT, "build", "cov.vdb")
        out_cov_db = os.path.join(output_dir, "cov.vdb")
        if os.path.isdir(cov_db):
            if os.path.isdir(out_cov_db):
                shutil.rmtree(out_cov_db)
            shutil.copytree(cov_db, out_cov_db)
            print(f"Coverage DB: {out_cov_db}")
        else:
            print(f"[WARN] Coverage requested, but VCS DB not found: {cov_db}")

    print(f"\n{'='*60}")
    print(f"Regression Complete")
    print(f"Total: {summary.total_tests} | Passed: {summary.passed} | "
          f"Failed: {summary.failed}")
    print(f"Pass rate: {100*summary.passed/max(1,summary.total_tests):.1f}%")
    print(f"Time: {summary.total_time_sec:.0f}s")
    print(f"Reports: {output_dir}/")
    print(f"{'='*60}\n")

    return summary


def regression_exit_code(summary: RegressionSummary, min_passed: int = None,
                         max_fail_rate_for_threshold: float = 0.25) -> int:
    """Return process status for strict or threshold-gated regressions."""
    if summary.failed == 0:
        return 0
    if min_passed is None:
        return 1
    if summary.total_tests <= 0:
        return 1
    fail_rate = summary.failed / summary.total_tests
    if summary.passed >= min_passed and fail_rate <= max_fail_rate_for_threshold:
        print(
            "Regression threshold met: {}/{} passed, minimum {}, "
            "fail rate {:.1%} <= {:.0%}; returning success".format(
                summary.passed, summary.total_tests, min_passed,
                fail_rate, max_fail_rate_for_threshold))
        return 0
    return 1


def main():
    parser = argparse.ArgumentParser(
        description="EH2 Regression Runner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --testlist riscv_dv_extension/testlist.yaml
  %(prog)s --test riscv_random_instr_test --seed 42 --simulator vcs
  %(prog)s --testlist testlist.yaml --iterations 5 --parallel 4
        """
    )

    # Test selection
    parser.add_argument("--testlist", help="Test list YAML file")
    parser.add_argument("--test", help="Run a single test")
    parser.add_argument("--iterations", type=int, help="Override iterations count")
    parser.add_argument("--seed", type=int, help="Override random seed")

    # Test configuration
    parser.add_argument("--rtl-test", default="",
                        help="UVM test class")
    parser.add_argument("--gen-opts", default="", help="Generator options")
    parser.add_argument("--sim-opts", default="", help="Simulation options")
    parser.add_argument("--binary", default="", help="Use pre-built binary")
    parser.add_argument("--coverage", action="store_true",
                        help="Enable simulator coverage collection")
    parser.add_argument("--waves", action="store_true",
                        help="Enable waveform dumping")
    parser.add_argument("--fail-on-warnings", action="store_true",
                        help="Treat simulator/UVM warnings as test failures")

    # Simulator
    parser.add_argument("--simulator", default="vcs",
                        choices=["vcs", "nc", "xlm", "questa"],
                        help="Simulator to use")

    # Output
    parser.add_argument("--output", help="Output directory")
    parser.add_argument("--build-dir", default=None,
                        help="Per-target build root containing simv. "
                             "Defaults to <eh2_root>/build/compile when omitted.")
    parser.add_argument("--min-passed", type=int, default=None,
                        help="Return success if at least this many tests pass "
                             "and the failure rate stays within the threshold. "
                             "Omit for strict zero-failure behavior.")
    parser.add_argument("--max-fail-rate-for-threshold", type=float,
                        default=0.25,
                        help="Maximum failed/total ratio allowed when "
                             "--min-passed is used.")

    # Parallelism
    parser.add_argument("--parallel", type=int, default=1,
                        help="Number of parallel test runs")

    args = parser.parse_args()

    if not args.testlist and not args.test:
        parser.error("Must specify --testlist or --test")

    summary = run_regression(args)
    sys.exit(regression_exit_code(
        summary, args.min_passed, args.max_fail_rate_for_threshold))


if __name__ == "__main__":
    main()

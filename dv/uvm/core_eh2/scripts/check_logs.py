#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 Simulation Log Checker

Analyzes simulation logs to determine test pass/fail status.
Checks for:
  - UVM_FATAL / UVM_ERROR messages
  - Test pass/fail mailbox signature
  - Simulation timeout
  - Trace output for instruction count
"""

import argparse
import os
import re
import sys
from pathlib import Path
from metadata import TestRunResult
from test_entry import read_test_dot_seed


UVM_SUMMARY_RE = re.compile(
    r"^\s*(UVM_WARNING|UVM_ERROR|UVM_FATAL)\s*:\s*(\d+)\b")

# Lines starting with the UVM Report Summary severity tag are never real
# fatals/errors/warnings — those come from `uvm_report_*` and embed a path
# like "UVM_FATAL <path>(<line>) @ <time>: ...". VCS interleaves its banner
# over the summary in three known shapes:
#   "UVM_FATAL :            V C S   S i m u l a t i o n   R e p o r t"
#   "UVM_FATAL            V C S   S i m u l a t i o n   R e p o r t"
#   "UVM_FATAL\n"   (count + banner overwrite the rest of the line; the
#                    Coverage Metrics dashes land on the next line instead)
# Match all three — colon, V C S keyword, or end-of-line — so we can safely
# skip them.
UVM_SUMMARY_LINE_RE = re.compile(
    r"^\s*(UVM_WARNING|UVM_ERROR|UVM_FATAL)"
    r"(\s*:|\s+(?=V\s*C\s*S\b)|\s*$)")

# NC's UVM Report Catcher emits informational lines like
# "Number of demoted UVM_FATAL reports  :    0" and "Number of caught UVM_ERROR
# reports   :    0" inside its summary block. They are not real failures.
UVM_CATCHER_SUMMARY_RE = re.compile(
    r"^\s*Number of (demoted|caught) UVM_(WARNING|ERROR|FATAL) reports")


TOOL_WARNING_RE = re.compile(r"\bWarning-\[")
TOOL_CRASH_RE = re.compile(
    r"(An unexpected termination|Segmentation fault|Fatal signal|core dumped|"
    r"Stack trace follows)",
    re.IGNORECASE)
SIM_FATAL_RE = re.compile(
    r"(^\s*(Fatal:|\*\*\s*Fatal:|\$fatal\b)|"
    r"^\s*Error:\s+\"[^\"]+\.(sv|svh|v|vh)\"|"
    r"RVVI_SCOREBOARD:\s+online lockstep failed)",
    re.IGNORECASE)
TOOL_TIMEOUT_RE = re.compile(
    r"(Command timed out|Simulation timeout|Wall-clock timeout)",
    re.IGNORECASE)
PRE_SIM_FAILURE_MODES = {
    "GEN_ERROR",
    "GEN_TIMEOUT",
    "GEN_NO_ASM",
    "COMPILE_ERROR",
    "COMPILE_TIMEOUT",
    "DIRECTED_ASM_MISSING",
    "BINARY_MISSING",
}


def check_uvm_log(log_path: str, fail_on_warnings: bool = False,
                  sim_returncode: int = None) -> tuple:
    """
    Check UVM simulation log for errors.

    Returns:
        (passed: bool, failure_mode: str, num_errors: int, num_warnings: int)
    """
    if not os.path.exists(log_path):
        return (False, "FILE_ERROR", 0, 0)

    num_errors = 0
    num_warnings = 0
    summary_errors = None
    summary_warnings = None
    has_fatal = False
    has_test_pass = False
    has_test_fail = False
    has_tool_crash = False
    has_sim_fatal = False
    has_tool_timeout = False

    with open(log_path, "r", errors="replace") as f:
        for line in f:
            if TOOL_CRASH_RE.search(line):
                has_tool_crash = True
            if SIM_FATAL_RE.search(line):
                has_sim_fatal = True
                num_errors += 1
            if TOOL_TIMEOUT_RE.search(line):
                has_tool_timeout = True

            summary_match = UVM_SUMMARY_RE.match(line)
            if summary_match:
                count = int(summary_match.group(2))
                if count == 0:
                    continue
                severity = summary_match.group(1)
                if severity == "UVM_WARNING":
                    summary_warnings = (summary_warnings or 0) + count
                    continue
                summary_errors = (summary_errors or 0) + count
                if severity == "UVM_FATAL":
                    has_fatal = True
                continue

            # Skip summary lines whose count was overwritten by tool banner
            # text (still summary lines, not real fatals/errors/warnings).
            if UVM_SUMMARY_LINE_RE.match(line):
                continue

            # Skip NC UVM Report Catcher informational lines.
            if UVM_CATCHER_SUMMARY_RE.match(line):
                continue

            if line.startswith("UVM_FATAL") or " UVM_FATAL " in line:
                has_fatal = True
                num_errors += 1
            elif line.startswith("UVM_ERROR") or " UVM_ERROR " in line:
                num_errors += 1
            elif "UVM_WARNING" in line or TOOL_WARNING_RE.search(line):
                num_warnings += 1
            elif "TEST PASSED" in line or "test_passed" in line:
                has_test_pass = True
            elif ("TEST FAILED" in line or "test_failed" in line or
                  "EH2 UVM TEST FAILED" in line or
                  "RISC-V UVM TEST FAILED" in line):
                has_test_fail = True

    if summary_errors is not None:
        num_errors = summary_errors
    if summary_warnings is not None:
        num_warnings = summary_warnings

    # Simulator crashes must take priority over a missing pass signature. This
    # keeps infrastructure failures visible in sign-off summaries.
    if has_tool_crash:
        return (False, "SIM_CRASH", num_errors, num_warnings)
    if has_tool_timeout:
        return (False, "SIM_TIMEOUT", num_errors, num_warnings)
    if has_sim_fatal:
        return (False, "SIM_FATAL", num_errors, num_warnings)
    if has_fatal:
        return (False, "UVM_FATAL", num_errors, num_warnings)
    if has_test_fail:
        return (False, "TEST_FAIL", num_errors, num_warnings)
    if num_errors > 0:
        return (False, "UVM_ERROR", num_errors, num_warnings)
    # NC/irun frequently exits with code 1 even when the simulation
    # printed "TEST PASSED" and the report summary shows zero errors —
    # the exit code reflects parser/elab warnings, not run-time status.
    # Trust the explicit pass marker over the return code in that case.
    if sim_returncode not in (None, 0) and not has_test_pass:
        return (False, "SIM_ERROR", num_errors, num_warnings)
    if fail_on_warnings and num_warnings > 0:
        return (False, "TOOL_WARNING", num_errors, num_warnings)
    if has_test_pass:
        return (True, "NONE", num_errors, num_warnings)

    # EH2 tests must explicitly report pass via mailbox/signature text.
    return (False, "NO_PASS_SIGNATURE", num_errors, num_warnings)


def extract_instruction_count(trace_path: str) -> int:
    """Extract instruction count from trace file."""
    if not os.path.exists(trace_path):
        return 0

    count = 0
    with open(trace_path, "r", errors="replace") as f:
        for line in f:
            # Count lines that look like instruction traces
            if line.strip() and not line.startswith("#"):
                count += 1
    return count


def extract_cycle_count(log_path: str) -> int:
    """Extract cycle count from simulation log."""
    if not os.path.exists(log_path):
        return 0

    with open(log_path, "r", errors="replace") as f:
        for line in f:
            # Look for cycle count in log
            match = re.search(r"cycles?:\s*(\d+)", line, re.IGNORECASE)
            if match:
                return int(match.group(1))
    return 0


def check_sim_log(log_path: str, trace_path: str = "",
                  fail_on_warnings: bool = False,
                  sim_returncode: int = None) -> TestRunResult:
    """
    Analyze simulation log and produce test result.

    Args:
        log_path: Path to simulation log
        trace_path: Path to trace file (optional)

    Returns:
        TestRunResult with analysis results
    """
    result = TestRunResult()
    result.sim_returncode = sim_returncode

    passed, failure_mode, num_errors, num_warnings = check_uvm_log(
        log_path, fail_on_warnings, sim_returncode)
    result.passed = passed
    result.failure_mode = failure_mode
    result.uvm_errors = num_errors
    result.uvm_warnings = num_warnings

    if trace_path:
        result.num_instructions = extract_instruction_count(trace_path)
    result.num_cycles = extract_cycle_count(log_path)

    if result.num_cycles > 0 and result.num_instructions > 0:
        result.ipc = result.num_instructions / result.num_cycles

    return result


def load_recorded_result(test_dir: Path, test_name: str, seed: int):
    """Load the result recorded by earlier staged steps."""
    for result_base in [test_dir / "{}_{}".format(test_name, seed),
                        test_dir / "result"]:
        if not Path(str(result_base) + ".pkl").exists():
            continue
        try:
            return TestRunResult.load(str(result_base))
        except Exception as err:
            print("Warning: Could not load recorded result {}: {}".format(
                result_base, err))
    return None


def load_recorded_sim_returncode(test_dir: Path, test_name: str, seed: int):
    """Load the simulator process return code recorded by run_rtl.py."""
    result = load_recorded_result(test_dir, test_name, seed)
    if result is None:
        return None
    value = getattr(result, "sim_returncode", None)
    return int(value) if value is not None else None


def metadata_test_type(md, test_name: str) -> str:
    """Return the test type exported in regression metadata."""
    for name, _, test_type in getattr(md, "tests_and_counts", []):
        if name == test_name:
            return test_type
    return getattr(md, "test_type", "RISCVDV") or "RISCVDV"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Check simulation logs")
    parser.add_argument("--log", default="", help="Simulation log path")
    parser.add_argument("--trace", default="", help="Trace file path")
    parser.add_argument("--output", default="", help="Output result path")
    parser.add_argument("--fail-on-warnings", action="store_true",
                        help="Treat simulator/UVM warnings as failures")
    parser.add_argument("--sim-returncode", type=int, default=None,
                        help="Simulator process return code")
    parser.add_argument("--dir-metadata", default="",
                        help="Ibex-style metadata directory")
    parser.add_argument("--test-dot-seed", default="",
                        help="Ibex-style TEST.SEED selector")
    args = parser.parse_args(argv)
    metadata_mode = bool(args.dir_metadata)

    if metadata_mode:
        if not args.test_dot_seed:
            parser.error("--test-dot-seed is required with --dir-metadata")
        from metadata import RegressionMetadata

        md = RegressionMetadata.construct_from_metadata_dir(
            Path(args.dir_metadata))
        test_name, seed = read_test_dot_seed(args.test_dot_seed)
        test_dir = Path(md.dir_tests) / args.test_dot_seed
        log_path = test_dir / "sim_{}_{}.log".format(test_name, seed)
        trace_path = test_dir / "trace_core"
        recorded_result = load_recorded_result(test_dir, test_name, seed)
        sim_returncode = args.sim_returncode
        if sim_returncode is None:
            sim_returncode = (
                getattr(recorded_result, "sim_returncode", None)
                if recorded_result is not None else None)
        if recorded_result is not None and \
                recorded_result.failure_mode in PRE_SIM_FAILURE_MODES:
            result = recorded_result
            result.passed = False
        else:
            result = check_sim_log(
                str(log_path),
                str(trace_path) if trace_path.exists() else "",
                args.fail_on_warnings,
                sim_returncode)
        result.test_name = test_name
        result.seed = seed
        result.test_type = metadata_test_type(md, test_name)
        result.sim_log_path = str(log_path)
        result.trace_path = str(trace_path) if trace_path.exists() else ""
        binary_path = test_dir / "test.hex"
        if not binary_path.exists():
            binary_path = test_dir / "test.bin"
        result.binary_path = str(binary_path)
        result.save(str(test_dir / "result"))
        trr_yaml = test_dir / "trr.yaml"
        trr_yaml.write_text(
            "test: {}\nseed: {}\ntype: {}\npassed: {}\nfailure_mode: {}\n"
            "uvm_errors: {}\nuvm_warnings: {}\nsim_returncode: {}\n".format(
                test_name, seed, result.test_type, bool(result.passed),
                result.failure_mode,
                result.uvm_errors, result.uvm_warnings,
                "" if result.sim_returncode is None
                else result.sim_returncode),
            encoding="utf-8")
    else:
        if not args.log:
            parser.error("--log is required without --dir-metadata")
        result = check_sim_log(args.log, args.trace, args.fail_on_warnings,
                               args.sim_returncode)

    if args.output:
        result.save(args.output)

    status = "PASSED" if result.passed else "FAILED"
    print(f"[{status}] errors={result.uvm_errors} warnings={result.uvm_warnings}")
    if result.failure_mode and result.failure_mode != "NONE":
        print(f"Failure mode: {result.failure_mode}")

    # Ibex-style Make flows must continue after an individual test failure so
    # collect_results can aggregate all trr.yaml/result.pkl files. Direct CLI
    # use keeps the conventional failing exit code for local debugging.
    if metadata_mode:
        return 0
    return 0 if result.passed else 1


if __name__ == "__main__":
    sys.exit(main())

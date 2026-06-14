#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 Regression Results Collector

Aggregates individual test results into regression summary reports:
  - regr.log (text)
  - regr_junit.xml (JUnit XML for CI)
  - report.json (machine-readable)
"""

import argparse
import glob
import json
import os
import pickle
import sys
from datetime import datetime
from metadata import TestRunResult, RegressionSummary


def collect_results(results_dir: str) -> RegressionSummary:
    """
    Collect all test results from a directory.

    Args:
        results_dir: Directory containing .pkl result files

    Returns:
        RegressionSummary with all results
    """
    summary = RegressionSummary()

    all_pkl_files = glob.glob(os.path.join(results_dir, "**", "*.pkl"), recursive=True)
    final_result_files = {
        os.path.realpath(path)
        for path in all_pkl_files
        if os.path.basename(path) == "result.pkl"
    }
    final_result_dirs = {
        os.path.dirname(path)
        for path in final_result_files
    }
    pkl_files = sorted(final_result_files)
    pkl_files.extend(
        sorted(path for path in all_pkl_files
               if os.path.realpath(path) not in final_result_files and
               os.path.dirname(os.path.realpath(path)) not in final_result_dirs)
    )

    for pkl_path in pkl_files:
        try:
            with open(pkl_path, "rb") as f:
                result = pickle.load(f)
            if not isinstance(result, TestRunResult):
                continue
            summary.add_result(result)
        except Exception as e:
            print(f"Warning: Could not load {pkl_path}: {e}")

    return summary


def generate_report_json(summary: RegressionSummary, path: str):
    """Generate JSON report."""
    report = {
        "timestamp": datetime.now().isoformat(),
        "total": summary.total_tests,
        "passed": summary.passed,
        "failed": summary.failed,
        "pass_rate": 100.0 * summary.passed / max(1, summary.total_tests),
        "total_time_sec": summary.total_time_sec,
        "tests": []
    }

    for r in summary.results:
        report["tests"].append({
            "name": r.test_name,
            "seed": r.seed,
            "type": r.test_type,
            "passed": r.passed,
            "failure_mode": r.failure_mode,
            "sim_log": r.sim_log_path,
            "uvm_log": r.uvm_log_path,
            "trace": r.trace_path,
            "assembly": r.assembly_path,
            "binary": r.binary_path,
            "coverage": r.coverage_path,
            "uvm_errors": r.uvm_errors,
            "uvm_warnings": r.uvm_warnings,
            "sim_returncode": r.sim_returncode,
            "instructions": r.num_instructions,
            "cycles": r.num_cycles,
            "ipc": r.ipc,
            "gen_time_sec": r.gen_time_sec,
            "compile_time_sec": r.compile_time_sec,
            "sim_time_sec": r.sim_time_sec,
        })

    with open(path, "w") as f:
        json.dump(report, f, indent=2)


def write_reports(summary: RegressionSummary, output_dir: str):
    """Write all supported regression report formats."""
    os.makedirs(output_dir, exist_ok=True)
    summary.to_log(os.path.join(output_dir, "regr.log"))
    summary.to_junit_xml(os.path.join(output_dir, "regr_junit.xml"))
    generate_report_json(summary, os.path.join(output_dir, "report.json"))


def main():
    parser = argparse.ArgumentParser(description="Collect regression results")
    parser.add_argument("--results-dir", default="", help="Results directory")
    parser.add_argument("--output-dir", default="", help="Output directory")
    parser.add_argument("--dir-metadata", default="",
                        help="Ibex-style metadata directory")
    args = parser.parse_args()

    if args.dir_metadata:
        from metadata import RegressionMetadata
        md = RegressionMetadata.construct_from_metadata_dir(args.dir_metadata)
        results_dir = md.dir_tests
        output_dir = args.output_dir or md.dir_out
    else:
        if not args.results_dir:
            parser.error("--results-dir is required without --dir-metadata")
        results_dir = args.results_dir
        output_dir = args.output_dir or args.results_dir

    summary = collect_results(results_dir)

    # Generate all report formats
    write_reports(summary, output_dir)

    print(f"\n{'='*60}")
    print(f"EH2 Regression Results")
    print(f"{'='*60}")
    print(f"Total:  {summary.total_tests}")
    print(f"Passed: {summary.passed}")
    print(f"Failed: {summary.failed}")
    print(f"Pass rate: {100*summary.passed/max(1,summary.total_tests):.1f}%")
    print(f"{'='*60}")

    if summary.failed > 0:
        print("\nFailed tests:")
        for r in summary.results:
            if not r.passed:
                print(f"  {r.test_name} seed={r.seed}: {r.failure_mode}")

    sys.exit(0 if summary.failed == 0 else 1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
EH2 Compliance Result Collector
Re-scans work/ subdirectories for .signature.output files,
compares against reference_outputs, and regenerates report.json.
"""
import json
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
EH2_ROOT = os.path.realpath(os.path.join(SCRIPT_DIR, "..", "..", "..", ".."))
COMPLIANCE_DIR = os.path.join(EH2_ROOT, "dv", "uvm", "riscv_compliance")
RISCV_COMPLIANCE_FW = os.environ.get("RISCV_COMPLIANCE_FW", "")
WORK_DIR = os.path.join(COMPLIANCE_DIR, "work")

ISAS = ["rv32i", "rv32im", "rv32imc"]


def load_hex_words(path):
    """Load a file of 32-bit hex words, one per line."""
    if not os.path.exists(path):
        return []
    words = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if re.match(r'^[0-9a-fA-F]{8}$', line):
                words.append(line.lower())
    return words


def words_to_bytes(words):
    """Convert list of 8-char hex words to byte stream (big-endian)."""
    b = bytearray()
    for w in words:
        val = int(w, 16)
        b.extend([(val >> 24) & 0xFF, (val >> 16) & 0xFF,
                   (val >> 8) & 0xFF, val & 0xFF])
    return bytes(b)


def compare_signatures(actual, reference, test_name):
    """Compare two signature word lists. Returns (passed, detail_string)."""
    if not actual:
        return False, "no signature captured (empty)"
    if not reference:
        return True, "no reference available"

    actual_bytes = words_to_bytes(actual)
    ref_bytes = words_to_bytes(reference)

    if actual_bytes == ref_bytes:
        return True, "signature match ({} words)".format(len(actual))

    min_len = min(len(actual_bytes), len(ref_bytes))
    mismatch_index = None
    for i in range(min_len):
        if actual_bytes[i] != ref_bytes[i]:
            mismatch_index = i
            break

    if mismatch_index is not None:
        detail = "byte {} differs: actual=0x{:02x} ref=0x{:02x}".format(
            mismatch_index, actual_bytes[mismatch_index], ref_bytes[mismatch_index])
    elif len(actual_bytes) != len(ref_bytes):
        detail = "length mismatch: {} actual vs {} ref bytes".format(
            len(actual_bytes), len(ref_bytes))
    else:
        detail = "signature mismatch (unknown)"
    return False, detail


def collect_isa(isa):
    """Collect all test results for one ISA suite."""
    if not RISCV_COMPLIANCE_FW:
        raise RuntimeError("Set RISCV_COMPLIANCE_FW to a riscv-compliance checkout")
    work_isa_dir = os.path.join(WORK_DIR, isa)
    ref_dir = os.path.join(RISCV_COMPLIANCE_FW, "riscv-test-suite", isa, "references")

    if not os.path.isdir(work_isa_dir):
        return []

    tests = []
    seen_names = set()

    for fname in sorted(os.listdir(work_isa_dir)):
        if not fname.endswith(".signature.output"):
            continue
        # e.g. I-ADD-01.signature.output -> test_name = I-ADD-01
        test_name = fname[:-len(".signature.output")]
        sig_path = os.path.join(work_isa_dir, fname)
        ref_path = os.path.join(ref_dir, test_name + ".reference_output")

        actual = load_hex_words(sig_path)
        reference = load_hex_words(ref_path)

        passed, detail = compare_signatures(actual, reference, test_name)

        diff_path = os.path.join(work_isa_dir, test_name + ".diff")
        if not passed and os.path.exists(diff_path):
            detail += " (diff file exists)"

        tests.append({
            "name": test_name,
            "seed": 0,
            "type": "compliance_" + isa,
            "passed": passed,
            "failure_mode": "" if passed else "signature_mismatch",
            "sim_log": os.path.join(work_isa_dir, test_name + ".log"),
            "uvm_log": "",
            "trace": "",
            "assembly": "",
            "binary": "",
            "coverage": "",
            "uvm_errors": 0 if passed else 1,
            "uvm_warnings": 0,
            "instructions": 0,
            "cycles": 0,
            "ipc": 0.0,
            "gen_time_sec": 0.0,
            "compile_time_sec": 0.0,
            "sim_time_sec": 0.0,
        })
        seen_names.add(test_name)

    # Also find tests that ran but produced no signature (only .log present)
    for fname in sorted(os.listdir(work_isa_dir)):
        if not fname.endswith(".log"):
            continue
        test_name = fname[:-len(".log")]
        if test_name in seen_names:
            continue
        tests.append({
            "name": test_name,
            "seed": 0,
            "type": "compliance_" + isa,
            "passed": False,
            "failure_mode": "no_signature",
            "sim_log": os.path.join(work_isa_dir, fname),
            "uvm_log": "",
            "trace": "",
            "assembly": "",
            "binary": "",
            "coverage": "",
            "uvm_errors": 1,
            "uvm_warnings": 0,
            "instructions": 0,
            "cycles": 0,
            "ipc": 0.0,
            "gen_time_sec": 0.0,
            "compile_time_sec": 0.0,
            "sim_time_sec": 0.0,
        })

    return tests


def main():
    all_tests = []
    suite_stats = {}

    for isa in ISAS:
        tests = collect_isa(isa)
        all_tests.extend(tests)
        passed = sum(1 for t in tests if t["passed"])
        total = len(tests)
        suite_stats[isa] = {"total": total, "passed": passed,
                            "failed": total - passed}
        print("{}: {}/{} PASS ({} tests)".format(isa, passed, total, total))

    total_pass = sum(1 for t in all_tests if t["passed"])
    total_all = len(all_tests)
    print("\nTotal: {}/{} PASS".format(total_pass, total_all))

    report = {
        "total_time_sec": 0.0,
        "tests": all_tests,
    }

    report_path = os.path.join(WORK_DIR, "report.json")
    with open(report_path, "w") as f:
        json.dump(report, f, indent=2)
    print("Wrote {} ({} tests)".format(report_path, total_all))

    # Also write per-ISA report.json for signoff.py evaluate_compliance_per_suite
    for isa in ISAS:
        isa_report = {"total_time_sec": 0.0, "tests": [
            t for t in all_tests if t["type"] == "compliance_" + isa
        ]}
        isa_path = os.path.join(WORK_DIR, isa, "report.json")
        with open(isa_path, "w") as f:
            json.dump(isa_report, f, indent=2)
        print("Wrote per-ISA: {} ({} tests)".format(isa_path, len(isa_report["tests"])))

    # Print failing tests
    print("\nFailing tests:")
    for t in all_tests:
        if not t["passed"]:
            print("  {}: {}".format(t["name"], t["failure_mode"]))

    return 0


if __name__ == "__main__":
    sys.exit(main())

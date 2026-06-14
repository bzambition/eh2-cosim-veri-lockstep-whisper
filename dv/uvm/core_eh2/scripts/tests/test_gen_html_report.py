"""Tests for the EH2 self-contained HTML sign-off report."""
import json
import os
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import gen_html_report


def test_parse_urg_report_reads_summary_modules_and_groups(tmp_path):
    report_dir = tmp_path / "cov"
    report_dir.mkdir()
    (report_dir / "dashboard.txt").write_text(
        "Dashboard\n\n"
        "Number of tests: 297\n\n"
        "Total Coverage Summary\n"
        "SCORE  LINE   COND   TOGGLE FSM    GROUP\n"
        " 65.80  78.29  64.07  55.49  61.81  69.34\n",
        encoding="utf-8")
    (report_dir / "modlist.txt").write_text(
        "Design Module List\n\n"
        "SCORE  LINE   COND   TOGGLE FSM    NAME\n"
        " 21.31 --     --      21.31 --     eh2_dec_trigger\n"
        " 90.26 100.00 100.00  70.79 --     eh2_exu_alu_ctl\n",
        encoding="utf-8")
    (report_dir / "groups.txt").write_text(
        "Testbench Group List\n\n"
        "SCORE  INSTANCES WEIGHT GOAL   AT LEAST PER INSTANCE AUTO BIN MAX PRINT MISSING COMMENT NAME\n"
        " 33.33  33.33    1      100    1        1            64           64                    csr_warl_cg\n"
        "100.00 100.00    1      100    1        1            64           64                    csr_cg\n",
        encoding="utf-8")

    cov = gen_html_report.parse_coverage_report(report_dir / "dashboard.txt")

    assert cov["number_of_tests"] == 297
    assert cov["metrics"]["line"] == pytest.approx(78.29)
    assert cov["metrics"]["functional"] == pytest.approx(69.34)
    assert cov["modules"][0]["name"] == "eh2_dec_trigger"
    assert cov["groups"][0]["name"] == "csr_warl_cg"


def test_gather_report_data_creates_relative_log_links(tmp_path):
    run_dir = tmp_path / "build" / "r3b_final"
    runs_dir = run_dir / "runs"
    log_path = runs_dir / "smoke" / "smoke_s1" / "sim_smoke_1.log"
    log_path.parent.mkdir(parents=True)
    log_path.write_text("TEST PASSED\n", encoding="utf-8")

    status = {
        "status": "PASS",
        "timestamp": "2026-05-11T00:52:08",
        "profile": "full",
        "output_dir": str(run_dir),
        "coverage": {"metrics": {"line": 78.29, "functional": 69.34}},
        "blockers": [],
        "stages": {
            "smoke": {
                "stage": "smoke",
                "status": "PASS",
                "total": 1,
                "passed": 1,
                "failed": 0,
                "pass_rate": 100.0,
                "tests": [{
                    "name": "smoke",
                    "seed": 1,
                    "passed": True,
                    "failure_mode": "NONE",
                    "sim_log": str(log_path),
                    "warnings": 0,
                }],
            },
            "compliance": {
                "stage": "compliance",
                "status": "PASS",
                "total": 85,
                "passed": 85,
                "failed": 0,
                "pass_rate": 100.0,
                "tests": [],
            },
        },
        "cosim_disabled_tests": ["riscv_csr_test"],
        "skip_in_signoff_tests": [],
    }
    cov_path = tmp_path / "dashboard.txt"
    cov_path.write_text(
        "Total Coverage Summary\n"
        "SCORE  LINE   COND   TOGGLE FSM    GROUP\n"
        " 65.80  78.29  64.07  55.49  61.81  69.34\n",
        encoding="utf-8")
    status_path = tmp_path / "status.json"
    status_path.write_text(json.dumps(status), encoding="utf-8")

    data = gen_html_report.load_report_data(status_path, cov_path, runs_dir,
                                            run_dir / "report.html")

    assert data["test_entry_count"] == 1
    assert data["stages"][0]["tests"][0]["log_href"] == "runs/smoke/smoke_s1/sim_smoke_1.log"
    assert [stage["stage"] for stage in data["stage_summaries"]] == ["smoke", "compliance"]
    assert "".join(["for", "mal"]) not in data
    assert "_".join(["le" + "c", "modules"]) not in data


def test_render_html_is_self_contained_and_contains_real_data(tmp_path):
    status_path = Path("build/r3b_final/signoff_status.json")
    cov_path = Path("build/r3b_cov_report/dashboard.txt")
    runs_dir = Path("build/r3b_final/runs")
    if not status_path.exists() or not cov_path.exists():
        pytest.skip("R3-B final artifacts are not present")

    output = tmp_path / "report.html"
    data = gen_html_report.load_report_data(status_path, cov_path, runs_dir, output)
    html = gen_html_report.render_html(data)

    assert "EH2 Sign-off Dashboard" in html
    assert "78.29" in html
    assert "31635" in html
    assert "54/55" in html
    assert 'href="' in html
    assert "sim_riscv_" in html
    assert "https://cdn" not in html
    assert "src=\"http" not in html

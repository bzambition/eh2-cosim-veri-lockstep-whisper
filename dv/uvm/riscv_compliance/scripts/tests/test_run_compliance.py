#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import run_compliance


class RunComplianceTest(unittest.TestCase):

    def test_run_simulation_reads_vcs_l_file_for_empty_signature_pass(self):
        with tempfile.TemporaryDirectory() as td:
            work_dir = Path(td)
            hex_path = work_dir / "test.hex"
            simv_path = work_dir / "simv"
            hex_path.write_text("@80000000\n", encoding="utf-8")
            simv_path.write_text("#!/bin/sh\n", encoding="utf-8")

            def fake_run(cmd, **kwargs):
                log_path = Path(cmd[cmd.index("-l") + 1])
                log_path.write_text(
                    "MAILBOX WRITE detected at 100: data=000000ff\n"
                    "TEST PASSED (mailbox)\n",
                    encoding="utf-8")
                return subprocess.CompletedProcess(cmd, 0, "", "")

            with mock.patch.object(run_compliance.subprocess, "run",
                                   side_effect=fake_run):
                passed, signature_lines, log_text = run_compliance.run_simulation(
                    hex_path=hex_path,
                    output_dir=work_dir,
                    test_name="empty_signature",
                    simv_path=simv_path,
                    simulator="vcs",
                )

            self.assertTrue(passed)
            self.assertEqual(signature_lines, [])
            self.assertIn("TEST PASSED (mailbox)", log_text)

    def test_run_compliance_accepts_empty_signature_mailbox_pass_without_ref(self):
        with tempfile.TemporaryDirectory() as td:
            work_dir = Path(td)
            src_dir = work_dir / "src"
            device_dir = work_dir / "device"
            output_dir = work_dir / "out"
            src_dir.mkdir()
            device_dir.mkdir()
            (src_dir / "add.S").write_text("", encoding="utf-8")
            (work_dir / "simv").write_text("#!/bin/sh\n", encoding="utf-8")
            hex_path = output_dir / "add.hex"

            with mock.patch.object(run_compliance, "_resolve_suite",
                                   return_value=("riscv-tests", src_dir, src_dir)), \
                 mock.patch.object(run_compliance, "find_tool",
                                   return_value="tool"), \
                 mock.patch.object(run_compliance, "compile_test",
                                   return_value=hex_path), \
                 mock.patch.object(run_compliance, "run_simulation",
                                   return_value=(True, [], "TEST PASSED (mailbox)")):
                result = run_compliance.run_compliance(
                    isa="rv32i",
                    simv_path=work_dir / "simv",
                    output_dir=output_dir,
                    device_dir=device_dir,
                )

            self.assertEqual(result["total"], 1)
            self.assertEqual(result["passed"], 1)
            self.assertEqual(result["failed"], 0)

    def test_riscv_tests_rv32i_default_run_excludes_legacy_fence_i(self):
        with tempfile.TemporaryDirectory() as td:
            work_dir = Path(td)
            src_dir = work_dir / "src"
            device_dir = work_dir / "device"
            output_dir = work_dir / "out"
            src_dir.mkdir()
            device_dir.mkdir()
            (src_dir / "add.S").write_text("", encoding="utf-8")
            (src_dir / "fence_i.S").write_text("", encoding="utf-8")
            (work_dir / "simv").write_text("#!/bin/sh\n", encoding="utf-8")
            hex_path = output_dir / "add.hex"

            with mock.patch.object(run_compliance, "_resolve_suite",
                                   return_value=("riscv-tests", src_dir, src_dir)), \
                 mock.patch.object(run_compliance, "find_tool",
                                   return_value="tool"), \
                 mock.patch.object(run_compliance, "compile_test",
                                   return_value=hex_path), \
                 mock.patch.object(run_compliance, "run_simulation",
                                   return_value=(True, [], "TEST PASSED (mailbox)")):
                result = run_compliance.run_compliance(
                    isa="rv32i",
                    simv_path=work_dir / "simv",
                    output_dir=output_dir,
                    device_dir=device_dir,
                )

            self.assertEqual(result["total"], 1)
            self.assertEqual(result["tests"][0]["name"], "add")

    def test_all_isa_expands_only_to_vendored_source_suites(self):
        self.assertEqual(
            run_compliance.ALL_ISAS,
            ["rv32i", "rv32im", "rv32imc"],
        )


if __name__ == "__main__":
    unittest.main()

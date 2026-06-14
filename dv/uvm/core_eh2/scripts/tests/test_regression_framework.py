#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import os
import sys
import tempfile
import unittest
import json
import yaml
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import run_regress
import run_rtl
import run_instr_gen
import render_config_template
import check_logs
import compile_tb
import compile_test
import collect_results as results_gatherer
import directed_test_schema
import metadata
import signoff
from metadata import RegressionMetadata, TestRunResult


class RegressionFrameworkTest(unittest.TestCase):

    def test_generated_assembly_path_matches_riscv_dv_layout(self):
        with tempfile.TemporaryDirectory() as td:
            work_dir = Path(td)
            asm_dir = work_dir / "asm_test"
            asm_dir.mkdir()
            expected = asm_dir / "riscv_arithmetic_basic_test_0.S"
            expected.write_text(".section .text\n", encoding="utf-8")

            found = run_regress.find_generated_asm(
                str(work_dir), "riscv_arithmetic_basic_test")

            self.assertEqual(Path(found), expected)

    def test_cosim_disabled_metadata_appends_disable_plusarg(self):
        entry = {
            "test": "riscv_csr_test",
            "rtl_test": "core_eh2_base_test",
            "sim_opts": "+enable_irq_seq=1",
            "cosim": "disabled",
        }

        sim_opts = run_regress.build_sim_opts(entry, "")

        self.assertIn("+enable_irq_seq=1", sim_opts)
        self.assertIn("+disable_cosim=1", sim_opts)
        self.assertNotIn("+enable_cosim=1", sim_opts)

    def test_cosim_enabled_metadata_appends_enable_plusarg(self):
        entry = {
            "test": "riscv_arithmetic_basic_test",
            "rtl_test": "core_eh2_base_test",
        }

        sim_opts = run_regress.build_sim_opts(entry, "")

        self.assertIn("+enable_cosim=1", sim_opts)
        self.assertNotIn("+disable_cosim=1", sim_opts)

    def test_rvvi_sim_opts_adds_matching_elf_path(self):
        sim_opts = run_regress.add_rvvi_elf_sim_opt(
            "+use_rvvi_cosim=1 +enable_cosim=1",
            "build/regress_vcs/cosim_smoke_s1/cosim_smoke.hex")

        self.assertIn("+use_rvvi_cosim=1", sim_opts)
        self.assertIn(
            "+rvvi_elf=build/regress_vcs/cosim_smoke_s1/cosim_smoke.elf",
            sim_opts)

    def test_rvvi_sim_opts_preserves_explicit_elf_path(self):
        sim_opts = run_regress.add_rvvi_elf_sim_opt(
            "+use_rvvi_cosim=1 +rvvi_elf=custom.elf",
            "build/regress_vcs/cosim_smoke_s1/cosim_smoke.hex")

        self.assertEqual(
            sim_opts,
            "+use_rvvi_cosim=1 +rvvi_elf=custom.elf")

    def test_rvvi_scoreboard_mismatch_is_fatal(self):
        scoreboard = (
            SCRIPT_DIR.parent / "common" / "rvvi_agent" /
            "eh2_rvvi_scoreboard.sv").read_text(encoding="utf-8")

        self.assertIn("RVVI_METRIC_ERRORS", scoreboard)
        self.assertIn("saw_error", scoreboard)
        self.assertIn('$fatal(1, "RVVI_SCOREBOARD: online lockstep failed")',
                      scoreboard)

    def test_rvvi_scoreboard_stages_async_writebacks_before_compare(self):
        scoreboard = (
            SCRIPT_DIR.parent / "common" / "rvvi_agent" /
            "eh2_rvvi_scoreboard.sv").read_text(encoding="utf-8")
        tb_top = (SCRIPT_DIR.parent / "tb" /
                  "core_eh2_tb_top.sv").read_text(encoding="utf-8")

        self.assertIn("pending_retire_q", scoreboard)
        self.assertIn("async_wb_q", scoreboard)
        self.assertIn("nb_load_wen", scoreboard)
        self.assertIn("needs_async_wb", scoreboard)
        self.assertIn("try_consume_async_wb", scoreboard)
        self.assertIn("rvviDutGprSet(retire_evt.hart, async_hint.rd",
                      scoreboard)
        self.assertIn(".nb_load_wen", tb_top)
        self.assertIn("dut_probe_intf.nb_load_wen", tb_top)
        self.assertIn(".div_wren", tb_top)
        self.assertIn("dut_probe_intf.div_wren", tb_top)

    def test_rvvi_traps_are_stepped_not_skipped(self):
        scoreboard = (
            SCRIPT_DIR.parent / "common" / "rvvi_agent" /
            "eh2_rvvi_scoreboard.sv").read_text(encoding="utf-8")
        spike_rvvi = (SCRIPT_DIR.parents[3] / "dv" / "cosim" /
                      "spike_rvvi.cc").read_text(encoding="utf-8")
        spike_cosim = (SCRIPT_DIR.parents[3] / "dv" / "cosim" /
                       "spike_cosim.cc").read_text(encoding="utf-8")

        self.assertIn("rvviDutTrap(retire_evt.hart", scoreboard)
        self.assertIn("rvviRefEventStep(retire_evt.hart)", scoreboard)
        self.assertNotIn("MR3a is smoke-only: no async/trap lockstep",
                         scoreboard)
        self.assertIn("g_dut[hartId].trap = true", spike_rvvi)
        self.assertIn("ref_last_trap", spike_cosim)
        self.assertIn("RVVI_METRIC_TRAPS", spike_rvvi)

    def test_rvvi_standard_csr_compare_is_enabled_by_default(self):
        spike_rvvi = (SCRIPT_DIR.parents[3] / "dv" / "cosim" /
                      "spike_rvvi.cc").read_text(encoding="utf-8")

        self.assertIn("enable_standard_csr_compare()", spike_rvvi)
        self.assertIn("kComparedCsrs", spike_rvvi)
        for csr in ("CSR_MSTATUS", "CSR_MTVEC", "CSR_MEPC", "CSR_MCAUSE",
                    "CSR_MTVAL", "CSR_MIP"):
            self.assertIn(csr, spike_rvvi)
        self.assertIn("g_csr_compare_enable[hart][csr] = true", spike_rvvi)

    def test_rvvi_scoreboard_surfaces_async_nets_and_bus_writes(self):
        scoreboard = (
            SCRIPT_DIR.parent / "common" / "rvvi_agent" /
            "eh2_rvvi_scoreboard.sv").read_text(encoding="utf-8")
        tb_top = (SCRIPT_DIR.parent / "tb" /
                  "core_eh2_tb_top.sv").read_text(encoding="utf-8")
        spike_rvvi = (SCRIPT_DIR.parents[3] / "dv" / "cosim" /
                      "spike_rvvi.cc").read_text(encoding="utf-8")

        self.assertIn("rvviRefNetIndexGet(\"MIP\")", scoreboard)
        self.assertIn("rvviRefNetSet(mip_net_idx", scoreboard)
        self.assertIn("rvviDutBusWrite(h, longint'(lsu_bus_addr)",
                      scoreboard)
        self.assertNotIn("rvviDutBusWrite(0", scoreboard)
        self.assertRegex(tb_top,
                         r"\.mip\s*\(\s*dut_probe_intf\.mip\s*\)")
        self.assertRegex(tb_top,
                         r"\.nmi\s*\(\s*dut_probe_intf\.nmi\s*\)")
        self.assertRegex(tb_top,
                         r"\.debug_req\s*\(\s*dut_probe_intf\.debug_req\s*\)")
        self.assertRegex(tb_top,
                         r"\.lsu_bus_write\s*\(\s*lsu_bus_write\s*\)")
        self.assertIn("write_mem(address + byte", spike_rvvi)

    def test_rvvi_async_interrupt_only_events_are_not_skipped(self):
        scoreboard = (
            SCRIPT_DIR.parent / "common" / "rvvi_agent" /
            "eh2_rvvi_scoreboard.sv").read_text(encoding="utf-8")
        spike_rvvi = (SCRIPT_DIR.parents[3] / "dv" / "cosim" /
                      "spike_rvvi.cc").read_text(encoding="utf-8")
        spike_cosim = (SCRIPT_DIR.parents[3] / "dv" / "cosim" /
                       "spike_cosim.cc").read_text(encoding="utf-8")

        self.assertIn("task automatic process_async_interrupt", scoreboard)
        self.assertIn("process_async_interrupt(retire_evt)", scoreboard)
        self.assertNotIn("async interrupt injection ordering is handled in MR3b hardening",
                         scoreboard)
        self.assertIn("ref_async_event_pending(hartId)", spike_rvvi)
        self.assertIn("ref_async_event_pending", spike_cosim)

    def test_testlist_marks_known_non_cosim_tests_disabled(self):
        testlist_path = SCRIPT_DIR.parent / "riscv_dv_extension" / "testlist.yaml"
        entries = yaml.safe_load(testlist_path.read_text(encoding="utf-8"))
        by_name = {entry["test"]: entry for entry in entries}

        self.assertNotEqual(by_name["riscv_arithmetic_basic_test"].get("cosim"),
                            "disabled")
        self.assertEqual(by_name["riscv_csr_test"].get("cosim"), "disabled")
        self.assertNotEqual(by_name["riscv_pmp_random_test"].get("cosim"),
                            "disabled")

    def test_run_rtl_uses_shared_build_and_out_log(self):
        md = RegressionMetadata()
        md.test_name = "smoke"
        md.seed = 7
        md.binary_path = "/tmp/smoke.hex"
        md.simulator = "vcs"
        md.rtl_test = "core_eh2_base_test"
        md.sim_opts = "+disable_cosim=1"
        md.build_dir = str(Path("/tmp/eh2-build"))
        md.out_dir = str(Path("/tmp/eh2-out"))
        md.sim_time_ns = 12345

        cfg_path = Path(run_rtl.__file__).resolve().parents[1] / "yaml" / "rtl_simulation.yaml"
        cmd = run_rtl.build_sim_cmd(md, run_rtl.load_sim_config(str(cfg_path)))

        self.assertIn("/tmp/eh2-build/simv", cmd)
        self.assertIn("-l /tmp/eh2-out/sim_smoke_7.log", cmd)
        self.assertIn("+timeout_ns=12345", cmd)
        self.assertNotIn("cd /tmp/eh2-build", cmd)

    def test_vcs_waves_enable_verdi_uvm_hierarchy_recording(self):
        md = RegressionMetadata()
        md.test_name = "smoke"
        md.seed = 7
        md.binary_path = "/tmp/smoke.hex"
        md.simulator = "vcs"
        md.rtl_test = "core_eh2_base_test"
        md.build_dir = str(Path("/tmp/eh2-build"))
        md.out_dir = str(Path("/tmp/eh2-out"))
        md.waves = True

        cfg_path = Path(run_rtl.__file__).resolve().parents[1] / "yaml" / "rtl_simulation.yaml"
        cmd = run_rtl.build_sim_cmd(md, run_rtl.load_sim_config(str(cfg_path)))

        self.assertIn("+UVM_VERDI_TRACE=UVM_AWARE+RAL+HIER+COMPWAVE", cmd)
        self.assertIn("+UVM_TR_RECORD", cmd)
        self.assertIn("-ucli -do", cmd)

    def test_run_rtl_skips_compile_when_simv_exists(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            build_dir = root / "build"
            out_dir = root / "out"
            yaml_dir = root / "dv" / "uvm" / "core_eh2" / "yaml"
            build_dir.mkdir()
            yaml_dir.mkdir(parents=True)
            (build_dir / "simv").write_text("#!/bin/sh\n", encoding="utf-8")
            (yaml_dir / "rtl_simulation.yaml").write_text(
                "vcs:\n"
                "  sim:\n"
                "    cmd: >\n"
                "      <build_dir>/simv +bin=<binary> +seed=<seed>\n"
                "      -l <out_dir>/sim_<test>_<seed>.log\n",
                encoding="utf-8")

            md = RegressionMetadata()
            md.test_name = "smoke"
            md.seed = 1
            md.binary_path = "/tmp/smoke.hex"
            md.simulator = "vcs"
            md.rtl_test = "core_eh2_base_test"
            md.build_dir = str(build_dir)
            md.out_dir = str(out_dir)
            md.eh2_root = str(root)

            calls = []

            def fake_run(cmd, log_path, timeout=3600, env=None):
                calls.append((cmd, log_path, timeout))
                del cmd, timeout, env
                Path(log_path).write_text("TEST PASSED (signature)\n",
                                          encoding="utf-8")
                return 0

            with mock.patch.object(run_rtl, "run_command", fake_run):
                result = run_rtl.run_rtl_simulation(md)

            self.assertTrue(result.passed)
            self.assertEqual(len(calls), 1)
            self.assertEqual(result.sim_log_path,
                             str(out_dir / "sim_smoke_1.log"))

    def test_run_rtl_requires_pass_signature_even_with_zero_returncode(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            build_dir = root / "build"
            out_dir = root / "out"
            yaml_dir = root / "dv" / "uvm" / "core_eh2" / "yaml"
            build_dir.mkdir()
            yaml_dir.mkdir(parents=True)
            (build_dir / "simv").write_text("#!/bin/sh\n", encoding="utf-8")
            (yaml_dir / "rtl_simulation.yaml").write_text(
                "vcs:\n"
                "  sim:\n"
                "    cmd: >\n"
                "      <build_dir>/simv +bin=<binary> +seed=<seed>\n"
                "      -l <out_dir>/sim_<test>_<seed>.log\n",
                encoding="utf-8")

            md = RegressionMetadata()
            md.test_name = "smoke"
            md.seed = 1
            md.binary_path = "/tmp/smoke.hex"
            md.simulator = "vcs"
            md.build_dir = str(build_dir)
            md.out_dir = str(out_dir)
            md.eh2_root = str(root)

            def fake_run(cmd, log_path, timeout=3600, env=None):
                del cmd, timeout, env
                Path(log_path).write_text("UVM_INFO stopped cleanly\n",
                                          encoding="utf-8")
                return 0

            with mock.patch.object(run_rtl, "run_command", fake_run):
                result = run_rtl.run_rtl_simulation(md)

            self.assertFalse(result.passed)
            self.assertEqual(result.failure_mode, "NO_PASS_SIGNATURE")

    def test_run_rtl_fails_when_sim_command_config_is_missing(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            build_dir = root / "build"
            out_dir = root / "out"
            build_dir.mkdir()
            (build_dir / "simv").write_text("#!/bin/sh\n", encoding="utf-8")

            md = RegressionMetadata()
            md.test_name = "smoke"
            md.seed = 1
            md.binary_path = "/tmp/smoke.hex"
            md.simulator = "vcs"
            md.build_dir = str(build_dir)
            md.out_dir = str(out_dir)
            md.eh2_root = str(root)

            result = run_rtl.run_rtl_simulation(md)

            self.assertFalse(result.passed)
            self.assertEqual(result.failure_mode, "CONFIG_ERROR")

    def test_run_rtl_metadata_mode_applies_directed_cosim_policy(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=1 TEST=directed_smoke SIMULATOR=vcs ITERATIONS=1",
            ])
            test_dir = out_dir / "run" / "tests" / "directed_smoke.1"
            test_dir.mkdir(parents=True)
            (test_dir / "test.hex").write_text("@80000000\n13 00 00 00\n",
                                                encoding="utf-8")
            captured = {}

            def fake_run(md):
                captured["md"] = md
                trr = TestRunResult()
                trr.test_name = md.test_name
                trr.seed = md.seed
                trr.passed = True
                trr.failure_mode = "NONE"
                trr.sim_log_path = str(Path(md.out_dir) /
                                       "sim_directed_smoke_1.log")
                return trr

            with mock.patch.object(run_rtl, "run_rtl_simulation", fake_run):
                run_rtl.run_from_metadata(str(md_dir), "directed_smoke.1")

            self.assertEqual(captured["md"].rtl_test, "core_eh2_base_test")
            self.assertEqual(captured["md"].test_type, "DIRECTED")
            self.assertIn("+disable_cosim=1", captured["md"].sim_opts)

    def test_run_rtl_metadata_mode_applies_cosim_testlist_policy(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=1 TEST=cosim_smoke SIMULATOR=vcs ITERATIONS=1",
            ])
            test_dir = out_dir / "run" / "tests" / "cosim_smoke.1"
            test_dir.mkdir(parents=True)
            (test_dir / "test.hex").write_text("@80000000\n13 00 00 00\n",
                                                encoding="utf-8")
            captured = {}

            def fake_run(md):
                captured["md"] = md
                trr = TestRunResult()
                trr.test_name = md.test_name
                trr.seed = md.seed
                trr.passed = True
                trr.failure_mode = "NONE"
                trr.sim_log_path = str(Path(md.out_dir) /
                                       "sim_cosim_smoke_1.log")
                return trr

            with mock.patch.object(run_rtl, "run_rtl_simulation", fake_run):
                run_rtl.run_from_metadata(str(md_dir), "cosim_smoke.1")

            self.assertEqual(captured["md"].rtl_test, "core_eh2_cosim_test")
            self.assertEqual(captured["md"].test_type, "DIRECTED")
            self.assertIn("+enable_cosim=1", captured["md"].sim_opts)
            self.assertNotIn("+disable_cosim=1", captured["md"].sim_opts)

    def test_run_rtl_metadata_mode_skips_missing_binary_after_compile_failure(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=1 TEST=riscv_arithmetic_basic_test SIMULATOR=vcs "
                "ITERATIONS=1",
            ])
            test_dir = out_dir / "run" / "tests" / \
                "riscv_arithmetic_basic_test.1"
            test_dir.mkdir(parents=True)
            compile_log = test_dir / "compile.log"
            compile_log.write_text("compiler failed\n", encoding="utf-8")
            recorded = TestRunResult()
            recorded.test_name = "riscv_arithmetic_basic_test"
            recorded.seed = 1
            recorded.failure_mode = "COMPILE_ERROR"
            recorded.sim_log_path = str(compile_log)
            recorded.save(str(test_dir / "result"))

            with mock.patch.object(run_rtl, "run_rtl_simulation") as fake_run:
                result = run_rtl.run_from_metadata(
                    str(md_dir), "riscv_arithmetic_basic_test.1")

            fake_run.assert_not_called()
            self.assertFalse(result.passed)
            self.assertEqual(result.failure_mode, "COMPILE_ERROR")
            self.assertTrue(Path(result.sim_log_path).exists())
            self.assertIn("compiler failed",
                          Path(result.sim_log_path).read_text(
                              encoding="utf-8"))

    def test_run_rtl_metadata_mode_applies_riscvdv_entry_sim_opts(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=3 TEST=riscv_random_instr_test SIMULATOR=vcs "
                "ITERATIONS=1",
            ])
            test_dir = out_dir / "run" / "tests" / \
                "riscv_random_instr_test.3"
            test_dir.mkdir(parents=True)
            (test_dir / "test.hex").write_text("@80000000\n13 00 00 00\n",
                                                encoding="utf-8")
            captured = {}

            def fake_run(md):
                captured["md"] = md
                trr = TestRunResult()
                trr.test_name = md.test_name
                trr.seed = md.seed
                trr.passed = True
                trr.failure_mode = "NONE"
                trr.sim_log_path = str(Path(md.out_dir) /
                                       "sim_riscv_random_instr_test_3.log")
                return trr

            with mock.patch.object(run_rtl, "run_rtl_simulation", fake_run):
                run_rtl.run_from_metadata(str(md_dir),
                                          "riscv_random_instr_test.3")

            # random_instr_test sim_opts should set up RVVI cosim + the
            # raised cycle/timeout limits the binary needs to walk through
            # interrupt handling. +enable_irq_seq was removed because it kept
            # the binary in a permanent IRQ loop preventing PASS detection
            # (see commit ea81409 / cosim-correctness #05).
            self.assertIn("+max_cycles=2000000", captured["md"].sim_opts)
            self.assertIn("+timeout_ns=200000000", captured["md"].sim_opts)
            self.assertIn("+enable_cosim=1", captured["md"].sim_opts)

    def test_run_instr_gen_resolves_riscv_dv_path_before_chdir(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            riscv_dv = root / "riscv-dv"
            work_dir = root / "work"
            riscv_dv.mkdir()
            run_py = riscv_dv / "run.py"
            run_py.write_text("#!/usr/bin/env python3\n", encoding="utf-8")

            captured = {}

            class FakeProc:
                returncode = 0
                stdout = b""

            def fake_run(cmd, stdout, stderr, timeout, cwd):
                del stdout, stderr, timeout
                captured["cmd"] = cmd
                captured["cwd"] = cwd
                return FakeProc()

            old_cwd = os.getcwd()
            try:
                os.chdir(root)
                with mock.patch.object(run_instr_gen.subprocess, "run", fake_run):
                    ok = run_instr_gen.run_instr_gen(
                        "riscv-dv", str(work_dir),
                        "riscv_arithmetic_basic_test", "", 1)
            finally:
                os.chdir(old_cwd)

            self.assertTrue(ok)
            self.assertEqual(Path(captured["cmd"][1]), run_py.resolve())
            self.assertEqual(Path(captured["cwd"]), work_dir)

    def test_run_instr_gen_writes_gen_opts_to_overlay_testlist(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            riscv_dv = root / "riscv-dv"
            work_dir = root / "work"
            riscv_dv.mkdir()
            (riscv_dv / "run.py").write_text("#!/usr/bin/env python3\n",
                                             encoding="utf-8")

            captured = {}

            class FakeProc:
                returncode = 0
                stdout = b""

            def fake_run(cmd, stdout, stderr, timeout, cwd):
                del stdout, stderr, timeout
                captured["cmd"] = cmd
                captured["cwd"] = cwd
                return FakeProc()

            with mock.patch.object(run_instr_gen.subprocess, "run", fake_run):
                ok = run_instr_gen.run_instr_gen(
                    str(riscv_dv), str(work_dir),
                    "riscv_arithmetic_basic_test", "+instr_cnt=10", 1)

            self.assertTrue(ok)
            self.assertNotIn("+instr_cnt=10", captured["cmd"])
            self.assertIn("--testlist", captured["cmd"])
            testlist = Path(captured["cmd"][captured["cmd"].index("--testlist") + 1])
            self.assertTrue(testlist.exists())
            self.assertIn("+instr_cnt=10",
                          testlist.read_text(encoding="utf-8"))

    def test_run_instr_gen_enables_eh2_asm_generator_override(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            riscv_dv = root / "riscv-dv"
            work_dir = root / "work"
            riscv_dv.mkdir()
            (riscv_dv / "run.py").write_text("#!/usr/bin/env python3\n",
                                             encoding="utf-8")
            captured = {}

            class FakeProc:
                returncode = 0
                stdout = b""

            def fake_run(cmd, stdout, stderr, timeout, cwd):
                del stdout, stderr, timeout, cwd
                captured["cmd"] = cmd
                return FakeProc()

            with mock.patch.object(run_instr_gen.subprocess, "run", fake_run):
                ok = run_instr_gen.run_instr_gen(
                    str(riscv_dv), str(work_dir),
                    "riscv_arithmetic_basic_test", "+instr_cnt=10", 1)

            self.assertTrue(ok)
            self.assertIn("--sim_opts", captured["cmd"])
            sim_opts = captured["cmd"][captured["cmd"].index("--sim_opts") + 1]
            self.assertIn(
                "+uvm_set_inst_override=riscv_asm_program_gen,"
                "eh2_asm_program_gen,uvm_test_top.asm_gen",
                sim_opts)
            self.assertIn("+require_signature_addr=1", sim_opts)
            self.assertIn("+signature_addr=d0580000", sim_opts)

    def test_riscv_dv_setting_uses_current_riscv_dv_types(self):
        setting = (SCRIPT_DIR.parent / "riscv_dv_extension" /
                   "riscv_core_setting.sv").read_text(encoding="utf-8")

        self.assertIn("riscv_instr_group_t supported_isa[$]", setting)
        self.assertIn("privileged_mode_t supported_privileged_mode[]", setting)
        self.assertIn("const privileged_reg_t implemented_csr[]", setting)
        self.assertIn("bit support_pmp", setting)
        self.assertIn("bit support_debug_mode", setting)
        self.assertNotIn("parameter string supported_isa", setting)
        self.assertNotIn("parameter bit [11:0] implemented_csr", setting)

    def test_eh2_asm_program_gen_has_single_hart_init_override(self):
        program_gen = (SCRIPT_DIR.parent / "riscv_dv_extension" /
                       "eh2_asm_program_gen.sv").read_text(encoding="utf-8")

        self.assertEqual(program_gen.count(
            "virtual function void gen_init_section(int hart);"), 1)
        self.assertNotIn("virtual function void gen_init_section();",
                         program_gen)
        self.assertIn("super.gen_init_section(hart);", program_gen)
        self.assertIn("virtual function void gen_test_done();", program_gen)
        self.assertIn("virtual function void gen_test_end", program_gen)
        self.assertIn("virtual function void gen_program_end(int hart);",
                      program_gen)
        self.assertIn("virtual function void gen_ecall_handler(int hart);",
                      program_gen)
        self.assertNotIn("h%0d_mtvec_handler", program_gen)
        self.assertNotIn("void'(hart);", program_gen)
        self.assertNotIn("virtual function void init_custom_csr(int hart);",
                         program_gen)
        self.assertIn('instr_stream.push_back({indent, "j main"});',
                      program_gen)

    def test_base_test_installs_eh2_report_server(self):
        base_test = (SCRIPT_DIR.parent / "tests" /
                     "core_eh2_base_test.sv").read_text(encoding="utf-8")

        self.assertIn("core_eh2_report_server eh2_report_server;", base_test)
        self.assertIn("uvm_report_server::set_server(eh2_report_server);",
                      base_test)

    def test_eh2_report_server_pass_fail_ignores_warnings(self):
        report_server = (SCRIPT_DIR.parent / "tests" /
                         "core_eh2_report_server.sv").read_text(
                             encoding="utf-8")

        self.assertIn("get_severity_count(UVM_ERROR)", report_server)
        self.assertIn("get_severity_count(UVM_FATAL)", report_server)
        self.assertNotIn("get_severity_count(UVM_WARNING)", report_server)

    def test_eh2_directed_streams_use_instr_list_member(self):
        directed_lib = (SCRIPT_DIR.parent / "riscv_dv_extension" /
                        "eh2_directed_instr_lib.sv").read_text(encoding="utf-8")

        self.assertNotIn("instr_stream.push_back", directed_lib)
        self.assertIn("instr_list.push_back", directed_lib)
        self.assertNotIn("riscv_instr::get_instr(LI)", directed_lib)
        self.assertIn("riscv_pseudo_instr::type_id::create", directed_lib)
        self.assertIn("bit is_debug_program = 0", directed_lib)

    def test_tb_connections_match_eh2_signal_widths(self):
        tb_top = (SCRIPT_DIR.parent / "tb" /
                  "core_eh2_tb_top.sv").read_text(encoding="utf-8")
        fcov_if = (SCRIPT_DIR.parent / "fcov" /
                   "eh2_fcov_if.sv").read_text(encoding="utf-8")

        self.assertNotIn("extintsrc_req[0]", tb_top)
        self.assertIn("extintsrc_req[1]", tb_top)
        self.assertIn("input logic [3:0]  dec_tlu_meicurpl", fcov_if)
        self.assertIn("input logic [3:0]  dec_tlu_meicidpl", fcov_if)

    def test_pmp_fcov_interface_is_instantiated_disabled_by_default(self):
        tb_top = (SCRIPT_DIR.parent / "tb" /
                  "core_eh2_tb_top.sv").read_text(encoding="utf-8")
        setting = (SCRIPT_DIR.parent / "riscv_dv_extension" /
                   "riscv_core_setting.sv").read_text(encoding="utf-8")

        self.assertIn("bit support_pmp = 0;", setting)
        self.assertIn("eh2_pmp_fcov_if", tb_top)
        self.assertIn("u_pmp_fcov_if", tb_top)
        self.assertIn(".PMPEnable      (1'b0)", tb_top)
        self.assertIn(".pmp_cfg_lock   ('0)", tb_top)
        self.assertIn(".pmp_addr       ('0)", tb_top)

    def test_rvvi_scoreboard_fails_if_enabled_but_no_steps_execute(self):
        scoreboard = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
                      "eh2_rvvi_scoreboard.sv").read_text(encoding="utf-8")

        self.assertIn("test_done", scoreboard)
        self.assertIn("saw_error", scoreboard)
        self.assertIn("retire count mismatch", scoreboard)
        self.assertIn("RVVI_METRIC_MISMATCHES", scoreboard)
        self.assertIn("RVVI_METRIC_ERRORS", scoreboard)
        self.assertIn('$fatal(1, "RVVI_SCOREBOARD: online lockstep failed")',
                      scoreboard)

    def test_rvvi_scoreboard_async_sources_prevent_cross_source_matches(self):
        scoreboard = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
                      "eh2_rvvi_scoreboard.sv").read_text(encoding="utf-8")

        self.assertIn("WB_SRC_DIV", scoreboard)
        self.assertIn("WB_SRC_NB_LOAD", scoreboard)
        self.assertIn("async_source_for", scoreboard)
        self.assertIn("async_wb_q[retire_evt.hart][i].source != need_source",
                      scoreboard)
        self.assertIn("pending_retire_q", scoreboard)
        self.assertNotIn("wb_source_matches", scoreboard)

    def test_spike_cosim_allows_suppressed_div_writebacks(self):
        spike_cc = (SCRIPT_DIR.parents[3] / "dv" / "cosim" /
                    "spike_cosim.cc").read_text(encoding="utf-8")
        spike_h = (SCRIPT_DIR.parents[3] / "dv" / "cosim" /
                   "spike_cosim.h").read_text(encoding="utf-8")

        self.assertIn("bool pc_is_div_or_rem(uint32_t pc);", spike_h)
        self.assertIn("bool SpikeCosim::pc_is_div_or_rem", spike_cc)
        self.assertIn("funct7 == 0x01 && funct3 >= 0x4 && funct3 <= 0x7",
                      spike_cc)
        self.assertIn("!pc_is_load(pc) && !pc_is_div_or_rem(pc)", spike_cc)
        self.assertIn("not a load/div", spike_cc)

    def test_axi_memory_hex_loader_consumes_parse_return_values(self):
        mem_model = (SCRIPT_DIR.parents[3] / "shared" / "rtl" /
                     "axi4_slave_mem.sv").read_text(encoding="utf-8")

        self.assertIn("fgets_status = $fgets(line, fd);", mem_model)
        self.assertIn("scan_status = $sscanf(line, \"@%h\", addr);",
                      mem_model)
        self.assertIn("scan_status = $sscanf(line, \"%h\", data);",
                      mem_model)
        self.assertNotIn("      $fgets(line, fd);", mem_model)
        self.assertNotIn("        $sscanf(line, \"@%h\", addr);",
                         mem_model)
        self.assertNotIn("        $sscanf(line, \"%h\", data);",
                         mem_model)

    def test_vcs_compile_inputs_avoid_known_command_warnings(self):
        root = SCRIPT_DIR.parents[3]
        makefile = (root / "Makefile").read_text(encoding="utf-8")
        rtl_f = (root / "dv" / "uvm" / "core_eh2" /
                 "eh2_rtl.f").read_text(encoding="utf-8")
        compile_vcs = makefile.split("compile_vcs:", 1)[1].split(
            "compile_nc:", 1)[0]

        self.assertNotIn("-sv_lib", compile_vcs)
        # libcosim.so must be on the link line (directly or via $(LIBCOSIM)).
        self.assertTrue(
            "$(CURDIR)/$(BUILD_DIR)/libcosim.so" in makefile
            or "$(CURDIR)/$(LIBCOSIM)" in makefile,
            msg="compile_vcs link line must include libcosim.so")
        self.assertNotIn("-incdir ", rtl_f)
        self.assertNotIn("+incdir+rtl/snapshots/default", rtl_f)
        self.assertNotIn("rtl/snapshots/default/eh2_pdef.vh", rtl_f)
        self.assertIn("$(SNAPSHOTS)/eh2_pdef.vh", makefile)
        self.assertNotIn("-y rtl/design/lib", rtl_f)

    def test_dual_thread_config_selects_mt_snapshot_and_rvvi_harts(self):
        root = SCRIPT_DIR.parents[3]
        makefile = (root / "Makefile").read_text(encoding="utf-8")

        self.assertIn("DUAL_THREAD_CONFIGS", makefile)
        self.assertIn("dual_thread", makefile)
        self.assertIn("rtl/snapshots/default_mt", makefile)
        self.assertIn("RVVI_NHART := $(if $(IS_DUAL_THREAD_CONFIG),2,1)",
                      makefile)
        self.assertIn("+define+RVVI_NHART=$(RVVI_NHART)", makefile)

    def test_rvvi_ref_hart_count_is_runtime_configurable(self):
        root = SCRIPT_DIR.parents[3]
        spike_rvvi = (root / "dv" / "cosim" /
                      "spike_rvvi.cc").read_text(encoding="utf-8")
        scoreboard = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
                      "eh2_rvvi_scoreboard.sv").read_text(encoding="utf-8")

        self.assertIn("kRvviConfigNumHarts", spike_rvvi)
        self.assertIn("g_config_num_harts", spike_rvvi)
        self.assertIn("std::make_unique<SpikeCosim>", spike_rvvi)
        self.assertIn("g_config_num_harts)", spike_rvvi)
        self.assertNotIn("constexpr int kDefaultNumHarts = 1", spike_rvvi)
        self.assertIn("rvviRefConfigSetInt(kRvviConfigNumHarts, NHART)",
                      scoreboard)
        self.assertRegex(scoreboard,
                         r'\$value\$plusargs\("rvvi_nhart=%d",\s*\w+\)')

    def test_rvvi_scoreboard_and_top_route_per_hart_sidebands(self):
        scoreboard = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
                      "eh2_rvvi_scoreboard.sv").read_text(encoding="utf-8")
        tb_top = (SCRIPT_DIR.parent / "tb" /
                  "core_eh2_tb_top.sv").read_text(encoding="utf-8")
        dut_probe = (SCRIPT_DIR.parent / "env" /
                     "eh2_dut_probe_if.sv").read_text(encoding="utf-8")

        self.assertIn("parameter int NUM_THREADS = 1", dut_probe)
        self.assertRegex(dut_probe,
                         r"logic\s+\[NUM_THREADS-1:0\]\s+nb_load_wen")
        self.assertRegex(dut_probe,
                         r"logic\s+\[NUM_THREADS-1:0\]\[31:0\]\s+mip")
        self.assertIn("async_wb_q[h].push_back(hint)", scoreboard)
        self.assertNotIn("async_wb_q[0].push_back(hint)", scoreboard)
        self.assertIn("rvviDutBusWrite(h", scoreboard)
        self.assertNotIn("rvviDutBusWrite(0", scoreboard)
        self.assertIn("for (int h = 0; h < NHART; h++) begin", scoreboard)
        self.assertIn("eh2_dut_probe_if #(.NUM_THREADS(`RV_NUM_THREADS))",
                      tb_top)
        self.assertIn("dut_probe_intf.mip[ph]", tb_top)
        self.assertIn("dut_probe_intf.debug_req[ph]", tb_top)

    def test_compile_vcs_hard_depends_on_libcosim_so(self):
        # Without a hard prereq, wildcard-style linking silently produces a
        # simv that lacks the cosim DPI symbols, and the failure only surfaces
        # at run time as `Error-[DPI-DIFNF] riscv_cosim_init`. Ask make itself
        # whether `compile_vcs` triggers the libcosim build.
        root = SCRIPT_DIR.parents[3]
        makefile_text = (root / "Makefile").read_text(encoding="utf-8")

        self.assertNotIn("$(wildcard $(BUILD_DIR)/libcosim.so)", makefile_text)
        # `$(LIBCOSIM):` must appear as a real file target on a line of its own.
        self.assertRegex(
            makefile_text,
            r"(?m)^\$\(LIBCOSIM\)\s*:",
            msg="libcosim.so must have an explicit file target so make can "
                "track it as a build artefact")

        # Use make --dry-run to verify the dependency is real, not just
        # textually present. Skip if make/vcs aren't available — this gate is
        # mainly for CI / local sign-off environments.
        import shutil, subprocess
        make_bin = shutil.which("make")
        if make_bin is None:
            self.skipTest("make not available")
        with tempfile.TemporaryDirectory() as td:
            # Probe order in --dry-run: making compile_vcs (without an existing
            # libcosim.so) must list libcosim.so as a target.
            result = subprocess.run(
                [make_bin, "-n", "-C", str(root),
                 "BUILD_DIR=" + td, "compile_vcs"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                universal_newlines=True, encoding="utf-8", errors="replace",
                timeout=30)
            self.assertIn("libcosim.so",
                          (result.stdout or "") + (result.stderr or ""),
                          msg="compile_vcs dry-run must mention libcosim.so")

    def test_no_cosim_escape_hatch_skips_libcosim_link(self):
        # Some users build without spike-cosim available. Allow opt-out via
        # NO_COSIM=1 instead of silently producing a broken simv.
        root = SCRIPT_DIR.parents[3]
        makefile = (root / "Makefile").read_text(encoding="utf-8")

        self.assertIn("NO_COSIM", makefile)
        self.assertRegex(
            makefile,
            r"ifeq\s*\(\s*\$\(NO_COSIM\)\s*,\s*1\s*\)",
            msg="NO_COSIM=1 must gate libcosim.so out of the link")

    def test_ifu_enum_state_flop_uses_vector_cast_bridge(self):
        ifu_mem_ctl = (SCRIPT_DIR.parents[3] / "rtl" / "design" / "ifu" /
                       "eh2_ifu_mem_ctl.sv").read_text(encoding="utf-8")

        self.assertIn("err_stop_state_thr_vec", ifu_mem_ctl)
        self.assertIn("err_stop_state_thr_ff_vec", ifu_mem_ctl)
        self.assertIn("eh2_err_stop_state_t'(", ifu_mem_ctl)
        self.assertIn(".din ( err_stop_state_thr_vec )", ifu_mem_ctl)
        self.assertIn(".dout( err_stop_state_thr_ff_vec )", ifu_mem_ctl)
        self.assertNotIn(".din ( err_stop_state_thr )", ifu_mem_ctl)
        self.assertNotIn(".dout( err_stop_state_thr_ff )", ifu_mem_ctl)

    def test_run_single_test_keeps_generation_failure_log(self):
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td)
            entry = {
                "test": "riscv_arithmetic_basic_test",
                "rtl_test": "core_eh2_base_test",
                "gen_opts": "+instr_cnt=10",
            }

            class FakeProc:
                returncode = 1
                stdout = b"generator failed"
                stderr = b""

            with mock.patch.object(run_regress.subprocess, "run",
                                   return_value=FakeProc()):
                result = run_regress.run_single_test(
                    entry, 1, "vcs", str(out_dir), "")

            work_dir = out_dir / "riscv_arithmetic_basic_test_s1"
            self.assertEqual(result.failure_mode, "GEN_ERROR")
            self.assertEqual(result.sim_log_path, str(work_dir / "gen.log"))
            self.assertTrue((work_dir / "gen.log").exists())
            self.assertTrue((work_dir / "result.pkl").exists())
            self.assertIn("generator failed",
                          (work_dir / "gen.log").read_text(encoding="utf-8"))

    def test_run_single_test_keeps_compile_failure_log_and_result(self):
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td)
            asm = out_dir / "directed.S"
            asm.write_text("_start:\n nop\n", encoding="utf-8")
            entry = {
                "test": "directed_smoke",
                "test_type": "DIRECTED",
                "asm": str(asm),
                "rtl_test": "core_eh2_base_test",
                "cosim": "disabled",
            }

            class FakeProc:
                def __init__(self, returncode, stdout=b"", stderr=b""):
                    self.returncode = returncode
                    self.stdout = stdout
                    self.stderr = stderr

            def fake_run(cmd, **kwargs):
                del kwargs
                if cmd[1].endswith("compile_test.py"):
                    return FakeProc(1, b"compile failed", b"")
                return FakeProc(0)

            with mock.patch.object(run_regress.subprocess, "run", fake_run):
                result = run_regress.run_single_test(
                    entry, 1, "vcs", str(out_dir), "")

            work_dir = out_dir / "directed_smoke_s1"
            compile_log = work_dir / "compile.log"
            self.assertFalse(result.passed)
            self.assertEqual(result.failure_mode, "COMPILE_ERROR")
            self.assertEqual(result.sim_log_path, str(compile_log))
            self.assertTrue(compile_log.exists())
            self.assertTrue((work_dir / "result.pkl").exists())
            self.assertIn("compile failed",
                          compile_log.read_text(encoding="utf-8"))

    def test_run_single_test_uses_python36_subprocess_capture(self):
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td)
            entry = {
                "test": "smoke",
                "rtl_test": "core_eh2_base_test",
                "cosim": "disabled",
            }
            sim_log = out_dir / "smoke_s1" / "sim_smoke_1.log"
            seen_kwargs = []

            class FakeProc:
                returncode = 0
                stdout = b"rtl passed"
                stderr = b""

            def fake_run(cmd, **kwargs):
                seen_kwargs.append(kwargs)
                sim_log.parent.mkdir(parents=True, exist_ok=True)
                sim_log.write_text("TEST PASSED\n", encoding="utf-8")
                return FakeProc()

            with mock.patch.object(run_regress.subprocess, "run", fake_run):
                result = run_regress.run_single_test(
                    entry, 1, "vcs", str(out_dir), "tests/asm/smoke.hex")

            self.assertTrue(result.passed)
            self.assertEqual(len(seen_kwargs), 1)
            self.assertNotIn("capture_output", seen_kwargs[0])
            self.assertIs(seen_kwargs[0]["stdout"], run_regress.subprocess.PIPE)
            self.assertIs(seen_kwargs[0]["stderr"], run_regress.subprocess.PIPE)

    def test_check_logs_requires_explicit_pass_signature(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text("UVM_INFO simulation stopped without pass\n",
                           encoding="utf-8")

            result = check_logs.check_sim_log(str(log))

            self.assertFalse(result.passed)
            self.assertEqual(result.failure_mode, "NO_PASS_SIGNATURE")

    def test_check_logs_classifies_simulator_crash_before_missing_signature(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text(
                "UVM_INFO test started\n"
                "An unexpected termination has occurred due to a signal: "
                "Segmentation fault\n"
                "--- Stack trace follows:\n",
                encoding="utf-8")

            result = check_logs.check_sim_log(str(log), sim_returncode=139)

            self.assertFalse(result.passed)
            self.assertEqual(result.failure_mode, "SIM_CRASH")

    def test_check_logs_classifies_nonzero_return_without_pass_as_sim_error(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text("UVM_INFO simulation stopped early\n",
                           encoding="utf-8")

            result = check_logs.check_sim_log(str(log), sim_returncode=1)

            self.assertFalse(result.passed)
            self.assertEqual(result.failure_mode, "SIM_ERROR")

    def test_check_logs_ignores_zero_count_uvm_report_summary(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text(
                "UVM_INFO tb [test] TEST PASSED (signature)\n"
                "--- UVM Report Summary ---\n"
                "UVM_ERROR :    0\n"
                "UVM_FATAL :    0\n",
                encoding="utf-8")

            result = check_logs.check_sim_log(str(log))

            self.assertTrue(result.passed)
            self.assertEqual(result.failure_mode, "NONE")
            self.assertEqual(result.uvm_errors, 0)

    def test_check_logs_prefers_uvm_summary_counts_when_present(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text(
                "UVM_ERROR tb [cosim] first mismatch\n"
                "UVM_ERROR tb [cosim] second mismatch\n"
                "--- EH2 UVM TEST FAILED ---\n"
                "--- UVM Report Summary ---\n"
                "UVM_WARNING :    0\n"
                "UVM_ERROR :    2\n"
                "UVM_FATAL :    0\n",
                encoding="utf-8")

            result = check_logs.check_sim_log(str(log))

            self.assertFalse(result.passed)
            self.assertEqual(result.failure_mode, "TEST_FAIL")
            self.assertEqual(result.uvm_errors, 2)

    def test_check_logs_warning_clean_ignores_zero_warning_summary(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text(
                "UVM_INFO tb [test] TEST PASSED (signature)\n"
                "--- UVM Report Summary ---\n"
                "UVM_WARNING :    0\n"
                "UVM_ERROR :    0\n"
                "UVM_FATAL :    0\n",
                encoding="utf-8")

            result = check_logs.check_sim_log(str(log), fail_on_warnings=True)

            self.assertTrue(result.passed)
            self.assertEqual(result.failure_mode, "NONE")
            self.assertEqual(result.uvm_warnings, 0)

    def test_check_logs_accepts_vcs_text_after_zero_fatal_summary(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text(
                "TEST PASSED (signature)\n"
                "--- EH2 UVM TEST PASSED ---\n"
                "UVM_WARNING :    0\n"
                "UVM_ERROR :    0\n"
                "UVM_FATAL :    0           V C S   S i m u l a t i o n   R e p o r t\n",
                encoding="utf-8")

            result = check_logs.check_sim_log(str(log))

            self.assertTrue(result.passed)
            self.assertEqual(result.failure_mode, "NONE")
            self.assertEqual(result.uvm_errors, 0)

    def test_check_logs_accepts_vcs_text_overlapping_fatal_summary_count(self):
        # VCS sometimes interleaves the simulation banner with the UVM summary
        # so the count after "UVM_FATAL :" is overwritten entirely. This is a
        # cosmetic artefact, not a real fatal.
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text(
                "TEST PASSED (signature)\n"
                "--- EH2 UVM TEST PASSED ---\n"
                "--- UVM Report Summary ---\n"
                "** Report counts by severity\n"
                "UVM_INFO :   50\n"
                "UVM_WARNING :    0\n"
                "UVM_ERROR :    0\n"
                "UVM_FATAL :            V C S   S i m u l a t i o n   R e p o r t \n",
                encoding="utf-8")

            result = check_logs.check_sim_log(str(log))

            self.assertTrue(result.passed)
            self.assertEqual(result.failure_mode, "NONE")
            self.assertEqual(result.uvm_errors, 0)

    def test_check_logs_accepts_vcs_text_when_summary_colon_also_eaten(self):
        # Even more aggressive overlap: the colon itself is gone, leaving e.g.
        # "UVM_FATAL            V C S   S i m u l a t i o n   R e p o r t".
        # Still a summary artefact, not a real fatal.
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text(
                "TEST PASSED (signature)\n"
                "--- EH2 UVM TEST PASSED ---\n"
                "--- UVM Report Summary ---\n"
                "** Report counts by severity\n"
                "UVM_INFO :   50\n"
                "UVM_WARNING :    0\n"
                "UVM_ERROR :    0\n"
                "UVM_FATAL            V C S   S i m u l a t i o n   R e p o r t \n",
                encoding="utf-8")

            result = check_logs.check_sim_log(str(log))

            self.assertTrue(result.passed)
            self.assertEqual(result.failure_mode, "NONE")
            self.assertEqual(result.uvm_errors, 0)

    def test_check_logs_still_detects_real_uvm_fatal_with_path(self):
        # Genuine fatals come from uvm_report_fatal as
        # "UVM_FATAL <path>(<line>) @ <time>: <id> [<tag>] <msg>" — no colon
        # directly after UVM_FATAL. The summary-line guard must not mask these.
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text(
                "UVM_FATAL dv/uvm/core_eh2/foo.sv(42) @ 100: uvm_test_top "
                "[FATAL] something exploded\n"
                "UVM_WARNING :    0\n"
                "UVM_ERROR :    0\n"
                "UVM_FATAL :    1\n",
                encoding="utf-8")

            result = check_logs.check_sim_log(str(log))

            self.assertFalse(result.passed)
            self.assertEqual(result.failure_mode, "UVM_FATAL")

    def test_check_logs_detects_module_fatal_after_pass_signature(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text(
                "TEST PASSED (signature)\n"
                "Error: \"dv/uvm/core_eh2/common/rvvi_agent/"
                "eh2_rvvi_scoreboard.sv\", 150: core_eh2_tb_top."
                "u_rvvi_scoreboard: at time 1000 ps\n"
                "RVVI_SCOREBOARD: online lockstep failed\n"
                "$finish called from file \"dv/uvm/core_eh2/common/"
                "rvvi_agent/eh2_rvvi_scoreboard.sv\", line 150.\n",
                encoding="utf-8")

            result = check_logs.check_sim_log(str(log))

            self.assertFalse(result.passed)
            self.assertEqual(result.failure_mode, "SIM_FATAL")

    def test_check_logs_treats_explicit_eh2_uvm_failed_banner_as_failure(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text(
                "TEST PASSED (signature)\n"
                "--- EH2 UVM TEST FAILED ---\n",
                encoding="utf-8")

            result = check_logs.check_sim_log(str(log))

            self.assertFalse(result.passed)
            self.assertEqual(result.failure_mode, "TEST_FAIL")

    def test_check_logs_metadata_mode_returns_zero_for_failed_test(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list", "SEED=1 TEST=smoke ITERATIONS=1",
            ])
            test_dir = out_dir / "run" / "tests" / "smoke.1"
            test_dir.mkdir(parents=True)
            (test_dir / "sim_smoke_1.log").write_text(
                "UVM_INFO stopped without pass\n",
                encoding="utf-8")

            rc = check_logs.main([
                "--dir-metadata", str(md_dir),
                "--test-dot-seed", "smoke.1",
            ])

            self.assertEqual(rc, 0)
            self.assertTrue((test_dir / "result.pkl").exists())
            trr = yaml.safe_load((test_dir / "trr.yaml").read_text(
                encoding="utf-8"))
            self.assertFalse(trr["passed"])
            self.assertEqual(trr["failure_mode"], "NO_PASS_SIGNATURE")

    def test_check_logs_metadata_mode_uses_recorded_sim_returncode(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list", "SEED=1 TEST=smoke ITERATIONS=1",
            ])
            test_dir = out_dir / "run" / "tests" / "smoke.1"
            test_dir.mkdir(parents=True)
            (test_dir / "sim_smoke_1.log").write_text(
                "TEST PASSED (signature)\n",
                encoding="utf-8")

            rtl_result = TestRunResult()
            rtl_result.test_name = "smoke"
            rtl_result.seed = 1
            rtl_result.passed = False
            rtl_result.failure_mode = "SIM_ERROR"
            rtl_result.sim_returncode = 1
            rtl_result.save(str(test_dir / "smoke_1"))

            rc = check_logs.main([
                "--dir-metadata", str(md_dir),
                "--test-dot-seed", "smoke.1",
            ])

            self.assertEqual(rc, 0)
            trr = yaml.safe_load((test_dir / "trr.yaml").read_text(
                encoding="utf-8"))
            self.assertTrue(trr["passed"])
            self.assertEqual(trr["failure_mode"], "NONE")
            self.assertEqual(trr["sim_returncode"], 1)

    def test_check_logs_metadata_mode_preserves_directed_test_type(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=2 TEST=directed_smoke ITERATIONS=1",
            ])
            test_dir = out_dir / "run" / "tests" / "directed_smoke.2"
            test_dir.mkdir(parents=True)
            (test_dir / "sim_directed_smoke_2.log").write_text(
                "TEST PASSED (signature)\n",
                encoding="utf-8")

            rc = check_logs.main([
                "--dir-metadata", str(md_dir),
                "--test-dot-seed", "directed_smoke.2",
            ])

            self.assertEqual(rc, 0)
            trr = yaml.safe_load((test_dir / "trr.yaml").read_text(
                encoding="utf-8"))
            self.assertEqual(trr["type"], "DIRECTED")
            result = TestRunResult.load(str(test_dir / "result"))
            self.assertEqual(result.test_type, "DIRECTED")

    def test_check_logs_metadata_mode_preserves_presim_compile_failure(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=1 TEST=riscv_arithmetic_basic_test ITERATIONS=1",
            ])
            test_dir = out_dir / "run" / "tests" / \
                "riscv_arithmetic_basic_test.1"
            test_dir.mkdir(parents=True)
            sim_log = test_dir / "sim_riscv_arithmetic_basic_test_1.log"
            sim_log.write_text(
                "ERROR: RTL simulation skipped because test binary is missing\n",
                encoding="utf-8")
            recorded = TestRunResult()
            recorded.test_name = "riscv_arithmetic_basic_test"
            recorded.seed = 1
            recorded.failure_mode = "COMPILE_ERROR"
            recorded.sim_log_path = str(sim_log)
            recorded.save(str(test_dir / "riscv_arithmetic_basic_test_1"))

            rc = check_logs.main([
                "--dir-metadata", str(md_dir),
                "--test-dot-seed", "riscv_arithmetic_basic_test.1",
            ])

            self.assertEqual(rc, 0)
            trr = yaml.safe_load((test_dir / "trr.yaml").read_text(
                encoding="utf-8"))
            self.assertFalse(trr["passed"])
            self.assertEqual(trr["failure_mode"], "COMPILE_ERROR")

    def test_run_rtl_metadata_mode_returns_zero_for_failed_test(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            md_dir.mkdir()
            sim_log = root / "smoke.1" / "sim_smoke_1.log"

            trr = TestRunResult()
            trr.test_name = "smoke"
            trr.seed = 1
            trr.passed = False
            trr.failure_mode = "NO_PASS_SIGNATURE"
            trr.sim_log_path = str(sim_log)

            with mock.patch.object(run_rtl, "run_from_metadata",
                                   return_value=trr):
                rc = run_rtl.main([
                    "--dir-metadata", str(md_dir),
                    "--test-dot-seed", "smoke.1",
                ])

            self.assertEqual(rc, 0)
            self.assertTrue((sim_log.parent / "smoke_1.pkl").exists())

    def test_compile_assembly_adds_riscv_dv_user_extension_include(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            riscv_dv = root / "riscv-dv"
            user_extension = riscv_dv / "user_extension"
            user_extension.mkdir(parents=True)
            (user_extension / "user_define.h").write_text("", encoding="utf-8")
            (user_extension / "user_init.s").write_text("", encoding="utf-8")

            asm = root / "test.S"
            asm.write_text('.include "user_define.h"\n_start:\n nop\n',
                           encoding="utf-8")
            linker = root / "link.ld"
            linker.write_text("SECTIONS { . = 0x80000000; .text : { *(.text*) } }\n",
                              encoding="utf-8")
            bin_path = root / "test.bin"
            captured = []

            class FakeProc:
                returncode = 0
                stdout = b""

            def fake_run(cmd, stdout, stderr, timeout):
                del stdout, stderr, timeout
                captured.append(cmd)
                if "-O" in cmd and "binary" in cmd:
                    bin_path.write_bytes(b"\x13\x00\x00\x00")
                return FakeProc()

            with mock.patch.dict(os.environ, {"RISCV_DV_DIR": str(riscv_dv)}):
                with mock.patch.object(compile_test.subprocess, "run", fake_run):
                    ok = compile_test.compile_assembly(
                        str(asm), str(bin_path), str(linker))

            self.assertTrue(ok)
            self.assertIn(f"-I{user_extension}", captured[0])

    def test_compile_assembly_emits_vma_addressed_hex(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            asm = root / "test.S"
            asm.write_text("_start:\n nop\n", encoding="utf-8")
            linker = root / "link.ld"
            linker.write_text("SECTIONS { . = 0x80000000; .text : { *(.text*) } }\n",
                              encoding="utf-8")
            bin_path = root / "test.bin"
            hex_path = root / "test.hex"
            elf_path = root / "test.elf"
            elf_bytes = bytearray(0x3000)
            elf_bytes[0x1000:0x1004] = b"\x13\x00\x00\x00"
            elf_bytes[0x2000:0x2004] = b"\xaa\xbb\xcc\xdd"
            elf_path.write_bytes(elf_bytes)

            class FakeProc:
                def __init__(self, stdout=b""):
                    self.returncode = 0
                    self.stdout = stdout

            def fake_run(cmd, stdout, stderr, timeout):
                del stdout, stderr, timeout
                if "-O" in cmd and "binary" in cmd:
                    bin_path.write_bytes(b"\x13\x00\x00\x00")
                    return FakeProc()
                if cmd[0].endswith("-objdump") and "-h" in cmd:
                    return FakeProc((
                        "\n"
                        "Sections:\n"
                        "Idx Name          Size      VMA       LMA       File off  Algn\n"
                        "  0 .text         00000004  80000000  80000000  00001000  2**2\n"
                        "                  CONTENTS, ALLOC, LOAD, READONLY, CODE\n"
                        "  1 .data         00000004  81000000  80000004  00002000  2**2\n"
                        "                  CONTENTS, ALLOC, LOAD, DATA\n"
                        "  2 .riscv.attributes 00000010  00000000  00000000  00002004  2**0\n"
                        "                  CONTENTS, READONLY\n"
                    ).encode("utf-8"))
                return FakeProc()

            with mock.patch.object(compile_test.subprocess, "run", fake_run):
                ok = compile_test.compile_assembly(
                    str(asm), str(bin_path), str(linker), hex_path=str(hex_path))

            self.assertTrue(ok)
            hex_text = hex_path.read_text(encoding="utf-8")
            self.assertIn("@80000000", hex_text)
            self.assertIn("13 00 00 00", hex_text)
            self.assertIn("@81000000", hex_text)
            self.assertIn("AA BB CC DD", hex_text)
            self.assertNotIn("@00000000", hex_text)

    def test_run_single_test_passes_generated_hex_to_rtl(self):
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td)
            entry = {
                "test": "riscv_arithmetic_basic_test",
                "rtl_test": "core_eh2_base_test",
                "gen_opts": "+instr_cnt=10",
                "cosim": "disabled",
            }
            asm_dir = out_dir / "riscv_arithmetic_basic_test_s1" / "asm_test"
            asm_dir.mkdir(parents=True)
            (asm_dir / "riscv_arithmetic_basic_test_0.S").write_text(
                "_start:\n nop\n", encoding="utf-8")
            sim_log = out_dir / "riscv_arithmetic_basic_test_s1" / \
                "sim_riscv_arithmetic_basic_test_1.log"
            seen_cmds = []

            class FakeProc:
                returncode = 0
                stdout = b""
                stderr = b""

            def fake_run(cmd, **kwargs):
                del kwargs
                seen_cmds.append(cmd)
                if cmd[1].endswith("compile_test.py"):
                    hex_path = Path(cmd[cmd.index("--hex") + 1])
                    hex_path.write_text("@80000000\n13 00 00 00\n",
                                        encoding="utf-8")
                if cmd[1].endswith("run_rtl.py"):
                    sim_log.parent.mkdir(parents=True, exist_ok=True)
                    sim_log.write_text("TEST PASSED\n", encoding="utf-8")
                return FakeProc()

            with mock.patch.object(run_regress.subprocess, "run", fake_run):
                result = run_regress.run_single_test(
                    entry, 1, "vcs", str(out_dir), "")

            self.assertTrue(result.passed)
            rtl_cmd = [cmd for cmd in seen_cmds if cmd[1].endswith("run_rtl.py")][0]
            binary_arg = rtl_cmd[rtl_cmd.index("--binary") + 1]
            self.assertTrue(binary_arg.endswith(".hex"))
            self.assertEqual(result.binary_path, binary_arg)

    def test_run_single_test_uses_sim_returncode_in_log_check(self):
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td)
            entry = {
                "test": "smoke",
                "rtl_test": "core_eh2_base_test",
                "cosim": "disabled",
            }
            sim_log = out_dir / "smoke_s1" / "sim_smoke_1.log"

            class FakeProc:
                returncode = 1
                stdout = b""
                stderr = b""

            def fake_run(cmd, **kwargs):
                del cmd, kwargs
                sim_log.parent.mkdir(parents=True, exist_ok=True)
                sim_log.write_text("UVM_INFO stopped\n", encoding="utf-8")
                return FakeProc()

            with mock.patch.object(run_regress.subprocess, "run", fake_run):
                result = run_regress.run_single_test(
                    entry, 1, "vcs", str(out_dir), "tests/asm/smoke.hex")

            self.assertFalse(result.passed)
            self.assertEqual(result.failure_mode, "SIM_ERROR")
            self.assertEqual(result.sim_returncode, 1)

    def test_run_single_test_records_warning_and_error_counts(self):
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td)
            entry = {
                "test": "smoke",
                "rtl_test": "core_eh2_base_test",
                "cosim": "disabled",
            }
            sim_log = out_dir / "smoke_s1" / "sim_smoke_1.log"

            class FakeProc:
                returncode = 0
                stdout = b""
                stderr = b""

            def fake_run(cmd, **kwargs):
                del cmd, kwargs
                sim_log.parent.mkdir(parents=True, exist_ok=True)
                sim_log.write_text(
                    "TEST PASSED (signature)\n"
                    "UVM_WARNING :    2\n",
                    encoding="utf-8")
                return FakeProc()

            with mock.patch.object(run_regress.subprocess, "run", fake_run):
                result = run_regress.run_single_test(
                    entry, 1, "vcs", str(out_dir), "tests/asm/smoke.hex")

            self.assertTrue(result.passed)
            self.assertEqual(result.uvm_warnings, 2)
            self.assertEqual(result.uvm_errors, 0)

    def test_run_regression_writes_machine_readable_report_json(self):
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td) / "regress"

            class Args:
                testlist = ""
                test = "smoke"
                rtl_test = "core_eh2_base_test"
                gen_opts = ""
                disable_cosim = True
                output = str(out_dir)
                iterations = 1
                seed = 1
                parallel = 1
                simulator = "vcs"
                binary = "tests/asm/smoke.hex"
                sim_opts = "+disable_cosim=1"
                coverage = False
                waves = False
                fail_on_warnings = False
                build_dir = None

            def fake_run_single_test(*args, **kwargs):
                del args, kwargs
                result = TestRunResult()
                result.test_name = "smoke"
                result.seed = 1
                result.passed = True
                result.failure_mode = "NONE"
                result.sim_log_path = str(out_dir / "smoke.log")
                return result

            with mock.patch.object(run_regress, "run_single_test",
                                   fake_run_single_test):
                summary = run_regress.run_regression(Args)

            self.assertEqual(summary.failed, 0)
            report_json = out_dir / "report.json"
            self.assertTrue(report_json.exists())
            data = json.loads(report_json.read_text(encoding="utf-8"))
            self.assertEqual(data["total"], 1)
            self.assertEqual(data["tests"][0]["sim_log"],
                             str(out_dir / "smoke.log"))

    def test_run_regression_filters_named_test_from_testlist(self):
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td) / "regress"
            cosim_testlist = (SCRIPT_DIR.parent / "directed_tests" /
                              "cosim_testlist.yaml")
            captured = {}

            class Args:
                testlist = str(cosim_testlist)
                test = "cosim_smoke"
                rtl_test = ""
                gen_opts = ""
                disable_cosim = False
                output = str(out_dir)
                iterations = None
                seed = 1
                parallel = 1
                simulator = "vcs"
                binary = ""
                sim_opts = ""
                coverage = False
                waves = True
                fail_on_warnings = False
                build_dir = None

            def fake_run_single_test(entry, seed, *args, **kwargs):
                captured["entry"] = entry
                captured["seed"] = seed
                captured["waves"] = args[5]
                result = TestRunResult()
                result.test_name = entry["test"]
                result.seed = seed
                result.passed = True
                result.failure_mode = "NONE"
                result.sim_log_path = str(out_dir / "cosim_smoke.log")
                return result

            with mock.patch.object(run_regress, "run_single_test",
                                   fake_run_single_test):
                summary = run_regress.run_regression(Args)

            self.assertEqual(summary.failed, 0)
            self.assertEqual(captured["entry"]["test"], "cosim_smoke")
            self.assertEqual(captured["entry"]["rtl_test"],
                             "core_eh2_cosim_test")
            self.assertEqual(captured["entry"]["test_type"], "DIRECTED")
            self.assertIn("cosim_smoke.S", captured["entry"]["asm"])
            self.assertEqual(captured["entry"]["cosim"], "enabled")
            self.assertTrue(captured["waves"])

    def test_default_linker_places_generated_ram_in_external_memory(self):
        link_ld = (SCRIPT_DIR / "link.ld").read_text(encoding="utf-8")

        self.assertIn("RAM", link_ld)
        self.assertIn("ORIGIN = 0x81000000", link_ld)
        self.assertNotIn("ORIGIN = 0xF0040000", link_ld)

    def test_results_gatherer_loads_pkl_files_and_creates_output_dir(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            result = TestRunResult()
            result.test_name = "smoke"
            result.seed = 1
            result.passed = True
            result.failure_mode = "NONE"
            result.save(str(root / "smoke_s1" / "result"))

            summary = results_gatherer.collect_results(str(root))

            self.assertEqual(summary.total_tests, 1)
            self.assertEqual(summary.passed, 1)
            out_dir = root / "reports"
            results_gatherer.write_reports(summary, str(out_dir))
            self.assertTrue((out_dir / "regr.log").exists())
            self.assertTrue((out_dir / "regr_junit.xml").exists())
            self.assertTrue((out_dir / "report.json").exists())

    def test_report_json_includes_diagnostic_paths_and_counts(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            result = TestRunResult()
            result.test_name = "smoke"
            result.seed = 1
            result.passed = False
            result.failure_mode = "UVM_ERROR"
            result.sim_log_path = str(root / "smoke.log")
            result.binary_path = str(root / "smoke.hex")
            result.uvm_errors = 3
            result.uvm_warnings = 2
            result.sim_returncode = 1

            summary = metadata.RegressionSummary()
            summary.add_result(result)
            out = root / "report.json"

            results_gatherer.generate_report_json(summary, str(out))
            data = json.loads(out.read_text(encoding="utf-8"))
            test = data["tests"][0]

            self.assertEqual(test["sim_log"], str(root / "smoke.log"))
            self.assertEqual(test["binary"], str(root / "smoke.hex"))
            self.assertEqual(test["uvm_errors"], 3)
            self.assertEqual(test["uvm_warnings"], 2)
            self.assertEqual(test["sim_returncode"], 1)

    def test_results_gatherer_prefers_final_result_over_intermediate_rtl_result(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            run_dir = root / "riscv_arithmetic_basic_test_s1"

            final_result = TestRunResult()
            final_result.test_name = "riscv_arithmetic_basic_test"
            final_result.seed = 1
            final_result.passed = True
            final_result.failure_mode = "NONE"
            final_result.num_cycles = 123
            final_result.save(str(run_dir / "result"))

            rtl_result = TestRunResult()
            rtl_result.test_name = "riscv_arithmetic_basic_test"
            rtl_result.seed = 1
            rtl_result.passed = True
            rtl_result.failure_mode = ""
            rtl_result.num_cycles = 0
            rtl_result.save(str(run_dir / "riscv_arithmetic_basic_test_1"))

            summary = results_gatherer.collect_results(str(root))

            self.assertEqual(summary.total_tests, 1)
            self.assertEqual(summary.results[0].failure_mode, "NONE")
            self.assertEqual(summary.results[0].num_cycles, 123)

    def test_cosim_only_makefile_flow_files_exist(self):
        root = SCRIPT_DIR.parents[3]

        get_meta = root / "dv" / "uvm" / "core_eh2" / "scripts" / "get_meta.mk"
        util_mk = root / "dv" / "uvm" / "core_eh2" / "scripts" / "util.mk"
        makefile = root / "Makefile"

        self.assertTrue(get_meta.exists())
        self.assertTrue(util_mk.exists())
        self.assertTrue(makefile.exists())

        makefile_text = makefile.read_text(encoding="utf-8")
        for target in [
            "spike:",
            "cosim:",
            "smoke:",
            "regress:",
            "signoff:",
            "compliance:",
        ]:
            self.assertIn(target, makefile_text)

    def test_metadata_supports_ibex_style_create_metadata_op(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"

            rc = metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=7 TEST=smoke SIMULATOR=vcs COV=1 WAVES=1 ITERATIONS=2",
            ])

            self.assertEqual(rc, 0)
            self.assertTrue((md_dir / "metadata.pkl").exists())
            self.assertTrue((md_dir / "metadata.yaml").exists())
            md = RegressionMetadata.construct_from_metadata_dir(md_dir)
            self.assertEqual(md.seed, 7)
            self.assertEqual(md.test_name, "smoke")
            self.assertEqual(md.simulator, "vcs")
            self.assertTrue(md.coverage)
            self.assertTrue(md.waves)
            self.assertEqual(md.iterations, 2)

    def test_metadata_print_field_exports_ibex_style_testdotseed_lists(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"

            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=5 TEST=directed_smoke SIMULATOR=vcs ITERATIONS=1",
            ])

            self.assertEqual(metadata.print_field(str(md_dir), "directed_tds"),
                             "directed_smoke.5")
            self.assertEqual(metadata.print_field(str(md_dir), "riscvdv_tds"),
                             "")
            self.assertEqual(metadata.print_field(str(md_dir), "dir_tests"),
                             str(out_dir.resolve() / "run" / "tests"))

    def test_metadata_classifies_cosim_testlist_entries_as_directed(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"

            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=1 TEST=cosim_smoke SIMULATOR=vcs ITERATIONS=1",
            ])

            self.assertEqual(metadata.print_field(str(md_dir), "directed_tds"),
                             "cosim_smoke.1")
            self.assertEqual(metadata.print_field(str(md_dir), "riscvdv_tds"),
                             "")
            md = RegressionMetadata.construct_from_metadata_dir(md_dir)
            self.assertEqual(md.tests_and_counts,
                             [("cosim_smoke", 1, "DIRECTED")])

    def test_metadata_all_cosim_selects_only_cosim_directed_entries(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"

            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=4 TEST=all_cosim SIMULATOR=vcs ITERATIONS=1",
            ])

            directed_tds = metadata.print_field(str(md_dir), "directed_tds")
            self.assertIn("cosim_smoke.4", directed_tds)
            self.assertIn("cosim_dual_issue.4", directed_tds)
            self.assertNotIn("directed_smoke.4", directed_tds)
            self.assertEqual(metadata.print_field(str(md_dir), "riscvdv_tds"),
                             "")

    def test_render_config_template_uses_eh2_config_parameters(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            template = root / "setting.tpl.sv"
            template.write_text(
                "parameter int NUM_HARTS = {{ NUM_THREADS }};\n"
                "riscv_instr_group_t supported_isa[$] = {\n"
                "  RV32I\n"
                "//% if ATOMIC_ENABLE\n"
                "  ,RV32A\n"
                "//% endif\n"
                "//% if BITMANIP_ZBA\n"
                "  ,RV32ZBA\n"
                "//% endif\n"
                "};\n",
                encoding="utf-8")

            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=1 TEST=directed_smoke CONFIG=minimal",
            ])

            rendered = render_config_template.render_template(
                "minimal", str(template))

            self.assertIn("NUM_HARTS = 1", rendered)
            self.assertNotIn("RV32A", rendered)
            self.assertNotIn("RV32ZBA", rendered)

    def test_compile_test_metadata_mode_compiles_directed_entry(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=2 TEST=directed_smoke ITERATIONS=1",
            ])

            seen = {}

            def fake_compile(asm_path, bin_path, linker_script,
                             gcc_prefix="riscv32-unknown-elf",
                             include_dirs=None, riscv_dv_dir="", hex_path=""):
                del gcc_prefix, riscv_dv_dir
                seen["asm_path"] = asm_path
                seen["linker_script"] = linker_script
                seen["include_dirs"] = include_dirs
                Path(bin_path).write_bytes(b"\x13\x00\x00\x00")
                Path(hex_path).write_text("@80000000\n13 00 00 00\n",
                                          encoding="utf-8")
                return True

            with mock.patch.object(compile_test, "compile_assembly",
                                   fake_compile):
                ok = compile_test.compile_from_metadata(str(md_dir),
                                                        "directed_smoke.2")

            test_dir = out_dir / "run" / "tests" / "directed_smoke.2"
            self.assertTrue(ok)
            self.assertTrue((test_dir / "test.S").exists())
            self.assertTrue(str(seen["asm_path"]).endswith("cosim_smoke.S"))
            self.assertTrue(str(seen["linker_script"]).endswith(
                "cosim_link.ld"))
            self.assertTrue(any(path.endswith("tests/asm")
                                for path in seen["include_dirs"]))

    def test_compile_test_metadata_mode_uses_default_linker_for_riscvdv(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=8 TEST=riscv_arithmetic_basic_test ITERATIONS=1",
            ])
            test_dir = out_dir / "run" / "tests" / \
                "riscv_arithmetic_basic_test.8" / "asm_test"
            test_dir.mkdir(parents=True)
            (test_dir / "riscv_arithmetic_basic_test_0.S").write_text(
                "_start:\n nop\n",
                encoding="utf-8")
            seen = {}

            def fake_compile(asm_path, bin_path, linker_script,
                             gcc_prefix="riscv32-unknown-elf",
                             include_dirs=None, riscv_dv_dir="", hex_path=""):
                del gcc_prefix, include_dirs, riscv_dv_dir
                seen["asm_path"] = asm_path
                seen["linker_script"] = linker_script
                Path(bin_path).write_bytes(b"\x13\x00\x00\x00")
                Path(hex_path).write_text("@80000000\n13 00 00 00\n",
                                          encoding="utf-8")
                return True

            with mock.patch.object(compile_test, "compile_assembly",
                                   fake_compile):
                ok = compile_test.compile_from_metadata(
                    str(md_dir), "riscv_arithmetic_basic_test.8")

            self.assertTrue(ok)
            self.assertTrue(str(seen["asm_path"]).endswith(
                "riscv_arithmetic_basic_test_0.S"))
            self.assertTrue(str(seen["linker_script"]).endswith(
                "scripts/link.ld"))

    def test_compile_test_metadata_mode_compiles_cosim_entry(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=3 TEST=cosim_alu ITERATIONS=1",
            ])

            seen = {}

            def fake_compile(asm_path, bin_path, linker_script,
                             gcc_prefix="riscv32-unknown-elf",
                             include_dirs=None, riscv_dv_dir="", hex_path=""):
                del gcc_prefix, riscv_dv_dir, include_dirs
                seen["asm_path"] = asm_path
                seen["linker_script"] = linker_script
                Path(bin_path).write_bytes(b"\x13\x00\x00\x00")
                Path(hex_path).write_text("@80000000\n13 00 00 00\n",
                                          encoding="utf-8")
                return True

            with mock.patch.object(compile_test, "compile_assembly",
                                   fake_compile):
                ok = compile_test.compile_from_metadata(str(md_dir),
                                                        "cosim_alu.3")

            self.assertTrue(ok)
            self.assertTrue(str(seen["asm_path"]).endswith("cosim_alu.S"))
            self.assertTrue(str(seen["linker_script"]).endswith(
                "cosim_link.ld"))

    def test_compile_test_metadata_mode_records_compile_failure(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=6 TEST=directed_smoke ITERATIONS=1",
            ])

            def fake_compile(asm_path, bin_path, linker_script,
                             gcc_prefix="riscv32-unknown-elf",
                             include_dirs=None, riscv_dv_dir="", hex_path=""):
                del (asm_path, bin_path, linker_script, gcc_prefix,
                     include_dirs, riscv_dv_dir, hex_path)
                print("fake compiler failed")
                return False

            with mock.patch.object(compile_test, "compile_assembly",
                                   fake_compile):
                ok = compile_test.compile_from_metadata(str(md_dir),
                                                        "directed_smoke.6")

            test_dir = out_dir / "run" / "tests" / "directed_smoke.6"
            self.assertFalse(ok)
            self.assertTrue((test_dir / "compile.log").exists())
            self.assertIn("fake compiler failed",
                          (test_dir / "compile.log").read_text(
                              encoding="utf-8"))
            result = TestRunResult.load(str(test_dir / "result"))
            self.assertEqual(result.failure_mode, "COMPILE_ERROR")
            self.assertEqual(result.test_type, "DIRECTED")

    def test_run_instr_gen_metadata_mode_uses_testdotseed_work_dir(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=9 TEST=riscv_arithmetic_basic_test ITERATIONS=1",
            ])

            seen = {}

            def fake_run(riscv_dv_dir, work_dir, test_name, gen_opts,
                         seed, iterations=1):
                seen.update({
                    "riscv_dv_dir": riscv_dv_dir,
                    "work_dir": work_dir,
                    "test_name": test_name,
                    "gen_opts": gen_opts,
                    "seed": seed,
                    "iterations": iterations,
                })
                return True

            with mock.patch.object(run_instr_gen, "run_instr_gen", fake_run):
                ok = run_instr_gen.run_from_metadata(str(md_dir),
                                                     "riscv_arithmetic_basic_test.9")

            self.assertTrue(ok)
            self.assertEqual(seen["test_name"], "riscv_arithmetic_basic_test")
            self.assertEqual(seen["seed"], 9)
            self.assertEqual(seen["iterations"], 1)
            self.assertTrue(seen["work_dir"].endswith(
                "run/tests/riscv_arithmetic_basic_test.9"))

    def test_run_rtl_metadata_mode_uses_test_hex_and_shared_build(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            md_dir = root / "metadata"
            out_dir = root / "out"
            metadata.main([
                "--op", "create_metadata",
                "--dir-metadata", str(md_dir),
                "--dir-out", str(out_dir),
                "--args-list",
                "SEED=4 TEST=directed_smoke ITERATIONS=1 SIMULATOR=vcs",
            ])
            test_dir = out_dir / "run" / "tests" / "directed_smoke.4"
            test_dir.mkdir(parents=True)
            (test_dir / "test.hex").write_text("@80000000\n13 00 00 00\n",
                                               encoding="utf-8")

            seen = {}

            def fake_run(md):
                seen["md"] = md
                result = TestRunResult()
                result.test_name = md.test_name
                result.seed = md.seed
                result.passed = True
                result.failure_mode = "NONE"
                result.sim_log_path = str(Path(md.out_dir) /
                                          "sim_directed_smoke_4.log")
                return result

            with mock.patch.object(run_rtl, "run_rtl_simulation", fake_run):
                result = run_rtl.run_from_metadata(str(md_dir),
                                                   "directed_smoke.4")

            self.assertTrue(result.passed)
            self.assertEqual(seen["md"].binary_path, str(test_dir / "test.hex"))
            self.assertEqual(seen["md"].build_dir,
                             str(SCRIPT_DIR.parents[3] / "build"))
            self.assertEqual(seen["md"].out_dir, str(test_dir))

    def test_directed_and_cosim_testlists_are_present_and_parse(self):
        directed_path = SCRIPT_DIR.parent / "directed_tests" / "directed_testlist.yaml"
        cosim_path = SCRIPT_DIR.parent / "directed_tests" / "cosim_testlist.yaml"

        self.assertTrue(directed_path.exists())
        self.assertTrue(cosim_path.exists())

        directed_model = directed_test_schema.import_model(directed_path)
        cosim_model = directed_test_schema.import_model(cosim_path)

        self.assertGreaterEqual(len(directed_model.tests), 1)
        self.assertEqual(
            {test.test for test in cosim_model.tests},
            {
                "cosim_smoke",
                "cosim_alu",
                "cosim_load_store",
                "cosim_dual_issue",
                "cosim_bitmanip",
                "cosim_exception_compare",
                "cosim_atomic_basic",
            },
        )
        for test in cosim_model.tests:
            self.assertEqual(test.rtl_test, "core_eh2_cosim_test")
            self.assertTrue((SCRIPT_DIR.parent / test.test_srcs).exists())

    def test_load_regression_testlist_expands_directed_schema(self):
        directed_path = SCRIPT_DIR.parent / "directed_tests" / "cosim_testlist.yaml"

        entries = run_regress.load_regression_testlist(str(directed_path))

        self.assertEqual(len(entries), 7)
        self.assertEqual(entries[0]["test"], "cosim_smoke")
        self.assertEqual(entries[0]["test_type"], "DIRECTED")
        self.assertEqual(entries[0]["rtl_test"], "core_eh2_cosim_test")
        self.assertEqual(entries[0]["cosim"], "enabled")
        self.assertTrue(entries[0]["asm"].endswith("tests/asm/cosim_smoke.S"))
        self.assertTrue(entries[0]["linker"].endswith("tests/asm/cosim_link.ld"))

    def test_load_regression_testlist_preserves_directed_test_overrides(self):
        directed_path = SCRIPT_DIR.parent / "directed_tests" / "directed_testlist.yaml"

        entries = run_regress.load_regression_testlist(str(directed_path))
        by_name = {entry["test"]: entry for entry in entries}

        debug_walk = by_name["directed_dbg_dret_walk"]
        self.assertIn("+enable_debug_seq=1", debug_walk["sim_opts"])
        self.assertIn("+enable_debug_single=1", debug_walk["sim_opts"])
        self.assertEqual(debug_walk["cosim"], "disabled")

    def test_debug_coverage_sequence_is_finite_and_exercises_dmi_commands(self):
        vseq_path = SCRIPT_DIR.parent / "tests" / "core_eh2_vseq.sv"
        seq_lib_path = SCRIPT_DIR.parent / "tests" / "core_eh2_seq_lib.sv"

        vseq_text = vseq_path.read_text(encoding="utf-8")
        seq_text = seq_lib_path.read_text(encoding="utf-8")

        self.assertIn("debug_stress_h.stress_mode = cfg.enable_debug_stress;", vseq_text)
        self.assertIn("send_core_register_read", seq_text)
        self.assertIn("send_core_local_memory_read", seq_text)
        self.assertIn("send_external_system_bus_read", seq_text)
        self.assertIn("DMI_COMMAND", seq_text)
        self.assertIn("DMI_SBADDRESS0", seq_text)

    def test_run_single_test_compiles_directed_asm_without_instr_gen(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            asm = root / "directed.S"
            asm.write_text("_start:\n nop\n", encoding="utf-8")
            sim_log = root / "directed_smoke_s3" / "sim_directed_smoke_3.log"
            entry = {
                "test": "directed_smoke",
                "test_type": "DIRECTED",
                "asm": str(asm),
                "rtl_test": "core_eh2_cosim_test",
                "cosim": "enabled",
            }
            seen_cmds = []

            class FakeProc:
                returncode = 0
                stdout = b""
                stderr = b""

            def fake_run(cmd, **kwargs):
                del kwargs
                seen_cmds.append(cmd)
                if cmd[1].endswith("compile_test.py"):
                    hex_path = Path(cmd[cmd.index("--hex") + 1])
                    hex_path.write_text("@80000000\n13 00 00 00\n",
                                        encoding="utf-8")
                if cmd[1].endswith("run_rtl.py"):
                    sim_log.parent.mkdir(parents=True, exist_ok=True)
                    sim_log.write_text(
                        "TEST PASSED (signature)\n"
                        "Co-simulation Scoreboard Report\n"
                        "Steps executed: 1\n"
                        "Mismatches: 0\n",
                        encoding="utf-8")
                return FakeProc()

            with mock.patch.object(run_regress.subprocess, "run", fake_run):
                result = run_regress.run_single_test(
                    entry, 3, "vcs", str(root), "")

            self.assertTrue(result.passed)
            self.assertEqual(result.test_type, "DIRECTED")
            self.assertIn("+enable_cosim=1", " ".join(seen_cmds[-1]))
            self.assertFalse(any(cmd[1].endswith("run_instr_gen.py")
                                 for cmd in seen_cmds))
            self.assertTrue(result.binary_path.endswith(".hex"))

    def test_run_single_test_forwards_coverage_and_waves_to_rtl(self):
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td)
            entry = {
                "test": "smoke",
                "rtl_test": "core_eh2_base_test",
                "cosim": "disabled",
            }
            sim_log = out_dir / "smoke_s1" / "sim_smoke_1.log"
            seen_cmds = []

            class FakeProc:
                returncode = 0
                stdout = b""
                stderr = b""

            def fake_run(cmd, **kwargs):
                del kwargs
                seen_cmds.append(cmd)
                sim_log.parent.mkdir(parents=True, exist_ok=True)
                sim_log.write_text("TEST PASSED (signature)\n", encoding="utf-8")
                return FakeProc()

            with mock.patch.object(run_regress.subprocess, "run", fake_run):
                result = run_regress.run_single_test(
                    entry, 1, "vcs", str(out_dir), "tests/asm/smoke.hex",
                    coverage=True, waves=True)

            self.assertTrue(result.passed)
            rtl_cmd = seen_cmds[0]
            self.assertIn("--coverage", rtl_cmd)
            self.assertIn("--waves", rtl_cmd)

    def test_check_logs_can_fail_on_tool_warnings_for_warning_clean_runs(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text(
                "TEST PASSED (signature)\n"
                "Warning-[STASKW_RMCOF] Cannot open file\n"
                "UVM_ERROR :    0\n"
                "UVM_FATAL :    0\n",
                encoding="utf-8")

            result = check_logs.check_sim_log(str(log), fail_on_warnings=True)

            self.assertFalse(result.passed)
            self.assertEqual(result.failure_mode, "TOOL_WARNING")

    def test_vcs_compile_names_single_testbench_top(self):
        root = SCRIPT_DIR.parents[3]
        makefile = (root / "Makefile").read_text(encoding="utf-8")

        self.assertIn("-top core_eh2_tb_top", makefile)

    def test_vcs_compile_enables_verdi_uvm_component_wave(self):
        root = SCRIPT_DIR.parents[3]
        makefile = (root / "Makefile").read_text(encoding="utf-8")

        self.assertIn("-debug_access+all", makefile)
        self.assertIn("-kdb", makefile)
        self.assertIn("+define+UVM_VERDI_COMPWAVE", makefile)

    def test_compile_tb_vcs_enables_verdi_uvm_component_wave(self):
        md = RegressionMetadata()
        md.simulator = "vcs"
        md.work_dir = "/tmp/eh2-build"

        cmd = compile_tb.get_compile_cmd(md)

        self.assertIn("-debug_access+all", cmd)
        self.assertIn("-kdb", cmd)
        self.assertIn("+define+UVM_VERDI_COMPWAVE", cmd)

    def test_axi_agents_are_parameterized_and_sb_monitor_is_connected(self):
        tb_top = (SCRIPT_DIR.parent / "tb" /
                  "core_eh2_tb_top.sv").read_text(encoding="utf-8")
        env = (SCRIPT_DIR.parent / "env" /
               "core_eh2_env.sv").read_text(encoding="utf-8")
        agent = (SCRIPT_DIR.parent / "common" / "axi4_agent" /
                 "axi4_agent.sv").read_text(encoding="utf-8")
        monitor = (SCRIPT_DIR.parent / "common" / "axi4_agent" /
                   "axi4_monitor.sv").read_text(encoding="utf-8")
        driver = (SCRIPT_DIR.parent / "common" / "axi4_agent" /
                  "axi4_driver.sv").read_text(encoding="utf-8")

        self.assertIn("class axi4_agent #(int ID_WIDTH = 4) extends uvm_agent;",
                      agent)
        self.assertIn("axi4_agent#(`RV_LSU_BUS_TAG) lsu_agent;", env)
        self.assertIn("axi4_agent#(`RV_IFU_BUS_TAG) ifu_agent;", env)
        self.assertIn("axi4_agent#(`RV_SB_BUS_TAG) sb_agent;", env)
        self.assertIn("virtual axi4_intf#(.ID_WIDTH(ID_WIDTH)) vif;",
                      monitor)
        self.assertIn("virtual axi4_intf#(.ID_WIDTH(ID_WIDTH)) vif;",
                      driver)
        self.assertIn(
            'uvm_config_db#(virtual axi4_intf#(.ID_WIDTH(`RV_SB_BUS_TAG)))::set(null, "*sb_agent*",  "vif", sb_axi_intf);',
            tb_top)
        self.assertNotIn("SB agent: skip config_db", tb_top)

    def test_axi_monitor_captures_same_cycle_write_handshakes(self):
        monitor = (SCRIPT_DIR.parent / "common" / "axi4_agent" /
                   "axi4_monitor.sv").read_text(encoding="utf-8")

        self.assertIn("EH2 can handshake both on", monitor)
        self.assertIn("if (!(vif.wvalid && vif.wready)) begin", monitor)
        self.assertIn("as soon as address and data are complete", monitor)
        self.assertNotIn("@(posedge vif.clk iff (vif.bvalid && vif.bready))",
                         monitor)

    def test_rvvi_scoreboard_queues_retire_until_async_writeback_arrives(self):
        scoreboard = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
                      "eh2_rvvi_scoreboard.sv").read_text(encoding="utf-8")

        self.assertIn("pending_retire_q[h].push_back(retire_evt)", scoreboard)
        self.assertIn("task automatic process_pending(input int h)", scoreboard)
        self.assertIn("if (needs_async_wb(retire_evt)) begin", scoreboard)
        self.assertIn("if (!try_consume_async_wb(retire_evt, async_hint)) begin",
                      scoreboard)
        self.assertIn("break;", scoreboard)
        self.assertIn("process_retire(retire_evt, has_async, async_hint)",
                      scoreboard)

    def test_rvvi_scoreboard_stages_lsu_bus_writes_through_rvvi_api(self):
        scoreboard = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
                      "eh2_rvvi_scoreboard.sv").read_text(encoding="utf-8")

        self.assertIn("task automatic stage_bus_writes", scoreboard)
        self.assertIn("lsu_bus_write && lsu_bus_wmask != 4'b0", scoreboard)
        self.assertIn("rvviDutBusWrite", scoreboard)
        self.assertIn("stage_bus_writes();", scoreboard)

    def test_cosim_dpi_has_no_tmp_debug_file_side_effects(self):
        cosim_dir = SCRIPT_DIR.parents[3] / "dv" / "cosim"
        cosim_text = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(cosim_dir.glob("*"))
            if path.suffix in (".cc", ".h", ".svh"))

        self.assertNotIn("/tmp/cosim_debug.log", cosim_text)
        self.assertNotIn("fopen(\"/tmp", cosim_text)

    def test_spike_cosim_mcycle_sync_is_dpi_safe(self):
        spike_cosim = (SCRIPT_DIR.parents[3] / "dv" / "cosim" /
                       "spike_cosim.cc").read_text(encoding="utf-8")
        start = spike_cosim.index("void SpikeCosim::set_mcycle")
        end = spike_cosim.index("void SpikeCosim::set_csr", start)
        body = spike_cosim[start:end]

        self.assertIn("EH2 samples mcycle", body)
        self.assertNotIn("processor->get_state()->mcycle->write(", body)
        self.assertNotIn("processor->get_state()->mcycle->write_upper_half(",
                         body)
        self.assertNotIn("processor->get_csr(CSR_MCYCLE)", body)
        self.assertNotIn("csrmap[CSR_MCYCLE]->read()", body)
        self.assertNotIn("csrmap[CSR_MCYCLE]->write(", body)
        self.assertNotIn("csrmap[CSR_MCYCLEH]->write(", body)
        self.assertNotIn("std::make_shared<basic_csr_t>(processor.get(), CSR_MCYCLE",
                         body)

    def test_spike_cosim_init_returns_adjusted_cosim_pointer(self):
        spike_cosim = (SCRIPT_DIR.parents[3] / "dv" / "cosim" /
                       "spike_cosim.cc").read_text(encoding="utf-8")

        self.assertIn("inherits simif_t first and Cosim second", spike_cosim)
        self.assertIn("static_cast<void *>(static_cast<Cosim *>(cosim))",
                      spike_cosim)
        self.assertNotIn("return static_cast<void *>(cosim);", spike_cosim)

    def test_spike_cosim_keeps_isa_parser_alive(self):
        cosim_dir = SCRIPT_DIR.parents[3] / "dv" / "cosim"
        header = (cosim_dir / "spike_cosim.h").read_text(encoding="utf-8")
        impl = (cosim_dir / "spike_cosim.cc").read_text(encoding="utf-8")

        self.assertIn("std::unique_ptr<isa_parser_t> isa_parser;", header)
        self.assertIn("isa_parser = std::make_unique<isa_parser_t>", impl)
        self.assertIn("isa_parser.get()", impl)
        self.assertNotIn("auto isa = std::make_unique<isa_parser_t>", impl)
        self.assertNotIn("isa.get(), DEFAULT_VARCH", impl)

    def test_spike_cosim_allows_eh2_widened_axi_load_byte_enables(self):
        spike_cosim = (SCRIPT_DIR.parents[3] / "dv" / "cosim" /
                       "spike_cosim.cc").read_text(encoding="utf-8")

        # EH2 LSU widens both loads AND stores at the AXI boundary (sub-word
        # accesses become full aligned words with extra strb bits). spike_cosim
        # accepts BE supersets on either side — see ADR-0005.
        self.assertIn("EH2 widens both loads AND stores", spike_cosim)
        self.assertIn("!store && ((expected_be & ~top_pending_access_info.be) != 0)",
                      spike_cosim)
        self.assertIn("store && ((expected_be & ~top_pending_access_info.be) != 0)",
                      spike_cosim)

    def test_spike_cosim_allows_eh2_forwarded_load_without_pending_dside(self):
        spike_cosim = (SCRIPT_DIR.parents[3] / "dv" / "cosim" /
                       "spike_cosim.cc").read_text(encoding="utf-8")

        self.assertIn("EH2 can satisfy a load internally without an external AXI transaction",
                      spike_cosim)
        self.assertIn("if (!store) {", spike_cosim)
        self.assertIn("return kCheckMemOk;", spike_cosim)

    def test_root_readme_documents_rvvi_cosim_platform(self):
        readme = SCRIPT_DIR.parents[3] / "README.md"

        self.assertTrue(readme.exists())
        text = readme.read_text(encoding="utf-8")
        self.assertIn("cosim-only", text)
        self.assertIn("标准 RVVI-API", text)
        self.assertIn("rvvi_adapter.sv", text)
        self.assertIn("spike_rvvi.cc", text)
        self.assertIn("NHART=2", text)

    def test_signoff_is_cosim_only(self):
        expected = ["smoke", "directed", "cosim", "riscvdv", "compliance"]

        self.assertEqual(signoff.PROFILE_STAGES["full"], expected)
        self.assertEqual(signoff.resolve_stages("full", ""), expected)
        with self.assertRaises(ValueError):
            signoff.resolve_stages("full", "li" + "nt")
        with self.assertRaises(ValueError):
            signoff.parse_stage_result_args(["for" + "mal=/tmp/" + "for" + "mal"])

    def test_signoff_cosim_profile_uses_rvvi_lockstep(self):
        class Args:
            simulator = "vcs"
            seed = 1
            parallel = 1
            coverage = False
            waves = False
            allow_warnings = True
            iterations = 0

        root = SCRIPT_DIR.parents[3]
        cmd = signoff.build_stage_cmd(
            "cosim", Args, Path("/tmp/out"), Path("/tmp/build/simv"))
        smoke_cmd = signoff.build_stage_cmd(
            "smoke", Args, Path("/tmp/out"), Path("/tmp/build/simv"))

        self.assertIn("+use_rvvi_cosim=1", " ".join(cmd))
        self.assertIn("+use_rvvi_cosim=1", " ".join(smoke_cmd))
        self.assertIn(str(root / "dv" / "uvm" / "core_eh2" /
                          "directed_tests" / "cosim_testlist.yaml"), cmd)

    def test_signoff_dry_run_lists_ibex_style_stages(self):
        with tempfile.TemporaryDirectory() as td:
            rc = signoff.main([
                "--profile", "full",
                "--output", str(Path(td) / "signoff"),
                "--dry-run",
            ])

            self.assertEqual(rc, 0)

    def test_signoff_gate_passes_existing_clean_stage_result(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            run_dir = root / "smoke_results" / "smoke_s1"
            result = TestRunResult()
            result.test_name = "smoke"
            result.seed = 1
            result.passed = True
            result.failure_mode = "NONE"
            result.save(str(run_dir / "result"))

            out_dir = root / "signoff"
            rc = signoff.main([
                "--profile", "quick",
                "--stages", "smoke",
                "--stage-result", "smoke={}".format(root / "smoke_results"),
                "--output", str(out_dir),
                "--gate-only",
                "--skip-precheck",
                "--no-require-coverage",
                "--min-line-coverage", "0",
            ])

            self.assertEqual(rc, 0)
            status = yaml.safe_load(
                (out_dir / "signoff_status.json").read_text(encoding="utf-8"))
            self.assertEqual(status["status"], "PASS")
            self.assertTrue((out_dir / "signoff_report.md").exists())

    def test_signoff_gate_accepts_archived_report_json(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            report_dir = root / "archived"
            report_dir.mkdir()
            (report_dir / "report.json").write_text(json.dumps({
                "total": 1,
                "passed": 1,
                "failed": 0,
                "tests": [{
                    "name": "smoke",
                    "seed": 1,
                    "type": "RISCVDV",
                    "passed": True,
                    "failure_mode": "NONE",
                    "instructions": 0,
                    "cycles": 10,
                    "ipc": 0.0,
                    "sim_time_sec": 1.0,
                }]
            }), encoding="utf-8")

            out_dir = root / "signoff"
            rc = signoff.main([
                "--profile", "quick",
                "--stages", "smoke",
                "--stage-result", "smoke={}".format(report_dir),
                "--output", str(out_dir),
                "--gate-only",
                "--skip-precheck",
                "--no-require-coverage",
                "--min-line-coverage", "0",
            ])

            self.assertEqual(rc, 0)
            status = yaml.safe_load(
                (out_dir / "signoff_status.json").read_text(encoding="utf-8"))
            self.assertEqual(status["stages"]["smoke"]["source"], "report.json")

    def test_signoff_coverage_skips_ambient_build_report_when_not_requested(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)

            class Args:
                no_require_coverage = True
                min_overall_coverage = 0.0
                min_line_coverage = 0.0
                min_cond_coverage = 0.0
                min_fsm_coverage = 0.0
                min_toggle_coverage = 0.0
                min_functional_coverage = 0.0

            result = signoff.evaluate_coverage([], root / "signoff", Args)

            self.assertEqual(result["status"], "SKIP")
            self.assertEqual(result["metrics"], {})

    def test_signoff_gate_fails_existing_failed_stage_result(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            run_dir = root / "cosim_results" / "cosim_smoke_s1"
            result = TestRunResult()
            result.test_name = "cosim_smoke"
            result.seed = 1
            result.passed = False
            result.failure_mode = "SIM_CRASH"
            result.save(str(run_dir / "result"))

            out_dir = root / "signoff"
            rc = signoff.main([
                "--profile", "cosim",
                "--stages", "cosim",
                "--stage-result", "cosim={}".format(root / "cosim_results"),
                "--output", str(out_dir),
                "--gate-only",
                "--skip-precheck",
            ])

            self.assertEqual(rc, 1)
            status = yaml.safe_load(
                (out_dir / "signoff_status.json").read_text(encoding="utf-8"))
            self.assertEqual(status["status"], "FAIL")
            self.assertIn("cosim", status["blockers"][0])


if __name__ == "__main__":
    unittest.main()

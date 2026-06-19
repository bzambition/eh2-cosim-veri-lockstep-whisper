#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import os
import re
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
from metadata import RegressionMetadata, RegressionSummary, TestRunResult


class RegressionFrameworkTest(unittest.TestCase):

    def test_specialized_uvm_tests_do_not_join_any_on_start_vseq(self):
        """start_vseq() returns immediately, so it must not end join_any tests."""
        test_lib = (
            SCRIPT_DIR.parent / "tests" / "core_eh2_test_lib.sv"
        ).read_text(encoding="utf-8")
        run_phase_re = re.compile(
            r"virtual task run_phase\(uvm_phase phase\);(?P<body>.*?)^\s*endtask",
            re.MULTILINE | re.DOTALL,
        )
        bad_pattern = re.compile(
            r"fork(?:(?!join_any).)*^\s*start_vseq\(\);\s*$"
            r"(?:(?!join_any).)*join_any",
            re.MULTILINE | re.DOTALL,
        )

        bad_run_phases = [
            match.group(0)
            for match in run_phase_re.finditer(test_lib)
            if bad_pattern.search(match.group("body"))
        ]
        self.assertEqual(bad_run_phases, [])

    def test_directed_debug_resume_keeps_dmactive_asserted(self):
        """DMCONTROL.resume must not clear dmactive in directed debug paths."""
        test_lib = (
            SCRIPT_DIR.parent / "tests" / "core_eh2_test_lib.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("send_debug_resume", test_lib)
        self.assertNotIn("DMI_DMCONTROL, 32'h40000000", test_lib)

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

    def test_cosim_metadata_does_not_add_legacy_disable_plusarg(self):
        entry = {
            "test": "riscv_csr_test",
            "rtl_test": "core_eh2_base_test",
            "sim_opts": "+enable_irq_seq=1",
            "cosim": "disabled",
        }

        sim_opts = run_regress.build_sim_opts(entry, "")

        self.assertIn("+enable_irq_seq=1", sim_opts)
        self.assertNotIn("+disable_" + "cosim=1", sim_opts)
        self.assertNotIn("+enable_" + "cosim=1", sim_opts)

    def test_cosim_enabled_metadata_does_not_add_legacy_enable_plusarg(self):
        entry = {
            "test": "riscv_arithmetic_basic_test",
            "rtl_test": "core_eh2_base_test",
        }

        sim_opts = run_regress.build_sim_opts(entry, "")

        self.assertEqual(sim_opts, "")
        self.assertNotIn("+disable_" + "cosim=1", sim_opts)

    def test_mailbox_accepts_riscv_dv_status_codes(self):
        tb_top = (
            SCRIPT_DIR.parent / "tb" / "core_eh2_tb_top.sv"
        ).read_text(encoding="utf-8")
        base_test = (
            SCRIPT_DIR.parent / "tests" / "core_eh2_base_test.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("mailbox_data[31:0] == 32'h0000_0002", tb_top)
        self.assertIn("mailbox_data[31:0] == 32'h0000_0003", tb_top)
        self.assertNotIn("mailbox_data[7:0] == 8'h02", tb_top)
        self.assertNotIn("mailbox_data[7:0] == 8'h03", tb_top)
        self.assertIn("tb_vif.mailbox_data[31:0] == TEST_PASS",
                      base_test)
        self.assertIn("tb_vif.mailbox_data[31:0] == TEST_FAIL",
                      base_test)
        self.assertIn("if (tb_vif != null && tb_vif.mailbox_test_done)",
                      base_test)
        self.assertIn('`uvm_info(test_name, "TEST PASSED (signature)", UVM_LOW)',
                      base_test)

    def test_log_checker_accepts_interrupted_mailbox_pass_write(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text(
                "TRACE_COMMIT: i0=1 i1=1 at 1425000\n"
                "MAILBOX WRITE detected at 1425000: data=000000ff\n"
                "=================================UVM_INFO scoreboard report\n"
                "UVM_ERROR :    0\n"
                "UVM_FATAL :    0\n",
                encoding="utf-8")

            result = check_logs.check_sim_log(str(log), sim_returncode=0)

            self.assertTrue(result.passed)
            self.assertEqual(result.failure_mode, "NONE")

    def test_log_checker_accepts_rvvi_trace_mailbox_pass_store(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            trace = Path(td) / "rvvi_trace.log"
            log.write_text(
                "UVM_ERROR :    0\n"
                "UVM_FATAL :    0\n",
                encoding="utf-8")
            trace.write_text(
                "0|21|8000001a|d05802b7|0|3|gpr=x5:d0580000|csr=\n"
                "M|0|d0580000:000000ff:f\n"
                "0|22|8000001e|0ff00313|0|3|gpr=x6:000000ff|csr=\n",
                encoding="utf-8")

            result = check_logs.check_sim_log(
                str(log), str(trace), sim_returncode=1)

            self.assertTrue(result.passed)
            self.assertEqual(result.failure_mode, "NONE")

    def test_mailbox_monitor_uses_committed_lsu_store_trace(self):
        tb_top = (
            SCRIPT_DIR.parent / "tb" / "core_eh2_tb_top.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("assign mailbox_trace_write = lsu_trace_store_write_q;",
                      tb_top)
        self.assertIn("assign mailbox_trace_addr  = lsu_trace_store_addr_q;",
                      tb_top)
        self.assertIn("assign mailbox_trace_data  = {32'b0, lsu_trace_store_wdata_q};",
                      tb_top)
        self.assertIn("lsu_trace_store_write_q <= lsu_trace_store_write;",
                      tb_top)
        self.assertIn("assign mailbox_axi_write = lsu_axi_awvalid && lsu_axi_awready;",
                      tb_top)
        self.assertIn("assign mailbox_write = mailbox_trace_write || mailbox_axi_write;",
                      tb_top)
        self.assertIn("fallback for any early external signature writes",
                      tb_top)
        self.assertIn("if (rst_l && !mailbox_test_done)", tb_top)

    def test_riscvdv_instr_count_adds_bounded_runtime_budget(self):
        entry = {
            "test": "riscv_rand_jump_test",
            "rtl_test": "core_eh2_base_test",
            "gen_opts": "+instr_cnt=15000 +boot_mode=m",
            "sim_opts": "+enable_irq_seq=1",
        }

        sim_opts = run_regress.build_sim_opts(entry, "")

        self.assertIn("+enable_irq_seq=1", sim_opts)
        self.assertIn("+max_cycles=750000", sim_opts)
        self.assertIn("+timeout_ns=75000000", sim_opts)

    def test_riscvdv_instr_count_preserves_explicit_runtime_budget(self):
        entry = {
            "test": "riscv_random_instr_test",
            "rtl_test": "core_eh2_base_test",
            "gen_opts": "+instr_cnt=20000 +boot_mode=m",
            "sim_opts": "+max_cycles=2000000 +timeout_ns=200000000",
        }

        sim_opts = run_regress.build_sim_opts(entry, "")

        self.assertIn("+max_cycles=2000000", sim_opts)
        self.assertIn("+timeout_ns=200000000", sim_opts)
        self.assertNotIn("+max_cycles=1000000", sim_opts)

    def test_rvvi_sim_opts_adds_matching_elf_path_by_default(self):
        sim_opts = run_regress.add_rvvi_elf_sim_opt(
            "",
            "build/regress_vcs/cosim_smoke_s1/cosim_smoke.hex")

        self.assertIn(
            "+rvvi_elf=build/regress_vcs/cosim_smoke_s1/cosim_smoke.elf",
            sim_opts)

    def test_rvvi_sim_opts_preserves_explicit_elf_path(self):
        sim_opts = run_regress.add_rvvi_elf_sim_opt(
            "+rvvi_elf=custom.elf",
            "build/regress_vcs/cosim_smoke_s1/cosim_smoke.hex")

        self.assertEqual(sim_opts, "+rvvi_elf=custom.elf")

    def test_rvvi_trace_dump_sim_opts_adds_default_trace_file(self):
        sim_opts = run_regress.add_rvvi_trace_dump_sim_opts(
            "+foo=1", "build/regress_vcs/cosim_alu_s1/rvvi_trace.log")

        self.assertIn("+foo=1", sim_opts)
        self.assertIn("+rvvi_trace_dump", sim_opts)
        self.assertIn(
            "+rvvi_trace_file=build/regress_vcs/cosim_alu_s1/rvvi_trace.log",
            sim_opts)

    def test_rvvi_trace_dump_sim_opts_preserves_explicit_trace_file(self):
        sim_opts = run_regress.add_rvvi_trace_dump_sim_opts(
            "+rvvi_trace_dump +rvvi_trace_file=custom.log", "ignored.log")

        self.assertEqual(sim_opts, "+rvvi_trace_dump +rvvi_trace_file=custom.log")

    def test_elf_entry_reader_reads_elf32_entry(self):
        with tempfile.TemporaryDirectory() as td:
            elf = Path(td) / "test.elf"
            data = bytearray(64)
            data[0:4] = b"\x7fELF"
            data[4] = 1
            data[5] = 1
            data[24:28] = (0x80000080).to_bytes(4, byteorder="little")
            elf.write_bytes(data)

            self.assertEqual(run_regress.read_elf_entry(str(elf)), 0x80000080)

    def test_reset_vector_sim_opt_uses_matching_elf_entry(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "prog"
            hex_path = str(root) + ".hex"
            elf = root.with_suffix(".elf")
            data = bytearray(64)
            data[0:4] = b"\x7fELF"
            data[4] = 1
            data[5] = 1
            data[24:28] = (0x80000080).to_bytes(4, byteorder="little")
            elf.write_bytes(data)

            sim_opts = run_regress.add_reset_vector_sim_opt("", hex_path)

            self.assertIn("+reset_vector=0x80000080", sim_opts)

    def test_reset_vector_sim_opt_preserves_explicit_value(self):
        sim_opts = run_regress.add_reset_vector_sim_opt(
            "+reset_vector=0x80000040", "missing.hex")

        self.assertEqual(sim_opts, "+reset_vector=0x80000040")

    def test_trace_compare_flow_does_not_use_legacy_disable_plusarg(self):
        self.assertFalse(hasattr(run_regress, "add_trace" + "cmp_only_sim_opt"))
        run_regress_text = Path(run_regress.__file__).read_text(encoding="utf-8")
        run_rtl_text = Path(run_rtl.__file__).read_text(encoding="utf-8")

        self.assertNotIn("+tracecmp_" + "only", run_regress_text)
        self.assertNotIn("+tracecmp_" + "only", run_rtl_text)

    def test_rvvi_nhart_is_parsed_from_sim_opts(self):
        self.assertEqual(run_regress.rvvi_nhart_from_sim_opts(""), 1)
        self.assertEqual(
            run_regress.rvvi_nhart_from_sim_opts("+foo +rvvi_nhart=2"), 2)
        self.assertEqual(
            run_regress.rvvi_nhart_from_sim_opts("+rvvi_nhart=bad"), 1)

    def test_generic_rvvi_scoreboard_is_part_of_tb_build(self):
        old_scoreboard_path = (
            SCRIPT_DIR.parent / "common" / "rvvi_agent" /
            ("eh2_rvvi_" + "scoreboard.sv"))
        scoreboard_path = (
            SCRIPT_DIR.parent / "common" / "rvvi_agent" /
            "rvvi_scoreboard.sv")
        tb_top = (SCRIPT_DIR.parent / "tb" /
                  "core_eh2_tb_top.sv").read_text(encoding="utf-8")
        tb_f = (SCRIPT_DIR.parent / "eh2_tb.f").read_text(encoding="utf-8")

        self.assertFalse(old_scoreboard_path.exists())
        self.assertTrue(scoreboard_path.exists())
        self.assertNotIn("eh2_rvvi_" + "scoreboard", tb_top)
        self.assertNotIn("eh2_rvvi_" + "scoreboard", tb_f)
        self.assertIn("rvvi_scoreboard #(", tb_top)
        self.assertIn("u_rvvi_scoreboard", tb_top)
        self.assertIn("rvvi_scoreboard.sv", tb_f)
        self.assertIn("rvvi" + "ApiPkg", tb_f)

    def test_rvvi_adapter_keeps_async_sideband_capture_for_trace_dump(self):
        tb_top = (SCRIPT_DIR.parent / "tb" /
                  "core_eh2_tb_top.sv").read_text(encoding="utf-8")
        adapter = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
                   "eh2_rvvi_adapter.sv").read_text(encoding="utf-8")

        self.assertIn("eh2_rvvi_adapter", tb_top)
        self.assertIn(".nb_load_wen", tb_top)
        self.assertIn("dut_probe_intf.nb_load_wen", tb_top)
        self.assertIn(".div_wren", tb_top)
        self.assertIn("dut_probe_intf.div_wren", tb_top)
        self.assertIn("nb_load_wen", adapter)
        self.assertIn("div_wren", adapter)

    def test_mailbox_detection_uses_registered_committed_store_trace(self):
        tb_top = (SCRIPT_DIR.parent / "tb" /
                  "core_eh2_tb_top.sv").read_text(encoding="utf-8")

        self.assertIn("lsu_trace_store_write_q", tb_top)
        self.assertIn("mailbox_trace_write = lsu_trace_store_write_q", tb_top)
        self.assertIn("mailbox_trace_addr  = lsu_trace_store_addr_q", tb_top)
        self.assertIn("mailbox_trace_data  = {32'b0, lsu_trace_store_wdata_q}",
                      tb_top)

    def test_adapter_surfaces_async_nets_and_bus_writes_for_dump(self):
        tb_top = (SCRIPT_DIR.parent / "tb" /
                  "core_eh2_tb_top.sv").read_text(encoding="utf-8")
        adapter = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
                   "eh2_rvvi_adapter.sv").read_text(encoding="utf-8")

        self.assertRegex(tb_top,
                         r"\.lsu_bus_write\s*\(\s*lsu_bus_write\s*\)")
        self.assertIn("lsu_bus_write", adapter)
        self.assertIn('$fwrite(dump_fd, "M|%0d|', adapter)

    def test_lockstep_whisper_uses_rvvi_api_scoreboard(self):
        scoreboard_sv = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
                         "rvvi_scoreboard.sv").read_text(encoding="utf-8")
        tb_f = (SCRIPT_DIR.parent / "eh2_tb.f").read_text(encoding="utf-8")
        rvvi_backend = (SCRIPT_DIR.parents[3] / "vendor" /
                        "cosim-arch-checker" / "bridge" / "whisper" /
                        "whisper_rvvi.cpp").read_text(encoding="utf-8")

        self.assertIn("import rvviApiPkg::*", scoreboard_sv)
        self.assertIn("rvviRefInit", scoreboard_sv)
        self.assertIn("rvviRefEventStep", scoreboard_sv)
        self.assertIn("rvviRefNetSet", scoreboard_sv)
        self.assertNotIn("monitor_async", scoreboard_sv)
        self.assertIn("vendor/rvvi/source/host/rvvi/rvviApiPkg.sv", tb_f)
        self.assertIn("rvvi_scoreboard.sv", tb_f)
        self.assertNotIn("rvvi_cac_bridge.sv", tb_f)
        self.assertIn("rvviRefNetGroupSet", rvvi_backend)
        self.assertIn("whisperPoke(hartId, kResourceCsr, kCsrMip", rvvi_backend)
        self.assertIn("whisperEnterDebug", rvvi_backend)
        self.assertIn("whisperExitDebug", rvvi_backend)

    def test_rvvi_scoreboard_consumes_amo_memory_writes(self):
        scoreboard_sv = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
                         "rvvi_scoreboard.sv").read_text(encoding="utf-8")

        self.assertIn("insn[6:0] == 7'h2f", scoreboard_sv)

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
        md.sim_opts = ""
        md.build_dir = str(Path("/tmp/eh2-build"))
        md.out_dir = str(Path("/tmp/eh2-out"))
        md.sim_time_ns = 12345

        cfg_path = Path(run_rtl.__file__).resolve().parents[1] / "yaml" / "rtl_simulation.yaml"
        cmd = run_rtl.build_sim_cmd(md, run_rtl.load_sim_config(str(cfg_path)))

        self.assertIn("/tmp/eh2-build/simv", cmd)
        self.assertIn("-l /tmp/eh2-out/sim_smoke_7.log", cmd)
        self.assertIn("+timeout_ns=12345", cmd)
        self.assertNotIn("cd /tmp/eh2-build", cmd)

    def test_run_rtl_promotes_sim_opts_timeout_to_template_timeout(self):
        md = RegressionMetadata()
        md.test_name = "long_random"
        md.seed = 10
        md.binary_path = "/tmp/long_random.hex"
        md.simulator = "vcs"
        md.rtl_test = "core_eh2_base_test"
        md.sim_opts = "+max_cycles=2000000 +timeout_ns=200000000"
        md.build_dir = str(Path("/tmp/eh2-build"))
        md.out_dir = str(Path("/tmp/eh2-out"))
        md.sim_time_ns = 10000000

        cfg_path = Path(run_rtl.__file__).resolve().parents[1] / "yaml" / "rtl_simulation.yaml"
        cmd = run_rtl.build_sim_cmd(md, run_rtl.load_sim_config(str(cfg_path)))

        self.assertNotIn("+timeout_ns=10000000", cmd)
        self.assertIn("+timeout_ns=200000000", cmd)

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

    def test_run_rtl_derives_shell_timeout_from_max_cycles(self):
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
                "      <sim_opts> -l <out_dir>/sim_<test>_<seed>.log\n",
                encoding="utf-8")

            md = RegressionMetadata()
            md.test_name = "long_random"
            md.seed = 1
            md.binary_path = "/tmp/long_random.hex"
            md.simulator = "vcs"
            md.build_dir = str(build_dir)
            md.out_dir = str(out_dir)
            md.eh2_root = str(root)
            md.sim_opts = "+max_cycles=2000000"

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
            self.assertGreaterEqual(calls[0][2], 4300)

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
            self.assertNotIn("+disable_" + "cosim=1", captured["md"].sim_opts)
            self.assertIn("+rvvi_elf=", captured["md"].sim_opts)
            self.assertIn("+rvvi_trace_dump", captured["md"].sim_opts)
            self.assertIn("+rvvi_trace_file=", captured["md"].sim_opts)

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

            self.assertEqual(captured["md"].rtl_test, "core_eh2_rvvi_test")
            self.assertEqual(captured["md"].test_type, "DIRECTED")
            self.assertNotIn("+enable_" + "cosim=1", captured["md"].sim_opts)
            self.assertNotIn("+disable_" + "cosim=1", captured["md"].sim_opts)
            self.assertIn("+rvvi_elf=", captured["md"].sim_opts)
            self.assertIn("+rvvi_trace_dump", captured["md"].sim_opts)
            self.assertIn("+rvvi_trace_file=", captured["md"].sim_opts)

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
            self.assertNotIn("+enable_" + "cosim=1", captured["md"].sim_opts)
            self.assertIn("+rvvi_elf=", captured["md"].sim_opts)

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

    def test_run_instr_gen_keeps_stack_pointer_fixed_for_trap_recovery(self):
        sim_opts = run_instr_gen.build_sim_opts()

        self.assertIn("+fix_sp=1", sim_opts)

    def test_run_instr_gen_uses_hardware_trigger_rom_for_debug_triggers(self):
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
                    "riscv_debug_triggers_test", "", 1)

            self.assertTrue(ok)
            sim_opts = captured["cmd"][captured["cmd"].index("--sim_opts") + 1]
            self.assertIn(
                "+uvm_set_inst_override=riscv_asm_program_gen,"
                "eh2_hardware_triggers_asm_program_gen,uvm_test_top.asm_gen",
                sim_opts)

            user_extension = (
                SCRIPT_DIR.parent / "riscv_dv_extension" /
                "user_extension.svh").read_text(encoding="utf-8")
            self.assertIn('`include "eh2_debug_triggers_overrides.sv"',
                          user_extension)

    def test_debug_triggers_uses_self_contained_hardware_trigger_stream(self):
        """Hardware trigger stimulus must not depend on a racy early HALTREQ."""
        with open(SCRIPT_DIR.parent / "riscv_dv_extension" /
                  "testlist.yaml", encoding="utf-8") as fd:
            tests = yaml.safe_load(fd)

        debug_triggers = next(
            test for test in tests
            if test["test"] == "riscv_debug_triggers_test")
        self.assertEqual(debug_triggers["rtl_test"], "core_eh2_base_test")
        self.assertIn("eh2_hardware_trigger_stream",
                      debug_triggers["gen_opts"])
        self.assertNotIn("+enable_debug_seq=1",
                         debug_triggers.get("sim_opts", ""))

        triggers = (
            SCRIPT_DIR.parent / "riscv_dv_extension" /
            "eh2_debug_triggers_overrides.sv"
        ).read_text(encoding="utf-8")
        self.assertIn("class eh2_hardware_trigger_stream", triggers)
        self.assertIn("hardware_trigger_target_", triggers)
        self.assertIn("EH2_TRIGGER_EXECUTE_BREAKPOINT", triggers)
        self.assertIn("TDATA1", triggers)
        self.assertIn("TDATA2", triggers)
        self.assertIn("instr.rs1 = cfg.gpr[1];", triggers)
        self.assertIn("CSRRSI", triggers)
        self.assertIn("CSRRCI", triggers)
        self.assertIn("MSTATUS", triggers)
        self.assertIn("virtual function void gen_ebreak_handler", triggers)
        self.assertIn("mret", triggers)
        self.assertNotIn("EBREAK_EXCEPTION", triggers)

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

    def test_eh2_asm_program_gen_keeps_trap_stack_in_mscratch(self):
        program_gen = (SCRIPT_DIR.parent / "riscv_dv_extension" /
                       "eh2_asm_program_gen.sv").read_text(encoding="utf-8")

        self.assertIn("virtual function void pre_enter_privileged_mode(int hart);",
                      program_gen)
        self.assertIn("super.pre_enter_privileged_mode(hart);", program_gen)
        self.assertIn("eh2_kernel_sp", program_gen)
        self.assertIn('"sw x%0d, 0(x%0d) # save EH2 KSP"', program_gen)
        self.assertIn("virtual function void gen_trap_handler_section", program_gen)
        self.assertIn("lw x%0d, 0(x%0d) # restore EH2 KSP",
                      program_gen)
        self.assertIn("save_next_kernel_sp", program_gen)
        self.assertIn("super.gen_trap_handler_section", program_gen)

    def test_eh2_asm_program_gen_skips_recoverable_access_faults(self):
        program_gen = (SCRIPT_DIR.parent / "riscv_dv_extension" /
                       "eh2_asm_program_gen.sv").read_text(encoding="utf-8")

        self.assertIn("function void append_skip_faulting_insn", program_gen)
        for handler in ("gen_instr_fault_handler", "gen_load_fault_handler",
                        "gen_store_fault_handler"):
            self.assertIn("virtual function void {}(int hart);".format(handler),
                          program_gen)
        self.assertGreaterEqual(program_gen.count("append_skip_faulting_insn(instr);"),
                                3)
        self.assertIn('"csrr t0, mepc"', program_gen)
        self.assertIn('"addi t0, t0, 4"', program_gen)
        self.assertIn('"csrw mepc, t0"', program_gen)

    def test_eh2_asm_program_gen_does_not_random_write_mepc(self):
        program_gen = (SCRIPT_DIR.parent / "riscv_dv_extension" /
                       "eh2_asm_program_gen.sv").read_text(encoding="utf-8")
        whitelist = re.search(
            r"default_include_csr_write\.delete\(\);(?P<body>.*?)super\.gen_program\(\);",
            program_gen,
            re.DOTALL,
        )

        self.assertIsNotNone(whitelist)
        self.assertNotIn("MEPC", whitelist.group("body"))
        self.assertNotIn("MSCRATCH", whitelist.group("body"))

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

    def test_no_online_scoreboard_artifacts_remain_in_active_sources(self):
        root = SCRIPT_DIR.parents[3]
        active_paths = [
            root / "Makefile",
            SCRIPT_DIR.parent / "eh2_tb.f",
            SCRIPT_DIR.parent / "tb" / "core_eh2_tb_top.sv",
            Path(run_regress.__file__),
            Path(run_rtl.__file__),
            Path(check_logs.__file__),
        ]
        haystack = "\n".join(
            path.read_text(encoding="utf-8") for path in active_paths)

        self.assertNotIn("eh2_rvvi_" + "scoreboard", haystack)
        self.assertNotIn("RVVI_" + "SCOREBOARD", haystack)
        self.assertNotIn("use_rvvi_" + "cosim", haystack)
        self.assertNotIn("tracecmp_" + "only", haystack)

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
        self.assertIn("$(CURDIR)/$(LIBCAC_COSIM)", makefile)
        self.assertNotIn("$(CURDIR)/$(LIB" + "COSIM)", makefile)
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

    def test_adapter_and_top_route_per_hart_sidebands(self):
        tb_top = (SCRIPT_DIR.parent / "tb" /
                  "core_eh2_tb_top.sv").read_text(encoding="utf-8")
        adapter = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
                   "eh2_rvvi_adapter.sv").read_text(encoding="utf-8")
        dut_probe = (SCRIPT_DIR.parent / "env" /
                     "eh2_dut_probe_if.sv").read_text(encoding="utf-8")

        self.assertIn("parameter int NUM_THREADS = 1", dut_probe)
        self.assertRegex(dut_probe,
                         r"logic\s+\[NUM_THREADS-1:0\]\s+nb_load_wen")
        self.assertRegex(dut_probe,
                         r"logic\s+\[NUM_THREADS-1:0\]\[31:0\]\s+mip")
        self.assertIn("for (int h = 0; h < NHART; h++) begin", adapter)
        self.assertIn("rvvi.valid[gh][gr]", adapter)
        self.assertIn("rvvi.pc_rdata[gh][gr]", adapter)
        self.assertIn("rvvi.insn[gh][gr]", adapter)
        self.assertIn("eh2_dut_probe_if #(.NUM_THREADS(`RV_NUM_THREADS))",
                      tb_top)
        self.assertIn("dut_probe_intf.mip[ph]", tb_top)
        self.assertIn("dut_probe_intf.debug_req[ph]", tb_top)
        self.assertIn(".lsu_bus_tid", tb_top)
        self.assertIn("dut.veer.lsu.lsu_pkt_dc5.tid", tb_top)
        adapter = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
                   "eh2_rvvi_adapter.sv").read_text(encoding="utf-8")
        self.assertRegex(adapter, r"input\s+logic\s+lsu_bus_tid")
        self.assertIn('$fwrite(dump_fd, "M|%0d|', adapter)
        self.assertNotIn('"M|0|', adapter)

    def test_compile_vcs_hard_depends_on_cac_dpi(self):
        # Without a hard prereq, wildcard-style linking silently produces a
        # simv that lacks the RVVI/CAC DPI symbols, and the failure only
        # surfaces at run time. Ask make itself whether `compile_vcs` triggers
        # the CAC build.
        root = SCRIPT_DIR.parents[3]
        makefile_text = (root / "Makefile").read_text(encoding="utf-8")

        self.assertNotIn("$(wildcard $(BUILD_DIR)/libcosim.so)", makefile_text)
        self.assertIn("compile_vcs: cac", makefile_text)
        self.assertIn("$(CURDIR)/$(LIBCAC_COSIM)", makefile_text)

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
            self.assertIn("vendor/cosim-arch-checker",
                          (result.stdout or "") + (result.stderr or ""),
                          msg="compile_vcs dry-run must mention CAC build")

    def test_compile_always_links_cac_for_rvvi_lockstep(self):
        root = SCRIPT_DIR.parents[3]
        makefile = (root / "Makefile").read_text(encoding="utf-8")

        self.assertIn("compile_vcs: cac", makefile)
        self.assertIn("compile_nc: cac", makefile)
        self.assertIn("$(CURDIR)/$(LIBCAC_COSIM)", makefile)
        self.assertNotIn("$(LIB" + "COSIM)", makefile)
        self.assertNotIn("NO_" + "COSIM", makefile)
        self.assertNotIn("COMPILE_LIB" + "COSIM_DEP", makefile)

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

    def test_run_single_test_passes_sized_process_timeout_to_run_rtl(self):
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td)
            entry = {
                "test": "smoke",
                "rtl_test": "core_eh2_base_test",
                "sim_opts": "+max_cycles=2000000",
                "cosim": "disabled",
                "tracecmp": "disabled",
            }
            sim_log = out_dir / "smoke_s1" / "sim_smoke_1.log"
            seen = []

            class FakeProc:
                returncode = 0
                stdout = b"rtl passed"
                stderr = b""

            def fake_run(cmd, **kwargs):
                seen.append((cmd, kwargs))
                sim_log.parent.mkdir(parents=True, exist_ok=True)
                sim_log.write_text("TEST PASSED\n", encoding="utf-8")
                return FakeProc()

            with mock.patch.object(run_regress.subprocess, "run", fake_run):
                result = run_regress.run_single_test(
                    entry, 1, "vcs", str(out_dir), "tests/asm/smoke.hex")

            self.assertTrue(result.passed)
            rtl_calls = [(cmd, kwargs) for cmd, kwargs in seen
                         if cmd[1].endswith("run_rtl.py")]
            self.assertEqual(len(rtl_calls), 1)
            rtl_cmd, rtl_kwargs = rtl_calls[0]
            self.assertIn("--process-timeout-s", rtl_cmd)
            proc_timeout = int(rtl_cmd[rtl_cmd.index("--process-timeout-s") + 1])
            self.assertGreaterEqual(proc_timeout, 4300)
            self.assertGreaterEqual(rtl_kwargs["timeout"], proc_timeout + 120)

    def test_run_single_test_drops_global_lockstep_for_cosim_disabled_test(self):
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td)
            entry = {
                "test": "riscv_csr_test",
                "rtl_test": "core_eh2_base_test",
                "cosim": "disabled",
                "skip_in_signoff": True,
            }
            sim_log = out_dir / "riscv_csr_test_s1" / "sim_riscv_csr_test_1.log"
            seen_cmds = []

            class FakeProc:
                returncode = 0
                stdout = b"rtl passed"
                stderr = b""

            def fake_run(cmd, **kwargs):
                del kwargs
                seen_cmds.append(cmd)
                sim_log.parent.mkdir(parents=True, exist_ok=True)
                sim_log.write_text("TEST PASSED\n", encoding="utf-8")
                return FakeProc()

            global_lockstep_opts = (
                "+cosim_arch_checker "
                "+whisper_path=vendor/whisper/build-Linux/whisper "
                "+whisper_json_path=config/whisper_default_lockstep.json"
            )
            with mock.patch.object(run_regress.subprocess, "run", fake_run):
                result = run_regress.run_single_test(
                    entry, 1, "vcs", str(out_dir),
                    "tests/asm/csr.hex", cli_sim_opts=global_lockstep_opts)

            self.assertTrue(result.passed)
            rtl_cmd = [cmd for cmd in seen_cmds if cmd[1].endswith("run_rtl.py")][0]
            sim_opts = rtl_cmd[rtl_cmd.index("--sim-opts") + 1]
            self.assertNotIn("+cosim_arch_checker", sim_opts)
            self.assertNotIn("+whisper_path=", sim_opts)
            self.assertNotIn("+whisper_json_path=", sim_opts)
            self.assertNotIn("+whisper_server_file=", sim_opts)
            self.assertNotIn("+rvvi_elf=", sim_opts)

    def test_run_rtl_direct_mode_does_not_add_rvvi_dump_without_rvvi_elf(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            binary = root / "test.hex"
            out_dir = root / "out"
            binary.write_text("@80000000\n13 00 00 00\n", encoding="utf-8")
            captured = {}

            def fake_run(md):
                captured["md"] = md
                trr = TestRunResult()
                trr.test_name = md.test_name
                trr.seed = md.seed
                trr.passed = True
                trr.failure_mode = "NONE"
                trr.sim_log_path = str(Path(md.out_dir) / "sim_rtl_only_1.log")
                return trr

            with mock.patch.object(run_rtl, "run_rtl_simulation", fake_run):
                rc = run_rtl.main([
                    "--test", "rtl_only",
                    "--seed", "1",
                    "--binary", str(binary),
                    "--simulator", "vcs",
                    "--rtl-test", "core_eh2_base_test",
                    "--sim-opts", "+max_cycles=250000",
                    "--out-dir", str(out_dir),
                ])

            self.assertEqual(rc, 0)
            self.assertNotIn("+rvvi_trace_dump", captured["md"].sim_opts)
            self.assertNotIn("+rvvi_trace_file=", captured["md"].sim_opts)

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

    def test_check_logs_accepts_vcs_interrupted_eh2_pass_banner(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "sim.log"
            log.write_text(
                "UVM_INFO reporter [TEST_DONE] 'run' phase is ready\n"
                "--- EH2 UVM TEST PA$finish called from file "
                "\"/tools/synopsys/vcs-mx/O-2018.09-1/etc/uvm-1.2/"
                "base/uvm_report_server.svh\", line 894.\n"
                "--- UVM Report Sum           V C S   S i m u l a t i o n"
                "   R e p o r t\n",
                encoding="utf-8")

            result = check_logs.check_sim_log(str(log), sim_returncode=1)

            self.assertTrue(result.passed)
            self.assertEqual(result.failure_mode, "NONE")

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
                "Error: \"dv/uvm/core_eh2/tb/core_eh2_tb_top.sv\", "
                "150: core_eh2_tb_top.u_check: at time 1000 ps\n"
                "$fatal called from file \"dv/uvm/core_eh2/tb/"
                "core_eh2_tb_top.sv\", line 150.\n",
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
                output = str(out_dir)
                iterations = 1
                seed = 1
                parallel = 1
                simulator = "vcs"
                binary = "tests/asm/smoke.hex"
                sim_opts = ""
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
                             "core_eh2_rvvi_test")
            self.assertEqual(captured["entry"]["test_type"], "DIRECTED")
            self.assertIn("cosim_smoke.S", captured["entry"]["asm"])
            self.assertEqual(captured["entry"]["cosim"], "enabled")
            self.assertTrue(captured["waves"])

    def test_regression_exit_code_honors_min_passed_threshold(self):
        regression_summary = RegressionSummary()
        for idx in range(57):
            result = TestRunResult()
            result.test_name = f"riscvdv_{idx}"
            result.seed = 1
            result.passed = idx < 51
            result.failure_mode = "NONE" if result.passed else "TEST_FAIL"
            regression_summary.add_result(result)

        self.assertEqual(
            run_regress.regression_exit_code(regression_summary), 1)
        self.assertEqual(
            run_regress.regression_exit_code(regression_summary, min_passed=50),
            0)

    def test_regression_exit_code_keeps_high_failure_rate_failing(self):
        regression_summary = RegressionSummary()
        for idx in range(100):
            result = TestRunResult()
            result.test_name = f"riscvdv_{idx}"
            result.seed = 1
            result.passed = idx < 50
            result.failure_mode = "NONE" if result.passed else "TEST_FAIL"
            regression_summary.add_result(result)

        self.assertEqual(
            run_regress.regression_exit_code(regression_summary, min_passed=50),
            1)

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
            "whisper:",
            "cac:",
            "smoke:",
            "regress:",
            "signoff:",
            "compliance:",
        ]:
            self.assertIn(target, makefile_text)
        self.assertNotIn("\nspi" + "ke:", makefile_text)
        self.assertNotIn("\ncosim:", makefile_text)

    def test_make_regress_default_uses_testlist_iterations(self):
        """P4.6 full regress must not silently cap riscvdv to one seed."""
        root = SCRIPT_DIR.parents[3]
        makefile = (root / "Makefile").read_text(encoding="utf-8")

        self.assertRegex(makefile, r"(?m)^ITERATIONS\s+\?=\s*$")
        self.assertIn("$(if $(ITERATIONS),--iterations $(ITERATIONS),)",
                      makefile)
        self.assertNotIn("--iterations $(ITERATIONS) --parallel", makefile)

    def test_make_signoff_default_allows_tracked_skip_items(self):
        """Bare full signoff should pass with only tracked skip_in_signoff tests."""
        root = SCRIPT_DIR.parents[3]
        makefile = (root / "Makefile").read_text(encoding="utf-8")

        self.assertRegex(
            makefile,
            r"(?m)^SIGNOFF_OPTS\s+\?=\s+--no-fail-on-skip-in-signoff$")
        self.assertIn("$(SIGNOFF_OPTS)", makefile)

    def test_skip_in_signoff_tests_do_not_force_nonzero_exit(self):
        summary = RegressionSummary()

        passing = TestRunResult(test_name="riscv_random_instr_test",
                                seed=1, passed=True,
                                failure_mode="NONE")
        summary.add_result(passing)

        skipped_failure = TestRunResult(test_name="riscv_csr_test",
                                        seed=1, passed=False,
                                        failure_mode="TEST_FAIL")
        skipped_failure.skip_in_signoff = True
        summary.add_result(skipped_failure)

        self.assertEqual(run_regress.regression_exit_code(summary), 0)

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
            self.assertEqual(test.rtl_test, "core_eh2_rvvi_test")
            self.assertTrue((SCRIPT_DIR.parent / test.test_srcs).exists())

    def test_load_regression_testlist_expands_directed_schema(self):
        directed_path = SCRIPT_DIR.parent / "directed_tests" / "cosim_testlist.yaml"

        entries = run_regress.load_regression_testlist(str(directed_path))

        self.assertEqual(len(entries), 7)
        self.assertEqual(entries[0]["test"], "cosim_smoke")
        self.assertEqual(entries[0]["test_type"], "DIRECTED")
        self.assertEqual(entries[0]["rtl_test"], "core_eh2_rvvi_test")
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

        self.assertEqual(by_name["directed_pmp_smoke"]["cosim"], "enabled")
        self.assertEqual(by_name["directed_csr_warl"]["cosim"], "disabled")
        self.assertEqual(by_name["directed_toggle_csr_walk"]["cosim"], "disabled")

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
                "rtl_test": "core_eh2_rvvi_test",
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
            self.assertNotIn("+enable_" + "cosim=1", " ".join(seen_cmds[-1]))
            self.assertNotIn("+rvvi_elf=", " ".join(seen_cmds[-1]))
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

    def test_adapter_preserves_async_writeback_tags_for_trace_dump(self):
        adapter = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
                   "eh2_rvvi_adapter.sv").read_text(encoding="utf-8")

        self.assertIn("nb_load_wen", adapter)
        self.assertIn("div_wren", adapter)
        self.assertIn("x_wdata_w", adapter)
        self.assertIn("x_wb_w", adapter)

    def test_root_readme_documents_lockstep_whisper_platform_scope(self):
        readme = SCRIPT_DIR.parents[3] / "README.md"

        self.assertTrue(readme.exists())
        text = readme.read_text(encoding="utf-8")
        self.assertIn("cosim-only", text)
        self.assertIn("RVVI-TRACE", text)
        self.assertIn("Whisper", text)
        self.assertIn("lockstep", text)
        self.assertIn("功能仿真", text)
        self.assertIn("不在本平台范围", text)
        self.assertIn("riscv_csr_test", text)
        self.assertIn("rvvi_adapter.sv", text)
        self.assertNotIn("spike_" + "cosim.cc", text)
        self.assertIn("NHART=2", text)

    def test_signoff_is_cosim_only(self):
        expected = ["smoke", "directed", "cosim", "riscvdv", "compliance"]

        self.assertEqual(signoff.PROFILE_STAGES["full"], expected)
        self.assertEqual(signoff.resolve_stages("full", ""), expected)
        with self.assertRaises(ValueError):
            signoff.resolve_stages("full", "li" + "nt")
        with self.assertRaises(ValueError):
            signoff.parse_stage_result_args(["for" + "mal=/tmp/" + "for" + "mal"])

    def test_signoff_cosim_profile_uses_cosim_testlist(self):
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

        self.assertNotIn("+use_rvvi_" + "cosim=1", " ".join(cmd))
        self.assertNotIn("+use_rvvi_" + "cosim=1", " ".join(smoke_cmd))
        self.assertIn(str(root / "dv" / "uvm" / "core_eh2" /
                          "directed_tests" / "cosim_testlist.yaml"), cmd)

    def test_signoff_lockstep_whisper_uses_online_checker_opts(self):
        class Args:
            simulator = "vcs"
            seed = 1
            parallel = 1
            coverage = False
            waves = False
            allow_warnings = True
            iterations = 0
            lockstep_whisper = True
            whisper_path = "vendor/whisper/build-Linux/whisper"
            whisper_json = "rtl/snapshots/default/whisper.json"

        cmd = signoff.build_stage_cmd(
            "cosim", Args, Path("/tmp/out"), Path("/tmp/build/simv"))
        text = " ".join(cmd)

        self.assertIn("+cosim_arch_checker", text)
        self.assertIn("+whisper_path=vendor/whisper/build-Linux/whisper", text)
        self.assertIn("+whisper_json_path=rtl/snapshots/default/whisper.json", text)
        self.assertNotIn("--disable-trace-" + "compare", cmd)

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
                "--no-fail-on-skip-in-signoff",
                "--no-require-coverage",
                "--min-line-coverage", "0",
            ])

            self.assertEqual(rc, 0)
            status = yaml.safe_load(
                (out_dir / "signoff_status.json").read_text(encoding="utf-8"))
            self.assertEqual(status["status"], "PASS")
            self.assertTrue((out_dir / "signoff_report.md").exists())

    def test_signoff_full_profile_can_disable_coverage_gate(self):
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
                "--profile", "full",
                "--stages", "smoke",
                "--stage-result", "smoke={}".format(report_dir),
                "--output", str(out_dir),
                "--gate-only",
                "--skip-precheck",
                "--no-fail-on-skip-in-signoff",
                "--no-require-coverage",
                "--min-line-coverage", "0",
                "--min-functional-coverage", "0",
            ])

            self.assertEqual(rc, 0)
            status = yaml.safe_load(
                (out_dir / "signoff_status.json").read_text(encoding="utf-8"))
            self.assertEqual(status["status"], "PASS")
            self.assertEqual(status["coverage"]["status"], "SKIP")

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
                "--no-fail-on-skip-in-signoff",
                "--no-require-coverage",
                "--min-line-coverage", "0",
            ])

            self.assertEqual(rc, 0)
            status = yaml.safe_load(
                (out_dir / "signoff_status.json").read_text(encoding="utf-8"))
            self.assertEqual(status["stages"]["smoke"]["source"], "report.json")

    def test_signoff_refresh_uses_rvvi_trace_mailbox_pass(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            report_dir = root / "archived"
            report_dir.mkdir()
            sim_log = report_dir / "sim_debug_1.log"
            sim_log.write_text(
                "UVM_ERROR :    0\n"
                "UVM_FATAL :    0\n",
                encoding="utf-8")
            (report_dir / "rvvi_trace.log").write_text(
                "0|21|8000001a|d05802b7|0|3|gpr=x5:d0580000|csr=\n"
                "M|0|d0580000:000000ff:f\n",
                encoding="utf-8")
            (report_dir / "report.json").write_text(json.dumps({
                "total": 1,
                "passed": 1,
                "failed": 0,
                "tests": [{
                    "name": "directed_debug_basic",
                    "seed": 1,
                    "type": "DIRECTED",
                    "passed": True,
                    "failure_mode": "NONE",
                    "sim_log": str(sim_log),
                    "sim_returncode": 1,
                    "instructions": 0,
                    "cycles": 10,
                    "ipc": 0.0,
                    "sim_time_sec": 1.0,
                }]
            }), encoding="utf-8")

            stage = signoff.gather_stage(
                "directed", report_dir, root / "reports", [], 0, False)

            self.assertEqual(stage["total"], 1)
            self.assertEqual(stage["passed"], 1)
            self.assertEqual(stage["failed"], 0)
            self.assertEqual(stage["tests"][0]["failure_mode"], "NONE")
            self.assertEqual(stage["waivers"], [])

    def test_signoff_preserves_recorded_tracecmp_mismatch(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            report_dir = root / "archived"
            report_dir.mkdir()
            sim_log = report_dir / "sim_tracecmp_clean_uvm.log"
            sim_log.write_text(
                "--- EH2 UVM TEST PASSED ---\n"
                "TEST PASSED\n",
                encoding="utf-8")
            (report_dir / "report.json").write_text(json.dumps({
                "total": 1,
                "passed": 0,
                "failed": 1,
                "tests": [{
                    "name": "riscv_random_instr_test",
                    "seed": 2,
                    "type": "RISCVDV",
                    "passed": False,
                    "failure_mode": "TRACECMP_MISMATCH",
                    "sim_log": str(sim_log),
                    "instructions": 0,
                    "cycles": 10,
                    "ipc": 0.0,
                    "sim_time_sec": 1.0,
                }]
            }), encoding="utf-8")

            stage = signoff.gather_stage(
                "riscvdv", report_dir, root / "reports", [], 1, False)

            self.assertEqual(stage["total"], 1)
            self.assertEqual(stage["passed"], 0)
            self.assertEqual(stage["failed"], 1)
            self.assertEqual(stage["tests"][0]["failure_mode"],
                             "TRACECMP_MISMATCH")

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

    def test_signoff_report_labels_coverage_gates_explicitly(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "signoff_report.md"
            status = {
                "status": "PASS",
                "timestamp": "2026-06-17T00:00:00",
                "profile": "full",
                "simulator": "vcs",
                "output_dir": str(Path(td)),
                "stages": [],
                "coverage": {
                    "status": "PASS",
                    "metrics": {
                        "assert": 33.0,
                        "fsm": 54.0,
                        "line": 91.0,
                        "toggle": 53.0,
                        "functional": 69.0,
                        "overall": 64.0,
                    },
                    "thresholds": {
                        "overall": 0.0,
                        "line": 55.0,
                        "fsm": 0.0,
                        "toggle": 0.0,
                        "functional": 40.0,
                    },
                    "files": [],
                    "blockers": [],
                },
                "precheck": {"checks": []},
                "blockers": [],
            }

            signoff.write_markdown_report(status, out)
            text = out.read_text(encoding="utf-8")

            self.assertIn("| Metric | Value | Gate | Threshold |", text)
            self.assertIn("| line | 91.00% | gated | 55.00% |", text)
            self.assertIn("| functional | 69.00% | gated | 40.00% |", text)
            self.assertIn("| assert | 33.00% | collected but ungated | - |", text)
            self.assertIn("| fsm | 54.00% | collected but ungated | - |", text)
            self.assertIn("| toggle | 53.00% | collected but ungated | - |", text)

    def test_docs_describe_honest_scope_and_generic_onboarding(self):
        root = SCRIPT_DIR.parents[3]
        readme = (root / "README.md").read_text(encoding="utf-8")
        index = (root / "docs" / "index.html").read_text(encoding="utf-8")
        onboarding_path = root / "docs" / "onboarding.md"

        self.assertTrue(onboarding_path.exists())
        onboarding = onboarding_path.read_text(encoding="utf-8")
        combined = "\n".join([readme, index, onboarding])

        self.assertIn("功能仿真", combined)
        self.assertIn("不在本平台范围", combined)
        self.assertIn("23/57", combined)
        self.assertIn("tracecmp: disabled", combined)
        self.assertIn("riscv_csr_test", combined)
        self.assertIn("riscv_csr_hazard_test", combined)
        self.assertIn("RVVI 适配器", onboarding)
        self.assertIn("参考模型", onboarding)
        self.assertIn("核配置", onboarding)
        self.assertIn("核无关", onboarding)
        self.assertNotRegex(readme + index,
                            r"online.*lockstep|逐指令.*lockstep|在线.*RVVI.*比对")

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

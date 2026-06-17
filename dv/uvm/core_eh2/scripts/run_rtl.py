#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# EH2 RTL Simulation Runner
#
# Constructs and runs VCS/Xcelium/Questa simulations for EH2.
# Reads rtl_simulation.yaml for simulator-specific commands.

import argparse
import os
import re
import sys
import yaml
import subprocess
from pathlib import Path
from metadata import RegressionMetadata, TestRunResult
from check_logs import check_sim_log
from test_entry import read_test_dot_seed
import directed_test_schema


SCRIPT_DIR = Path(__file__).resolve().parent
DV_DIR = SCRIPT_DIR.parent
EH2_ROOT = DV_DIR.parents[2]
PRE_SIM_FAILURE_MODES = {
    "GEN_ERROR",
    "GEN_TIMEOUT",
    "GEN_NO_ASM",
    "COMPILE_ERROR",
    "COMPILE_TIMEOUT",
    "DIRECTED_ASM_MISSING",
    "BINARY_MISSING",
}


def load_sim_config(config_path: str) -> dict:
    """Load simulator configuration from YAML."""
    with open(config_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def substitute_vars(cmd: str, variables: dict) -> str:
    """Substitute <var> placeholders in command string."""
    for key, value in variables.items():
        cmd = cmd.replace(f"<{key}>", str(value))
    return cmd


def build_compile_cmd(md: RegressionMetadata, sim_cfg: dict) -> str:
    """Build the compilation command."""
    del sim_cfg
    return "make -C {} compile SIMULATOR={} WAVES={} COV={}".format(
        md.eh2_root, md.simulator, int(md.waves), int(md.coverage))


def build_sim_cmd(md: RegressionMetadata, sim_cfg: dict) -> str:
    """Build the simulation command."""
    cfg = sim_cfg.get(md.simulator, sim_cfg.get("vcs", {}))
    sim_cfg_inner = cfg.get("sim", {})
    sim_opts = md.sim_opts or ""
    sim_timeout_ns = _plusarg_int(sim_opts, "timeout_ns")

    variables = {
        "build_dir": md.build_dir,
        "out_dir": md.out_dir,
        "tb_dir": str(DV_DIR),
        "eh2_root": md.eh2_root or str(EH2_ROOT),
        "test": md.test_name,
        "seed": md.seed,
        "binary": md.binary_path,
        "rtl_test": md.rtl_test or "core_eh2_base_test",
        "sim_opts": sim_opts,
        "timeout": (sim_timeout_ns if sim_timeout_ns is not None else
                    (md.sim_time_ns if md.sim_time_ns > 0 else 10000000)),
        "uvm_verbosity": "UVM_MEDIUM",
        "nc_uvm_home": os.environ.get(
            "NC_UVM_HOME",
            os.path.join(
                os.environ.get("NC_INSTALL", ""),
                "tools/methodology/UVM/CDNS-1.2")),
    }

    cmd = sim_cfg_inner.get("cmd", "")
    if not cmd:
        raise ValueError(
            f"No simulation command configured for simulator '{md.simulator}'")
    if md.coverage:
        cmd += " " + sim_cfg_inner.get("cov_opts", "")
    if md.waves:
        cmd += " " + sim_cfg_inner.get("wave_opts", "")

    cmd = substitute_vars(cmd, variables)
    # Normalize whitespace: collapse newlines and multiple spaces from YAML
    # multi-line values (sim_opts, cov_opts) that would otherwise break
    # shell command parsing (shell=True).
    cmd = " ".join(cmd.split())
    return cmd


def _plusarg_int(text: str, name: str):
    match = re.search(r"(?:^|\s)\+{}=(0x[0-9a-fA-F]+|\d+)(?:\s|$)".
                      format(re.escape(name)), text or "")
    if not match:
        return None
    try:
        return int(match.group(1), 0)
    except ValueError:
        return None


def sim_process_timeout_s(sim_opts: str, requested_timeout_s: int = 0) -> int:
    if requested_timeout_s:
        return requested_timeout_s
    cycles = _plusarg_int(sim_opts, "max_cycles")
    if not cycles:
        return 600
    return max(600, int(cycles / 500) + 300)


def run_command(cmd: str, log_path: str, timeout: int = 3600,
                env: dict = None) -> int:
    """Run a command and capture output."""
    print(f"Running: {cmd}")
    print(f"Log: {log_path}")

    os.makedirs(os.path.dirname(log_path), exist_ok=True)

    with open(log_path, "w") as log_f:
        try:
            result = subprocess.run(
                cmd, shell=True, stdout=log_f, stderr=subprocess.STDOUT,
                timeout=timeout, env=env,
            )
            return result.returncode
        except subprocess.TimeoutExpired:
            log_f.write("\n\nERROR: Command timed out\n")
            return -1


def run_rtl_simulation(md: RegressionMetadata) -> TestRunResult:
    """Run a single RTL simulation."""
    if not md.eh2_root:
        md.eh2_root = str(EH2_ROOT)
    if not md.build_dir:
        md.build_dir = os.path.join(md.eh2_root, "build", "compile")
    if not md.out_dir:
        md.out_dir = os.path.join(md.eh2_root, "build", f"{md.test_name}_{md.seed}")

    trr = TestRunResult()
    trr.test_name = md.test_name
    trr.seed = md.seed
    trr.test_type = md.test_type

    # Load simulator config
    sim_cfg_path = os.path.join(md.eh2_root, "dv", "uvm", "core_eh2", "yaml", "rtl_simulation.yaml")
    if os.path.exists(sim_cfg_path):
        sim_cfg = load_sim_config(sim_cfg_path) or {}
    else:
        trr.failure_mode = "CONFIG_ERROR"
        trr.sim_log_path = os.path.join(
            md.out_dir, f"sim_{md.test_name}_{md.seed}.log")
        os.makedirs(md.out_dir, exist_ok=True)
        with open(trr.sim_log_path, "w") as log_f:
            log_f.write(f"ERROR: simulator config not found: {sim_cfg_path}\n")
        return trr

    # Set output paths
    os.makedirs(md.out_dir, exist_ok=True)
    trr.sim_log_path = os.path.join(md.out_dir, f"sim_{md.test_name}_{md.seed}.log")
    trr.uvm_log_path = os.path.join(md.out_dir, f"{md.test_name}_{md.seed}_uvm.log")
    trr.trace_path = os.path.join(md.out_dir, "trace_core")

    # Compile
    sim_exe = os.path.join(md.build_dir, "simv")
    # For VCS the simv binary is the readiness signal; for NC the equivalent
    # signal is the elaborated INCA_libs directory left by `make compile_nc`.
    # When the readiness signal is absent we invoke `make compile` for the
    # corresponding simulator so each test can run standalone.
    if md.simulator == "vcs" and not os.path.exists(sim_exe):
        compile_cmd = build_compile_cmd(md, sim_cfg)
        trr.compile_cmd = compile_cmd
        compile_log = os.path.join(md.out_dir, "compile.log")
        rc = run_command(compile_cmd, compile_log)
        if rc != 0:
            trr.failure_mode = "COMPILE_ERROR"
            return trr
    elif md.simulator == "nc" and not os.path.isdir(
            os.path.join(md.build_dir, "INCA_libs")):
        compile_cmd = build_compile_cmd(md, sim_cfg)
        trr.compile_cmd = compile_cmd
        compile_log = os.path.join(md.out_dir, "compile.log")
        rc = run_command(compile_cmd, compile_log)
        if rc != 0:
            trr.failure_mode = "COMPILE_ERROR"
            return trr

    # Simulate
    try:
        sim_cmd = build_sim_cmd(md, sim_cfg)
    except ValueError as err:
        trr.failure_mode = "CONFIG_ERROR"
        with open(trr.sim_log_path, "w") as log_f:
            log_f.write(f"ERROR: {err}\n")
        return trr
    trr.sim_cmd = sim_cmd
    sim_env = {**os.environ, "SIM_DIR": md.out_dir}
    rc = run_command(
        sim_cmd, trr.sim_log_path,
        timeout=sim_process_timeout_s(
            md.sim_opts, getattr(md, "process_timeout_s", 0)),
        env=sim_env)
    trr.sim_returncode = rc

    # Parse results. A zero simulator return code is not sufficient for pass:
    # the test must emit an explicit mailbox/signature pass marker.
    checked = check_sim_log(trr.sim_log_path, trr.trace_path,
                            sim_returncode=rc)
    trr.passed = checked.passed
    trr.failure_mode = checked.failure_mode
    trr.num_instructions = checked.num_instructions
    trr.num_cycles = checked.num_cycles
    trr.ipc = checked.ipc
    trr.uvm_errors = checked.uvm_errors
    trr.uvm_warnings = checked.uvm_warnings

    return trr


def _append_opt(pieces: list, value: str):
    value = str(value or "").replace("\n", " ").strip()
    if value:
        pieces.append(value)


def _merge_sim_opts(test_entry: dict, global_sim_opts: str) -> str:
    pieces = []
    _append_opt(pieces, test_entry.get("sim_opts", ""))
    _append_opt(pieces, global_sim_opts)

    return " ".join(piece for piece in pieces if piece).strip()


def add_rvvi_elf_sim_opt(sim_opts: str, binary: Path) -> str:
    sim_opts = (sim_opts or "").strip()
    if "+rvvi_elf=" in sim_opts:
        return sim_opts
    root, ext = os.path.splitext(str(binary))
    elf_path = root + ".elf" if ext in (".hex", ".bin") else str(binary) + ".elf"
    return " ".join(piece for piece in (sim_opts, "+rvvi_elf={}".format(elf_path))
                    if piece)


def add_rvvi_trace_dump_sim_opts(sim_opts: str, trace_path: Path) -> str:
    sim_opts = (sim_opts or "").strip()
    pieces = [sim_opts]
    if "+rvvi_trace_dump" not in sim_opts:
        pieces.append("+rvvi_trace_dump")
    if "+rvvi_trace_file=" not in sim_opts:
        pieces.append("+rvvi_trace_file={}".format(trace_path))
    return " ".join(piece for piece in pieces if piece)


def needs_rvvi_trace_defaults(sim_opts: str) -> bool:
    return any(token in (sim_opts or "")
               for token in ("+rvvi_elf=", "+rvvi_trace_dump"))


def _directed_test_entry(md: RegressionMetadata, test_name: str) -> dict:
    for candidate in [md.directed_test_data,
                      getattr(md, "cosim_test_data", "")]:
        if not candidate:
            continue
        testlist_path = Path(candidate)
        if not testlist_path.exists():
            continue

        model = directed_test_schema.import_model(testlist_path)
        for test in model.tests:
            if test.test == test_name:
                return {
                    "test": test.test,
                    "rtl_test": test.rtl_test,
                    "sim_opts": "",
                    "test_type": "DIRECTED",
                    "cosim": "enabled",
                }
    return {}


def _riscvdv_test_entry(md: RegressionMetadata, test_name: str) -> dict:
    if not md.eh2_riscvdv_testlist:
        return {}
    testlist_path = Path(md.eh2_riscvdv_testlist)
    if not testlist_path.exists():
        return {}

    with open(testlist_path, "r", encoding="utf-8") as f:
        entries = yaml.safe_load(f) or []
    for entry in entries:
        if isinstance(entry, dict) and entry.get("test") == test_name:
            merged = dict(entry)
            merged.setdefault("test_type", "RISCVDV")
            return merged
    return {}


def metadata_test_entry(md: RegressionMetadata, test_name: str) -> dict:
    return (_directed_test_entry(md, test_name) or
            _riscvdv_test_entry(md, test_name) or
            {"test": test_name})


def load_recorded_result(test_dir: Path, test_name: str, seed: int):
    bases = [test_dir / "{}_{}".format(test_name, seed), test_dir / "result"]
    for base in bases:
        if not Path(str(base) + ".pkl").exists():
            continue
        try:
            return TestRunResult.load(str(base))
        except Exception:
            continue
    return None


def missing_binary_result(md_all: RegressionMetadata, test_entry: dict,
                          test_name: str, seed: int, test_dir: Path,
                          binary: Path) -> TestRunResult:
    recorded = load_recorded_result(test_dir, test_name, seed)
    recorded_log_path = getattr(recorded, "sim_log_path", "") \
        if recorded is not None else ""
    trr = recorded or TestRunResult()
    trr.test_name = test_name
    trr.seed = seed
    trr.test_type = test_entry.get("test_type", "RISCVDV")
    trr.passed = False
    if trr.failure_mode not in PRE_SIM_FAILURE_MODES:
        trr.failure_mode = "BINARY_MISSING"
    trr.binary_path = str(binary)
    trr.sim_log_path = str(test_dir / "sim_{}_{}.log".format(test_name, seed))

    log_path = Path(trr.sim_log_path)
    if not log_path.exists():
        details = ""
        if recorded_log_path and Path(recorded_log_path).exists():
            details = Path(recorded_log_path).read_text(
                encoding="utf-8", errors="replace")
        log_path.write_text(
            "ERROR: RTL simulation skipped because test binary is missing: "
            "{}\nFailure mode: {}\n{}\n".format(
                binary, trr.failure_mode, details),
            encoding="utf-8")
    return trr


def run_from_metadata(dir_metadata: str, test_dot_seed: str) -> TestRunResult:
    """Run one RTL simulation using Ibex-style metadata."""
    md_all = RegressionMetadata.construct_from_metadata_dir(Path(dir_metadata))
    test_name, seed = read_test_dot_seed(test_dot_seed)
    test_dir = Path(md_all.dir_tests) / test_dot_seed
    binary = test_dir / "test.hex"
    if not binary.exists():
        binary = test_dir / "test.bin"

    md = RegressionMetadata()
    md.test_name = test_name
    md.seed = seed
    md.binary_path = str(binary)
    md.simulator = md_all.simulator
    md.eh2_config = md_all.eh2_config
    md.waves = md_all.waves
    md.coverage = md_all.coverage
    md.sim_time_ns = md_all.sim_time_ns
    test_entry = metadata_test_entry(md_all, test_name)
    if not binary.exists():
        return missing_binary_result(md_all, test_entry, test_name, seed,
                                     test_dir, binary)

    md.test_type = test_entry.get("test_type", "RISCVDV")
    md.rtl_test = test_entry.get("rtl_test") or md_all.rtl_test or \
        "core_eh2_base_test"
    md.sim_opts = add_rvvi_elf_sim_opt(
        _merge_sim_opts(test_entry, md_all.sim_opts), binary)
    md.sim_opts = add_rvvi_trace_dump_sim_opts(
        md.sim_opts, test_dir / "rvvi_trace.log")
    md.eh2_root = md_all.eh2_root
    md.build_dir = str(Path(md_all.eh2_root) / "build")
    md.out_dir = str(test_dir)
    return run_rtl_simulation(md)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="EH2 RTL Simulation Runner")
    parser.add_argument("--test", default="", help="Test name")
    parser.add_argument("--seed", type=int, default=1, help="Random seed")
    parser.add_argument("--binary", default="", help="Test binary path")
    parser.add_argument("--simulator", default="vcs", choices=["vcs", "nc", "xlm", "questa"])
    parser.add_argument("--config", default="default", help="EH2 configuration")
    parser.add_argument("--waves", action="store_true", help="Enable waveform dump")
    parser.add_argument("--coverage", action="store_true", help="Enable coverage")
    parser.add_argument("--timeout", type=int, default=10000000, help="Sim timeout (ns)")
    parser.add_argument("--rtl-test", default="core_eh2_base_test", help="UVM test class")
    parser.add_argument("--sim-opts", default="", help="Simulation plusargs")
    parser.add_argument("--build-dir", default="", help="Build directory")
    parser.add_argument("--out-dir", default="", help="Output directory")
    parser.add_argument("--process-timeout-s", type=int, default=0,
                        help="Wall-clock timeout for simulator process")
    parser.add_argument("--dir-metadata", default="",
                        help="Ibex-style metadata directory")
    parser.add_argument("--test-dot-seed", default="",
                        help="Ibex-style TEST.SEED selector")

    args = parser.parse_args(argv)

    if args.dir_metadata:
        if not args.test_dot_seed:
            parser.error("--test-dot-seed is required with --dir-metadata")
        trr = run_from_metadata(args.dir_metadata, args.test_dot_seed)
        result_path = os.path.join(
            os.path.dirname(trr.sim_log_path),
            f"{trr.test_name}_{trr.seed}")
        trr.save(result_path)
        print(f"\nTest: {trr.test_name} | Seed: {trr.seed} | "
              f"{'PASSED' if trr.passed else 'FAILED'}")
        if trr.failure_mode and trr.failure_mode != "NONE":
            print(f"Failure mode: {trr.failure_mode}")
        # Keep Ibex-style Make regressions moving. The following check_logs
        # stage re-reads the log and writes the final result/trr files, and
        # collect_results must see every test rather than only the first fail.
        return 0

    if not args.test:
        parser.error("--test is required without --dir-metadata")

    md = RegressionMetadata()
    md.test_name = args.test
    md.seed = args.seed
    md.binary_path = args.binary
    md.simulator = args.simulator
    md.eh2_config = args.config
    md.waves = args.waves
    md.coverage = args.coverage
    md.sim_time_ns = args.timeout
    md.process_timeout_s = args.process_timeout_s
    md.rtl_test = args.rtl_test
    if args.build_dir:
        md.build_dir = args.build_dir
    if args.out_dir:
        md.out_dir = args.out_dir
    trace_dir = Path(md.out_dir) if md.out_dir else \
        Path(md.eh2_root or str(EH2_ROOT)) / "build" / \
        "{}_{}".format(md.test_name, md.seed)
    md.sim_opts = args.sim_opts
    if needs_rvvi_trace_defaults(md.sim_opts):
        md.sim_opts = add_rvvi_trace_dump_sim_opts(
            md.sim_opts, trace_dir / "rvvi_trace.log")

    trr = run_rtl_simulation(md)

    # Save results
    result_path = os.path.join(md.out_dir, f"{md.test_name}_{md.seed}")
    trr.save(result_path)

    print(f"\nTest: {trr.test_name} | Seed: {trr.seed} | {'PASSED' if trr.passed else 'FAILED'}")
    if trr.failure_mode and trr.failure_mode != "NONE":
        print(f"Failure mode: {trr.failure_mode}")

    return 0 if trr.passed else 1


if __name__ == "__main__":
    sys.exit(main())

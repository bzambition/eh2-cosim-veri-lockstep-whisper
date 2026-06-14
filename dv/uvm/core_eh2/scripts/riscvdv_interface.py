#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 riscv-dv Interface

Provides helper functions for interfacing with the riscv-dv framework:
  - get_run_cmd(): Build riscv-dv run.py command
  - get_cov_cmd(): Build riscv-dv coverage collection command
  - get_tool_cmds(): Parse rtl_simulation.yaml and produce final commands
"""

import os
import sys
import yaml


EH2_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
RISCV_DV_DIR = os.path.join(EH2_ROOT, "vendor", "google_riscv-dv")
DV_DIR = os.path.join(EH2_ROOT, "dv", "uvm", "core_eh2")
EXT_DIR = os.path.join(DV_DIR, "riscv_dv_extension")


def get_run_cmd(test: str, seed: int, iterations: int = 1,
                gen_opts: str = "", isa: str = "rv32imac",
                mabi: str = "ilp32", output_dir: str = "") -> list:
    """
    Build command to run riscv-dv instruction generator.

    Args:
        test: Test name from testlist.yaml
        seed: Random seed
        iterations: Number of iterations
        gen_opts: Additional generator plusargs
        isa: ISA string
        mabi: ABI string
        output_dir: Output directory

    Returns:
        Command as list of strings
    """
    run_py = os.path.join(RISCV_DV_DIR, "run.py")

    cmd = [
        sys.executable, run_py,
        "--test", test,
        "--target", "rv32imc",
        "--seed", str(seed),
        "--iterations", str(iterations),
        "--steps", "gen",
        "--isa", isa,
        "--mabi", mabi,
    ]

    # Add custom extension directory
    if os.path.exists(os.path.join(EXT_DIR, "user_extension.svh")):
        cmd.extend(["--custom_target", EXT_DIR])

    # Add testlist
    testlist = os.path.join(EXT_DIR, "testlist.yaml")
    if os.path.exists(testlist):
        cmd.extend(["--testlist", testlist])

    # Add CSR description
    csr_yaml = os.path.join(EXT_DIR, "csr_description.yaml")
    if os.path.exists(csr_yaml):
        cmd.extend(["--csr_yaml", csr_yaml])

    if output_dir:
        cmd.extend(["-o", output_dir])

    if gen_opts:
        cmd.extend(gen_opts.split())

    return cmd


def get_cov_cmd(trace_csv: str, isa: str = "rv32imac",
                output_dir: str = "") -> list:
    """
    Build command to collect riscv-dv functional coverage.

    Args:
        trace_csv: Path to trace CSV file
        isa: ISA string
        output_dir: Coverage output directory

    Returns:
        Command as list of strings
    """
    cov_py = os.path.join(RISCV_DV_DIR, "cov.py")

    cmd = [
        sys.executable, cov_py,
        "--trace_csv", trace_csv,
        "--isa", isa,
        "--target", "rv32imc",
    ]

    if output_dir:
        cmd.extend(["-o", output_dir])

    return cmd


def get_tool_cmds(yaml_path: str, variables: dict = None) -> dict:
    """
    Parse rtl_simulation.yaml and produce final commands with variable substitution.

    Args:
        yaml_path: Path to rtl_simulation.yaml
        variables: Dict of variable substitutions

    Returns:
        Dict with 'compile' and 'sim' command strings
    """
    with open(yaml_path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    if variables is None:
        variables = {}

    result = {}

    for simulator, sim_cfg in cfg.items():
        result[simulator] = {}

        for stage in ["compile", "sim"]:
            if stage not in sim_cfg:
                continue

            cmd = sim_cfg[stage].get("cmd", "")

            # Substitute variables
            for key, value in variables.items():
                cmd = cmd.replace(f"<{key}>", str(value))

            result[simulator][stage] = cmd.strip()

    return result


def get_default_variables(eh2_root: str = "", build_dir: str = "",
                          test: str = "", seed: int = 1,
                          binary: str = "", rtl_test: str = "") -> dict:
    """Get default variable substitutions."""
    if not eh2_root:
        eh2_root = EH2_ROOT

    return {
        "tb_dir": os.path.join(eh2_root, "dv", "uvm", "core_eh2"),
        "build_dir": build_dir or os.path.join(eh2_root, "build"),
        "seed": seed,
        "binary": binary,
        "rtl_test": rtl_test or "core_eh2_base_test",
        "sim_opts": "",
        "cov_opts": "",
        "wave_opts": "",
        "out_dir": build_dir or os.path.join(eh2_root, "build"),
        "timeout": 10000000,
    }

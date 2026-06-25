#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 riscv-dv Instruction Generator Runner

Runs riscv-dv to generate random assembly programs for EH2 testing.
Generates assembly files that are later compiled and loaded into the RTL simulation.
"""

import argparse
import os
import sys
import subprocess
import shutil
import yaml
from pathlib import Path
from metadata import RegressionMetadata
from test_entry import read_test_dot_seed
import render_config_template


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DV_DIR = os.path.dirname(SCRIPT_DIR)
EXT_DIR = os.path.join(DV_DIR, "riscv_dv_extension")
DEFAULT_TESTLIST = os.path.join(EXT_DIR, "testlist.yaml")
EH2_SIGNATURE_ADDR = "d0580000"


def build_sim_opts(test_name: str = "") -> str:
    """Build riscv-dv generator simulator plusargs for EH2 customizations."""
    asm_gen = "eh2_asm_program_gen"
    if test_name == "riscv_debug_triggers_test":
        asm_gen = "eh2_hardware_triggers_asm_program_gen"

    return " ".join([
        "+uvm_set_inst_override=riscv_asm_program_gen,"
        f"{asm_gen},uvm_test_top.asm_gen",
        "+require_signature_addr=1",
        f"+signature_addr={EH2_SIGNATURE_ADDR}",
        "+fix_sp=1",
    ])


def load_test_entry(testlist_path: str, test_name: str) -> dict:
    """Load one EH2 test entry for riscv-dv."""
    with open(testlist_path, "r", encoding="utf-8") as f:
        entries = yaml.safe_load(f)

    for entry in entries:
        if entry.get("test") == test_name:
            return dict(entry)

    raise KeyError(f"Test {test_name} not found in {testlist_path}")


def write_overlay_testlist(work_dir: str, test_name: str,
                           extra_gen_opts: str = "") -> str:
    """Create a per-run testlist that carries CLI generator plusargs."""
    entry = load_test_entry(DEFAULT_TESTLIST, test_name)
    entry["iterations"] = 1

    # Folded scalars (>) load with a trailing newline; strip it so the dumped
    # YAML does not spill into a quoted multi-line scalar that riscv-dv's
    # parser interprets as the value-plus-continuation.
    base_opts = str(entry.get("gen_opts", "") or "").strip()
    extra_gen_opts = (extra_gen_opts or "").strip()
    entry["gen_opts"] = " ".join(
        opt for opt in [base_opts, extra_gen_opts] if opt
    )

    overlay_path = os.path.join(work_dir, "riscv_dv_testlist.yaml")
    with open(overlay_path, "w") as f:
        yaml.safe_dump([entry], f, default_flow_style=False, sort_keys=False)
    return overlay_path


def prepare_custom_target(work_dir: str, config: str = "default") -> str:
    """Create a per-run EH2 custom target rendered for the selected config."""
    custom_target = os.path.join(work_dir, "riscv_dv_custom_target")
    if os.path.exists(custom_target):
        shutil.rmtree(custom_target)
    shutil.copytree(EXT_DIR, custom_target)

    template = os.path.join(EXT_DIR, "riscv_core_setting.tpl.sv")
    if os.path.exists(template):
        rendered = render_config_template.render_template(config, template)
        setting = os.path.join(custom_target, "riscv_core_setting.sv")
        with open(setting, "w", encoding="utf-8") as f:
            f.write(rendered)

    return custom_target


def run_instr_gen(riscv_dv_dir: str, work_dir: str, test_name: str,
                  gen_opts: str, seed: int, iterations: int = 1,
                  config: str = "default") -> bool:
    """
    Run riscv-dv instruction generator.

    Args:
        riscv_dv_dir: Path to riscv-dv directory
        work_dir: Working directory for outputs
        test_name: Name of the test to generate
        gen_opts: Generator options (plusargs)
        seed: Random seed
        iterations: Number of iterations

    Returns:
        True if successful
    """
    riscv_dv_dir = os.path.abspath(riscv_dv_dir)
    work_dir = os.path.abspath(work_dir)
    os.makedirs(work_dir, exist_ok=True)

    # riscv-dv run.py command
    riscv_dv_run = os.path.join(riscv_dv_dir, "run.py")
    if not os.path.exists(riscv_dv_run):
        print(f"Error: riscv-dv run.py not found at {riscv_dv_run}")
        return False

    testlist_path = write_overlay_testlist(work_dir, test_name, gen_opts)

    cmd = [
        sys.executable, riscv_dv_run,
        "--test", test_name,
        "--target", "rv32imc",
        "-o", work_dir,
        "--steps", "gen",
        "--seed", str(seed),
        "--iterations", str(iterations),
        "--isa", "rv32imac",
        "--mabi", "ilp32",
        "--testlist", testlist_path,
        "--sim_opts", build_sim_opts(test_name),
    ]

    # Add custom extension
    if os.path.exists(os.path.join(EXT_DIR, "user_extension.svh")):
        cmd.extend(["--custom_target",
                    prepare_custom_target(work_dir, config)])

    print(f"Running instruction generator: {' '.join(cmd)}")

    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=600,
            cwd=work_dir
        )

        output = result.stdout.decode("utf-8", errors="replace")
        log_path = os.path.join(work_dir, f"{test_name}_gen.log")
        with open(log_path, "w") as f:
            f.write(output)

        if result.returncode != 0:
            print(f"Instruction generator failed (rc={result.returncode})")
            print(f"See log: {log_path}")
            return False

        print(f"Generated assembly in {work_dir}")
        return True

    except subprocess.TimeoutExpired:
        print("Instruction generator timed out (600s)")
        return False
    except Exception as e:
        print(f"Instruction generator error: {e}")
        return False


def run_from_metadata(dir_metadata: str, test_dot_seed: str) -> bool:
    """Run generator using Ibex-style metadata and TEST.SEED selector."""
    md = RegressionMetadata.construct_from_metadata_dir(Path(dir_metadata))
    test_name, seed = read_test_dot_seed(test_dot_seed)
    work_dir = Path(md.dir_tests) / test_dot_seed
    work_dir.mkdir(parents=True, exist_ok=True)

    # Pass only the metadata-supplied extra gen_opts. write_overlay_testlist
    # itself reads the testlist's own gen_opts; duplicating them here would
    # produce a YAML scalar with the value concatenated twice.
    extra_gen_opts = md.gen_opts or ""

    args = [
        str(Path(md.eh2_root) / "vendor" / "google_riscv-dv"),
        str(work_dir), test_name, extra_gen_opts, seed, 1,
    ]
    if md.eh2_config != "default":
        return run_instr_gen(*args, config=md.eh2_config)
    return run_instr_gen(*args)


def main():
    parser = argparse.ArgumentParser(description="Run riscv-dv instruction generator")
    parser.add_argument("--riscv-dv-dir", default="", help="riscv-dv directory")
    parser.add_argument("--work-dir", default="", help="Working directory")
    parser.add_argument("--test", default="", help="Test name")
    parser.add_argument("--gen-opts", default="", help="Generator options")
    parser.add_argument("--config", default="default",
                        help="EH2 configuration")
    parser.add_argument("--seed", type=int, default=1, help="Random seed")
    parser.add_argument("--iterations", type=int, default=1, help="Iterations")
    parser.add_argument("--dir-metadata", default="",
                        help="Ibex-style metadata directory")
    parser.add_argument("--test-dot-seed", default="",
                        help="Ibex-style TEST.SEED selector")
    args = parser.parse_args()

    if args.dir_metadata:
        if not args.test_dot_seed:
            parser.error("--test-dot-seed is required with --dir-metadata")
        success = run_from_metadata(args.dir_metadata, args.test_dot_seed)
        sys.exit(0 if success else 1)

    for required_arg, value in {
        "--riscv-dv-dir": args.riscv_dv_dir,
        "--work-dir": args.work_dir,
        "--test": args.test,
    }.items():
        if not value:
            parser.error(f"{required_arg} is required without --dir-metadata")

    success = run_instr_gen(
        args.riscv_dv_dir, args.work_dir, args.test,
        args.gen_opts, args.seed, args.iterations, args.config
    )
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()

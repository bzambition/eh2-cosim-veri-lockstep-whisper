#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 Regression Metadata

Defines data classes for tracking regression configuration and test results.
Used by all regression scripts for consistent configuration management.
"""

import os
import argparse
import shlex
import yaml
import pickle
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Optional, Dict, Tuple
from datetime import datetime


@dataclass
class RegressionMetadata:
    """Central configuration for a regression run."""

    # Test configuration
    test_name: str = ""
    test_type: str = "RISCVDV"
    seed: int = 0
    iterations: Optional[int] = 1
    binary_path: str = ""
    rtl_test: str = "core_eh2_base_test"
    signature_addr: str = "d0580000"

    # Simulator configuration
    simulator: str = "vcs"  # vcs, xlm, questa
    sim_opts: str = ""
    gen_opts: str = ""
    sim_time_ns: int = 10000000
    waves: bool = False
    coverage: bool = False
    verbose: bool = False
    iss: str = "spike"

    # EH2 configuration
    eh2_config: str = "default"  # default, fast, secure
    eh2_root: str = ""

    # Directories
    work_dir: str = ""
    build_dir: str = ""
    out_dir: str = ""
    log_dir: str = ""
    binary_dir: str = ""
    coverage_dir: str = ""
    dir_out: str = ""
    dir_metadata: str = ""
    dir_build: str = ""
    dir_run: str = ""
    dir_tests: str = ""
    dir_tb: str = ""
    dir_instruction_generator: str = ""
    dir_cov: str = ""
    dir_fcov: str = ""
    dir_shared_cov: str = ""
    dir_cov_merged: str = ""
    dir_cov_report: str = ""

    # Test matrix exported for Ibex-style wrapper.mk dependencies.
    tests_and_counts: List[Tuple[str, int, str]] = field(default_factory=list)
    riscvdv_tds: List[str] = field(default_factory=list)
    directed_tds: List[str] = field(default_factory=list)
    tests_pickle_files: List[str] = field(default_factory=list)

    # Canonical input files.
    eh2_configs: str = ""
    eh2_riscvdv_testlist: str = ""
    eh2_riscvdv_customtarget: str = ""
    directed_test_dir: str = ""
    directed_test_data: str = ""
    cosim_test_data: str = ""

    # Build commands
    compile_cmd: str = ""
    sim_cmd: str = ""

    # Results
    passed: bool = False
    failure_mode: str = ""  # TIMEOUT, UVM_ERROR, MISMATCH, etc.

    # Timestamps
    start_time: str = ""
    end_time: str = ""

    def save(self, path: str):
        """Save metadata to YAML and pickle files."""
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(f"{path}.yaml", "w") as f:
            yaml.safe_dump(self.__dict__, f, default_flow_style=False)
        with open(f"{path}.pkl", "wb") as f:
            pickle.dump(self, f)

    @classmethod
    def load(cls, path: str) -> "RegressionMetadata":
        """Load metadata from pickle file."""
        with open(f"{path}.pkl", "rb") as f:
            return pickle.load(f)

    @classmethod
    def construct_from_metadata_dir(cls, metadata_dir) -> "RegressionMetadata":
        """Load metadata from a metadata directory (Path or str).

        Looks for metadata.pkl or metadata.yaml in the given directory.
        """
        metadata_dir = Path(metadata_dir)
        pkl_path = metadata_dir / "metadata.pkl"
        yaml_path = metadata_dir / "metadata.yaml"

        if pkl_path.exists():
            with open(pkl_path, "rb") as f:
                try:
                    return pickle.load(f)
                except (AttributeError, ModuleNotFoundError):
                    # Metadata written by `python scripts/metadata.py` in older
                    # revisions can pickle the class as __main__. Fall back to
                    # YAML, which is stable across entry points.
                    pass
        if yaml_path.exists():
            with open(yaml_path, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f)
            md = cls()
            for key, value in data.items():
                if hasattr(md, key):
                    setattr(md, key, value)
            return md
        else:
            raise FileNotFoundError(
                f"No metadata.pkl or metadata.yaml found in {metadata_dir}"
            )


@dataclass
class TestRunResult:
    """Result of a single test run."""

    test_name: str = ""
    seed: int = 0
    iteration: int = 0
    test_type: str = "RISCVDV"  # RISCVDV or DIRECTED

    # Paths
    assembly_path: str = ""
    binary_path: str = ""
    sim_log_path: str = ""
    uvm_log_path: str = ""
    trace_path: str = ""
    coverage_path: str = ""

    # Results
    passed: bool = False
    failure_mode: str = ""
    num_instructions: int = 0
    num_cycles: int = 0
    ipc: float = 0.0
    uvm_errors: int = 0
    uvm_warnings: int = 0
    sim_returncode: Optional[int] = None

    # Timing
    gen_time_sec: float = 0.0
    compile_time_sec: float = 0.0
    sim_time_sec: float = 0.0

    def save(self, path: str):
        """Save result to YAML and pickle."""
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(f"{path}.yaml", "w") as f:
            yaml.dump(self.__dict__, f, default_flow_style=False)
        with open(f"{path}.pkl", "wb") as f:
            pickle.dump(self, f)

    @classmethod
    def load(cls, path: str) -> "TestRunResult":
        """Load result from pickle."""
        with open(f"{path}.pkl", "rb") as f:
            return pickle.load(f)


@dataclass
class RegressionSummary:
    """Summary of an entire regression run."""

    total_tests: int = 0
    passed: int = 0
    failed: int = 0
    errors: int = 0

    total_time_sec: float = 0.0
    total_instructions: int = 0

    results: List[TestRunResult] = field(default_factory=list)

    def add_result(self, result: TestRunResult):
        self.results.append(result)
        self.total_tests += 1
        if result.passed:
            self.passed += 1
        else:
            self.failed += 1

    def to_junit_xml(self, path: str):
        """Generate JUnit XML report."""
        with open(path, "w") as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
            f.write(f'<testsuites tests="{self.total_tests}" '
                    f'failures="{self.failed}" '
                    f'time="{self.total_time_sec:.1f}">\n')
            f.write(f'  <testsuite name="eh2_regression" '
                    f'tests="{self.total_tests}" '
                    f'failures="{self.failed}">\n')

            for r in self.results:
                f.write(f'    <testcase name="{r.test_name}_s{r.seed}" '
                        f'time="{r.sim_time_sec:.1f}"')
                if r.passed:
                    f.write('/>\n')
                else:
                    f.write(f'>\n      <failure message="{r.failure_mode}"/>\n'
                            f'    </testcase>\n')

            f.write('  </testsuite>\n')
            f.write('</testsuites>\n')

    def to_log(self, path: str):
        """Generate text log report."""
        with open(path, "w") as f:
            f.write("=" * 78 + "\n")
            f.write("EH2 Regression Results\n")
            f.write(f"Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write("=" * 78 + "\n\n")
            f.write(f"Total:  {self.total_tests}\n")
            f.write(f"Passed: {self.passed}\n")
            f.write(f"Failed: {self.failed}\n")
            f.write(f"Pass rate: {100*self.passed/max(1,self.total_tests):.1f}%\n")
            f.write(f"Total time: {self.total_time_sec:.0f}s\n\n")

            if self.failed > 0:
                f.write("-" * 78 + "\n")
                f.write("FAILED TESTS:\n")
                f.write("-" * 78 + "\n")
                for r in self.results:
                    if not r.passed:
                        f.write(f"  {r.test_name} seed={r.seed}: {r.failure_mode}\n")
                f.write("\n")

            f.write("-" * 78 + "\n")
            f.write("ALL TESTS:\n")
            f.write("-" * 78 + "\n")
            for r in self.results:
                status = "PASS" if r.passed else "FAIL"
                f.write(f"  [{status}] {r.test_name} seed={r.seed} "
                        f"time={r.sim_time_sec:.0f}s\n")


def load_testlist(path: str) -> List[Dict]:
    """Load test list from YAML file."""
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def _str_to_bool(value) -> bool:
    """Convert an Ibex-style make argument value into bool."""
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def _parse_args_list(args_list: str) -> Dict[str, str]:
    """Parse Make-style KEY=VALUE tokens from metadata --args-list."""
    parsed = {}
    for token in shlex.split(str(args_list or "")):
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        parsed[key.strip()] = value.strip()
    return parsed


def _selected_tests_arg(test_arg: str) -> List[str]:
    return [item.strip() for item in str(test_arg or "all").split(",")
            if item.strip()]


def _entry_iterations(entry: Dict, override: Optional[int]) -> int:
    if override is not None:
        return override
    return int(entry.get("iterations", 1) or 1)


def _load_directed_entries(testlist_path: Path) -> List[Dict]:
    """Load directed schema without importing run_regress and creating cycles."""
    import directed_test_schema

    model = directed_test_schema.import_model(testlist_path)
    entries = []
    for test in model.tests:
        entry = {
            "test": test.test,
            "iterations": test.iterations,
            "rtl_test": test.rtl_test,
            "test_type": "DIRECTED",
            "asm": test.test_srcs,
            "linker": test.ld_script,
            "description": test.desc,
            "rtl_params": test.rtl_params,
        }
        entries.append(entry)
    return entries


def _select_test_entries(md: RegressionMetadata,
                         riscvdv_testlist: Path,
                         directed_testlists: List[Path]
                         ) -> List[Tuple[str, int, str]]:
    """Return (test, count, type) tuples for Ibex-style make dependencies."""
    selected = _selected_tests_arg(md.test_name)
    run_all = any(item in ("all", "all_riscvdv", "all_directed",
                           "all_cosim")
                  for item in selected)
    run_all_riscvdv = any(item in ("all", "all_riscvdv") for item in selected)
    run_all_directed = any(item in ("all", "all_directed") for item in selected)
    run_all_cosim = any(item in ("all", "all_cosim") for item in selected)
    override = md.iterations if md.iterations not in (None, 0) else None

    test_matrix = []
    riscvdv_entries = load_testlist(str(riscvdv_testlist)) or []
    for entry in riscvdv_entries:
        name = entry.get("test")
        if not name:
            continue
        if run_all_riscvdv or name in selected:
            count = _entry_iterations(entry, override)
            if count > 0:
                test_matrix.append((name, count, "RISCVDV"))

    for directed_testlist in directed_testlists:
        directed_entries = _load_directed_entries(directed_testlist)
        is_cosim_testlist = directed_testlist.name == "cosim_testlist.yaml"
        include_all = run_all_directed or (
            is_cosim_testlist and run_all_cosim)
        for entry in directed_entries:
            name = entry.get("test")
            if not name:
                continue
            if include_all or name in selected:
                count = _entry_iterations(entry, override)
                if count > 0:
                    test_matrix.append((name, count, "DIRECTED"))

    # Single-test wrapper invocations often use names like "smoke" that are
    # outside the full testlists. Preserve a runnable one-test metadata object
    # instead of failing metadata creation.
    if not test_matrix and not run_all:
        for name in selected:
            test_matrix.append((name, override or 1, "RISCVDV"))

    return test_matrix


def _tds_for_type(md: RegressionMetadata, test_type: str) -> List[str]:
    tds = []
    for test, count, entry_type in md.tests_and_counts:
        if entry_type != test_type:
            continue
        for seed in range(md.seed, md.seed + int(count)):
            tds.append(f"{test}.{seed}")
    return tds


def create_metadata(dir_metadata: str, dir_out: str,
                    args_list: str = "") -> RegressionMetadata:
    """Create a RegressionMetadata object using Ibex-style CLI arguments."""
    args = _parse_args_list(args_list)
    root = Path(__file__).resolve().parents[4]
    out_dir = Path(dir_out).resolve()
    metadata_dir = Path(dir_metadata).resolve()
    core_eh2 = root / "dv" / "uvm" / "core_eh2"
    run_dir = out_dir / "run"
    tests_dir = run_dir / "tests"
    cov_dir = run_dir / "coverage"

    md = RegressionMetadata()
    md.seed = int(args.get("SEED", 1) or 1)
    md.test_name = args.get("TEST", "all") or "all"
    md.simulator = args.get("SIMULATOR", "vcs") or "vcs"
    md.iterations = (int(args["ITERATIONS"])
                     if args.get("ITERATIONS", "") not in ("", None)
                     else None)
    md.waves = _str_to_bool(args.get("WAVES", "0"))
    md.coverage = _str_to_bool(args.get("COV", "0"))
    md.verbose = _str_to_bool(args.get("VERBOSE", "0"))
    md.iss = args.get("ISS", "spike") or "spike"
    md.signature_addr = args.get("SIGNATURE_ADDR", md.signature_addr)
    md.eh2_config = args.get("CONFIG", args.get("EH2_CONFIG", "default"))
    md.eh2_root = str(root)
    md.work_dir = str(out_dir)
    md.build_dir = str(out_dir / "build")
    md.out_dir = str(out_dir)
    md.log_dir = str(out_dir / "logs")
    md.binary_dir = str(tests_dir)
    md.coverage_dir = str(cov_dir)
    md.dir_out = str(out_dir)
    md.dir_metadata = str(metadata_dir)
    md.dir_build = str(out_dir / "build")
    md.dir_run = str(run_dir)
    md.dir_tests = str(tests_dir)
    md.dir_tb = str(out_dir / "build" / "tb")
    md.dir_instruction_generator = str(out_dir / "build" / "instr_gen")
    md.dir_cov = str(cov_dir)
    md.dir_fcov = str(cov_dir / "fcov")
    md.dir_shared_cov = str(cov_dir / "shared_cov")
    md.dir_cov_merged = str(cov_dir / "merged")
    md.dir_cov_report = str(cov_dir / "report")
    md.rtl_test = args.get("RTL_TEST", "core_eh2_base_test")
    md.sim_opts = args.get("SIM_OPTS", "")
    md.gen_opts = args.get("GEN_OPTS", "")
    md.eh2_configs = str(root / "eh2_configs.yaml")
    md.eh2_riscvdv_customtarget = str(core_eh2 / "riscv_dv_extension")
    md.eh2_riscvdv_testlist = str(
        core_eh2 / "riscv_dv_extension" / "testlist.yaml")
    md.directed_test_dir = str(core_eh2 / "directed_tests")
    md.directed_test_data = str(
        core_eh2 / "directed_tests" / "directed_testlist.yaml")
    md.cosim_test_data = str(
        core_eh2 / "directed_tests" / "cosim_testlist.yaml")

    md.tests_and_counts = _select_test_entries(
        md, Path(md.eh2_riscvdv_testlist),
        [Path(md.directed_test_data), Path(md.cosim_test_data)])
    md.riscvdv_tds = _tds_for_type(md, "RISCVDV")
    md.directed_tds = _tds_for_type(md, "DIRECTED")
    md.tests_pickle_files = [
        str(metadata_dir / f"{tds}.pkl")
        for tds in md.riscvdv_tds + md.directed_tds
    ]

    metadata_dir.mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    Path(md.dir_build).mkdir(parents=True, exist_ok=True)
    Path(md.dir_tests).mkdir(parents=True, exist_ok=True)
    md.save(str(metadata_dir / "metadata"))
    return md


def print_field(dir_metadata: str, field: str) -> str:
    """Print one metadata field for Makefile use."""
    md = RegressionMetadata.construct_from_metadata_dir(dir_metadata)
    if field == "riscvdv_tds":
        value = md.riscvdv_tds
    elif field == "directed_tds":
        value = md.directed_tds
    else:
        if not hasattr(md, field):
            raise AttributeError(f"Unknown metadata field: {field}")
        value = getattr(md, field)

    if isinstance(value, (list, tuple)):
        if value and isinstance(value[0], (list, tuple)):
            return " ".join(".".join(str(part) for part in item)
                            for item in value)
        return " ".join(str(item) for item in value)
    if value is None:
        return ""
    return str(value)


def main(argv=None) -> int:
    """Entry point compatible with Ibex's metadata.py --op interface."""
    parser = argparse.ArgumentParser(description="EH2 regression metadata helper")
    parser.add_argument("--op", required=True,
                        choices=["create_metadata", "print_field"])
    parser.add_argument("--dir-metadata", required=True)
    parser.add_argument("--dir-out", default="")
    parser.add_argument("--args-list", default="")
    parser.add_argument("--field", default="")
    args = parser.parse_args(argv)

    if args.op == "create_metadata":
        if not args.dir_out:
            parser.error("--dir-out is required for create_metadata")
        create_metadata(args.dir_metadata, args.dir_out, args.args_list)
        return 0
    if args.op == "print_field":
        if not args.field:
            parser.error("--field is required for print_field")
        print(print_field(args.dir_metadata, args.field))
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())

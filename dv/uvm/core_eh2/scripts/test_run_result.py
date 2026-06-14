#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 Test Run Result

Data class for tracking individual test run metadata and results.
Modeled after ibex's test_run_result.py.
"""

from enum import Enum
from pathlib import Path
from typing import Optional, List
from dataclasses import dataclass, field

import scripts_lib

import logging
logger = logging.getLogger(__name__)


class TestType(Enum):
    """Type of the test."""
    RISCVDV = 0
    DIRECTED = 1


class FailureModes(Enum):
    """Descriptive enum for the mode in which a test fails."""
    NONE = 0
    TIMEOUT = 1      # Simulation did not complete within timeout
    FILE_ERROR = 2   # Problem opening a logfile
    LOG_ERROR = 3    # Logfile contents indicate test failure
    UVM_FATAL = 4    # UVM_FATAL encountered
    COSIM_MISMATCH = 5  # Co-simulation mismatch

    def __str__(self):
        return f'{self.name}({self.value})'


@dataclass
class TestRunResult(scripts_lib.TestdataCls):
    """Holds metadata about a single test run and its results."""

    # Test identification
    testname: Optional[str] = None
    seed: Optional[int] = None
    testdotseed: Optional[str] = None
    testtype: Optional[TestType] = None

    # Result
    passed: Optional[bool] = None
    failure_mode: Optional[FailureModes] = None
    failure_message: Optional[str] = None
    timeout_s: Optional[int] = None

    # Simulator
    rtl_simulator: Optional[str] = None
    iss_cosim: Optional[str] = None

    # Binary paths
    binary: Optional[Path] = None
    assembly: Optional[Path] = None
    objectfile: Optional[Path] = None

    # riscv-dv specific
    gen_test: Optional[str] = None
    gen_opts: Optional[str] = None
    rtl_test: Optional[str] = None
    sim_opts: Optional[str] = None

    # Directed test specific
    directed_data: Optional[dict] = None

    # Directory paths
    dir_test: Optional[Path] = None
    dir_fcov: Optional[Path] = None

    # Log paths
    riscvdv_run_gen_log: Optional[Path] = None
    riscvdv_run_gen_stdout: Optional[Path] = None
    compile_asm_log: Optional[Path] = None
    rtl_log: Optional[Path] = None
    rtl_stdout: Optional[Path] = None
    rtl_trace: Optional[Path] = None
    iss_cosim_log: Optional[Path] = None

    # Commands executed
    riscvdv_run_gen_cmds: Optional[List[List[str]]] = None
    compile_asm_cmds: Optional[List[List[str]]] = None
    rtl_cmds: Optional[List[List[str]]] = None

    # Persistence
    pickle_file: Optional[Path] = None
    yaml_file: Optional[Path] = None

    @classmethod
    def construct_from_metadata_dir(cls, dir_metadata: Path, tds: str):
        """Construct metadata object from exported pickle."""
        trr_pickle = dir_metadata / f"{tds}.pickle"
        return cls.construct_from_pickle(trr_pickle)

    def format_to_printable_dict(self) -> dict:
        """Format to printable dict with relative paths."""
        from dataclasses import asdict
        relative_dict = {}
        for k, v in asdict(self).items():
            if isinstance(v, Path) and self.dir_test and v.is_relative_to(self.dir_test):
                relative_dict[k] = str(v.relative_to(self.dir_test))
            else:
                relative_dict[k] = v
        return scripts_lib.format_dict_to_printable_dict(relative_dict)

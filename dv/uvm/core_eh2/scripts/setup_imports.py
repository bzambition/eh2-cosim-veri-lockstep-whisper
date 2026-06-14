#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 Python Path Setup

Sets up PYTHONPATH for all regression scripts.
Modeled after ibex's setup_imports.py.
"""

import sys
from pathlib import Path


def get_project_root() -> Path:
    """Get the project root directory (eh2-veri/)."""
    return Path(__file__).resolve().parents[4]


root = get_project_root()
_EH2_ROOT = root
_CORE_EH2 = root / 'dv' / 'uvm' / 'core_eh2'
_CORE_EH2_SCRIPTS = _CORE_EH2 / 'scripts'
_CORE_EH2_RISCV_DV_EXTENSION = _CORE_EH2 / 'riscv_dv_extension'
_CORE_EH2_YAML = _CORE_EH2 / 'yaml'
_RISCV_DV = root / 'vendor' / 'google_riscv-dv'
_RISCV_DV_SCRIPTS = _RISCV_DV / 'scripts'


def get_pythonpath() -> str:
    """Create a PYTHONPATH string for all regression scripts."""
    pythonpath = ':'.join([
        str(_EH2_ROOT),
        str(_CORE_EH2_SCRIPTS),
        str(_CORE_EH2_RISCV_DV_EXTENSION),
        str(_CORE_EH2_YAML),
        str(_RISCV_DV_SCRIPTS),
    ])
    return pythonpath


if __name__ == '__main__':
    print(get_pythonpath())

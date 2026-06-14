#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 Testbench Compilation Script

Compiles the UVM testbench for a given simulator.
Modeled after ibex's compile_tb.py.
"""

import argparse
import os
import sys
import subprocess
from pathlib import Path

from metadata import RegressionMetadata
from scripts_lib import run_one

import logging
logger = logging.getLogger(__name__)


def get_compile_cmd(md: RegressionMetadata) -> list:
    """Build the compilation command based on simulator type."""
    eh2_root = Path(__file__).resolve().parents[4]
    core_eh2 = eh2_root / 'dv' / 'uvm' / 'core_eh2'

    if md.simulator == 'vcs':
        cmd = [
            'vcs', '-full64',
            '-sverilog',
            '-ntb_opts', 'uvm-1.2',
            '-timescale=1ns/1ps',
            '+define+UVM_VERDI_COMPWAVE',
            '-debug_access+all',
            '-kdb',
            '-l', os.path.join(md.work_dir, 'compile.log'),
            '-Mdir={}'.format(os.path.join(md.work_dir, 'csrc')),
        ]
        # Add filelists
        cmd += ['-f', str(core_eh2 / 'eh2_rtl.f')]
        cmd += ['-f', str(core_eh2 / 'eh2_shared.f')]
        cmd += ['-f', str(core_eh2 / 'eh2_tb.f')]
        # Add include dirs
        cmd += ['+incdir+{}'.format(core_eh2 / 'riscv_dv_extension')]
        # Add cosim DPI
        cmd += ['-CFLAGS', '-std=c++17']
        # Output
        cmd += ['-o', os.path.join(md.work_dir, 'simv')]

    elif md.simulator == 'xlm':
        cmd = [
            'xrun', '-64bit',
            '-uvm',
            '-sv',
            '-timescale', '1ns/1ps',
            '-l', os.path.join(md.work_dir, 'compile.log'),
        ]
        cmd += ['-f', str(core_eh2 / 'eh2_rtl.f')]
        cmd += ['-f', str(core_eh2 / 'eh2_shared.f')]
        cmd += ['-f', str(core_eh2 / 'eh2_tb.f')]
        cmd += ['+incdir+{}'.format(core_eh2 / 'riscv_dv_extension')]

    elif md.simulator == 'questa':
        cmd = [
            'vlog', '-sv',
            '-timescale', '1ns/1ps',
            '-l', os.path.join(md.work_dir, 'compile.log'),
        ]
        cmd += ['-f', str(core_eh2 / 'eh2_rtl.f')]
        cmd += ['-f', str(core_eh2 / 'eh2_shared.f')]
        cmd += ['-f', str(core_eh2 / 'eh2_tb.f')]

    else:
        raise ValueError(f'Unsupported simulator: {md.simulator}')

    return cmd


def main():
    parser = argparse.ArgumentParser(description='Compile EH2 UVM testbench')
    parser.add_argument('--dir-metadata', type=Path, required=True,
                        help='Path to regression metadata directory')
    args = parser.parse_args()

    md = RegressionMetadata.construct_from_metadata_dir(args.dir_metadata)
    os.makedirs(md.work_dir, exist_ok=True)

    cmd = get_compile_cmd(md)
    logger.info(f'Compiling testbench with {md.simulator}')

    stdout_log = os.path.join(md.work_dir, 'compile_stdout.log')
    retcode = run_one(True, cmd, redirect_stdstreams=stdout_log)

    if retcode:
        logger.error(f'Compilation failed with return code {retcode}')
    else:
        logger.info('Compilation succeeded')

    return retcode


if __name__ == '__main__':
    sys.exit(main())

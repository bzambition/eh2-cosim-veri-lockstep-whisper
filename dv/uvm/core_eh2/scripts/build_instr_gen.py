#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 Instruction Generator Build Script

Builds the riscv-dv instruction generator if required.
Modeled after ibex's build_instr_gen.py.
"""

import argparse
import shutil
import sys
from pathlib import Path

from metadata import RegressionMetadata
from scripts_lib import run_one, format_to_cmd
import riscvdv_interface

import logging
logger = logging.getLogger(__name__)


def main():
    parser = argparse.ArgumentParser(description='Build riscv-dv instruction generator')
    parser.add_argument('--dir-metadata', type=Path, required=True,
                        help='Path to regression metadata directory')
    args = parser.parse_args()

    md = RegressionMetadata.construct_from_metadata_dir(args.dir_metadata)

    # Clean and recreate the instruction generator directory
    gen_dir = Path(md.work_dir) / 'instr_gen'
    try:
        shutil.rmtree(gen_dir)
    except FileNotFoundError:
        pass
    gen_dir.mkdir(exist_ok=True, parents=True)

    # Build command using riscvdv_interface with a dummy test for compile-only
    cmd = riscvdv_interface.get_run_cmd(
        test='riscv_arithmetic_basic_test',
        seed=0,
        isa='rv32imac_zba_zbb_zbc_zbs',
        output_dir=str(gen_dir),
    )
    # Append compile-only flags
    cmd.extend(['--co', '--simulator', md.simulator, '--end_signature_addr', '0D058000'])
    cmd = format_to_cmd(cmd)

    stdout_log = gen_dir / 'build_stdout.log'
    logger.info('Building instruction generator')
    retcode = run_one(True, cmd, redirect_stdstreams=stdout_log)

    if retcode:
        logger.error(f'Build failed with return code {retcode}')
    else:
        logger.info('Instruction generator build succeeded')

    return retcode


if __name__ == '__main__':
    sys.exit(main())

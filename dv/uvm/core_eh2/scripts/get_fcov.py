#!/usr/bin/env python3
"""Get the riscv_dv functional coverage results."""

# SPDX-License-Identifier: Apache-2.0

import sys
import argparse
import shutil
import subprocess
import logging

logger = logging.getLogger(__name__)


def _main():
    parser = argparse.ArgumentParser(description="Collect riscv-dv functional coverage")
    parser.add_argument("--dir-metadata", type=str, required=True,
                        help="Path to metadata directory")
    parser.add_argument("--simulator", type=str, default="vcs",
                        choices=["vcs", "xlm", "questa"],
                        help="Simulator used for coverage collection")
    parser.add_argument("--cov-dir", type=str, default=None,
                        help="Override coverage output directory")
    parser.add_argument("--verbose", action="store_true",
                        help="Enable verbose output")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)

    # Locate the coverage databases from individual test runs
    metadata_dir = args.dir_metadata
    cov_dir = args.cov_dir or f"{metadata_dir}/fcov"
    logger.info("Collecting functional coverage from %s", metadata_dir)

    # For VCS: use urg to merge and report coverage
    if args.simulator == "vcs":
        vdb_files = []
        import pathlib
        for vdb in pathlib.Path(metadata_dir).rglob("*.vdb"):
            vdb_files.append(str(vdb))

        if not vdb_files:
            logger.warning("No .vdb coverage databases found in %s", metadata_dir)
            return 0

        urg_cmd = [
            "urg",
            "-dir", ",".join(vdb_files),
            "-report", f"{cov_dir}/report",
            "-format", "both",
        ]
        logger.info("Running: %s", " ".join(urg_cmd))
        result = subprocess.run(urg_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            logger.error("urg failed:\n%s", result.stderr)
            return result.returncode
        logger.info("Coverage report written to %s/report", cov_dir)

    elif args.simulator == "xlm":
        logger.info("Xcelium coverage collection: use -covoverwrite with imc")

    return 0


if __name__ == "__main__":
    sys.exit(_main())

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 Test Entry Utilities

Provides functions for reading test entries from testlist.yaml.
Modeled after ibex's test_entry.py.
"""

import re
from typing import Dict, List, Tuple
from pathlib import Path

import scripts_lib

import logging
logger = logging.getLogger(__name__)

TestEntry = Dict[str, object]
TestEntries = List[TestEntry]
TestAndSeed = Tuple[str, int]


def read_test_dot_seed(arg: str) -> TestAndSeed:
    """Read a value for --test-dot-seed argument (format: TEST.SEED)."""
    match = re.match(r'([^.]+)\.([0-9]+)$', arg)
    if match is None:
        raise ValueError(
            f'Bad --test-dot-seed ({arg}): should be of the form TEST.SEED.')
    return (match.group(1), int(match.group(2), 10))


def get_test_entry(testname: str, testlist: Path) -> TestEntry:
    """Get a specific test entry from the testlist by name."""
    yaml_data = scripts_lib.read_yaml(testlist)

    for entry in yaml_data:
        if entry.get('test') == testname:
            return entry

    raise RuntimeError(f'No matching test entry for {testname!r}')

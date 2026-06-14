# SPDX-License-Identifier: Apache-2.0
"""
EH2 Report Utilities

Common utility functions for report generation.
Adapted from ibex's report_lib/util.py.
"""

from typing import List, Dict
from dataclasses import asdict
import re
import io

CSS_RG_GRADIENT_YELLOW_POINT = 0.7


def css_red_green_gradient(value: float) -> str:
    """Output a CSS color value from a red-yellow-green gradient."""
    if value < CSS_RG_GRADIENT_YELLOW_POINT:
        red = 1.0
        green = value / CSS_RG_GRADIENT_YELLOW_POINT
    else:
        red = (1.0 - value) / (1.0 - CSS_RG_GRADIENT_YELLOW_POINT)
        green = 1.0

    red = int(red * 255)
    green = int(green * 255)

    return f'rgb({red},{green},0)'


def gen_test_run_result_text(trr) -> str:
    """Generate a string describing a TestRunResult."""
    test_name_idx = f'{trr.testname}.{trr.seed}'
    test_underline = '-' * len(test_name_idx)
    info_lines = [test_name_idx, test_underline]

    # Filter relevant fields
    relevant_keys = ['binary', 'rtl_log', 'rtl_trace', 'iss_cosim_log']
    lesskeys = {}
    for k, v in asdict(trr).items():
        if k in relevant_keys:
            if v is not None and hasattr(v, 'relative_to') and trr.dir_test:
                try:
                    lesskeys[k] = str(v.relative_to(trr.dir_test))
                except ValueError:
                    lesskeys[k] = str(v)
            else:
                lesskeys[k] = str(v) if v is not None else 'MISSING'

    # Format as YAML-like output
    for k, v in lesskeys.items():
        info_lines.append(f'  {k}: {v}')

    if trr.passed:
        info_lines.append('\n[PASSED]')
    else:
        info_lines.append(str(trr.failure_message) if trr.failure_message else '\n[FAILED]')

    return '\n' + '\n'.join(info_lines) + '\n'


def create_test_summary_dict(tests: list) -> Dict[str, Dict[str, int]]:
    """Create a dictionary of passing/failing counts per test name."""
    test_summary_dict = {}

    for test in tests:
        if test.testname not in test_summary_dict:
            test_summary_dict[test.testname] = {'passing': 0, 'failing': 0}

        if test.passed:
            test_summary_dict[test.testname]['passing'] += 1
        else:
            test_summary_dict[test.testname]['failing'] += 1

    return test_summary_dict

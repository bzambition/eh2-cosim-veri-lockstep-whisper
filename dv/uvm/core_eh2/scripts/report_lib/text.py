# SPDX-License-Identifier: Apache-2.0
"""
EH2 Text Report Generator

Generates plain text regression reports.
Adapted from ibex's report_lib/text.py.
"""

from typing import List, TextIO, Dict
import io

import scripts_lib
from .util import gen_test_run_result_text


def box_comment(line: str) -> str:
    hr = '#' * 80
    return hr + '\n# ' + line + '\n' + hr


def gen_summary_line(passing_tests: list, failing_tests: list) -> str:
    """Generate a summary line for test results."""
    total_tests = len(passing_tests) + len(failing_tests)
    if total_tests == 0:
        return 'No tests run'
    pass_pct = (len(passing_tests) / total_tests) * 100
    return f'{pass_pct:0.2f}% PASS {len(passing_tests)} PASSED, ' \
           f'{len(failing_tests)} FAILED'


def output_results_text(passing_tests: list, failing_tests: list,
                        summary_dict: Dict[str, str], report_file: TextIO):
    """Write results in text form to report_file."""
    # Summary line at top
    report_file.write(gen_summary_line(passing_tests, failing_tests))
    report_file.write('\n')

    # Short TEST.SEED PASS/FAILED summary
    summary_yaml = io.StringIO()
    scripts_lib.pprint_dict(summary_dict, summary_yaml)
    summary_yaml.seek(0)
    report_file.write(summary_yaml.getvalue())
    report_file.write('\n')

    # Detailed failing tests
    print('\n' + box_comment('Details of failing tests'), file=report_file)
    if not failing_tests:
        print("No failing tests.", file=report_file)
    for trr in failing_tests:
        print(gen_test_run_result_text(trr), file=report_file)

    # Detailed passing tests
    print('\n' + box_comment('Details of passing tests'), file=report_file)
    if not passing_tests:
        print("No passing tests.", file=report_file)
    for trr in passing_tests:
        print(gen_test_run_result_text(trr), file=report_file)

# SPDX-License-Identifier: Apache-2.0
"""
EH2 HTML Report Generator

Generates HTML regression reports using Mako templates.
Adapted from ibex's report_lib/html.py.
"""

from typing import List, TextIO, Dict
from datetime import datetime
import os

from .util import gen_test_run_result_text, css_red_green_gradient


def pct_str(pct_val: float) -> str:
    """Format a percentage value as string."""
    return f'{pct_val * 100:.1f}%'


def pct_style(pct_val: float) -> str:
    """Get CSS style for a percentage value (red-green gradient)."""
    return f'background-color: {css_red_green_gradient(pct_val)};'


def output_results_html(md, all_tests: list, test_summary_dict: Dict[str, Dict[str, int]],
                        cov_summary_dict: Dict[str, float], dest: TextIO) -> None:
    """Write HTML report for given test and coverage results to dest.

    Uses a simple string-based template (no Mako dependency required).
    """
    total_tests_acc = 0
    passing_tests_acc = 0

    test_summaries = []
    for test_name, test_info in test_summary_dict.items():
        total_tests = test_info['passing'] + test_info['failing']
        pass_rate = test_info['passing'] / total_tests if total_tests > 0 else 0

        test_summaries.append({
            'name': test_name,
            'passing': test_info['passing'],
            'total_tests': total_tests,
            'pass_rate': pass_rate,
        })

        total_tests_acc += total_tests
        passing_tests_acc += test_info['passing']

    pass_rate_acc = passing_tests_acc / total_tests_acc if total_tests_acc > 0 else 0

    # Generate HTML
    html = []
    html.append('<!DOCTYPE html>')
    html.append('<html>')
    html.append('<head><title>EH2 Regression Results</title>')
    html.append('<style>')
    html.append('body { font-family: Arial, sans-serif; margin: 20px; }')
    html.append('table { border-collapse: collapse; margin: 10px 0; }')
    html.append('th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }')
    html.append('th { background-color: #4CAF50; color: white; }')
    html.append('pre { background-color: #f5f5f5; padding: 10px; overflow-x: auto; }')
    html.append('</style>')
    html.append('</head>')
    html.append('<body>')
    html.append('<h1>EH2 Regression Results</h1>')
    html.append(f'<h2>Date/Time run: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}</h2>')

    # Test results table
    html.append('<h2>Test Results</h2>')
    html.append('<table>')
    html.append('<tr><th>Test Name</th><th>Passing</th><th>Total</th><th>Pass Rate</th></tr>')
    for test in test_summaries:
        html.append(f'<tr>')
        html.append(f'<td>{test["name"]}</td>')
        html.append(f'<td>{test["passing"]}</td>')
        html.append(f'<td>{test["total_tests"]}</td>')
        html.append(f'<td style="{pct_style(test["pass_rate"])}">{pct_str(test["pass_rate"])}</td>')
        html.append(f'</tr>')
    html.append(f'<tr><td><b>Total</b></td><td>{passing_tests_acc}</td>')
    html.append(f'<td>{total_tests_acc}</td>')
    html.append(f'<td style="{pct_style(pass_rate_acc)}">{pct_str(pass_rate_acc)}</td></tr>')
    html.append('</table>')

    # Coverage summary
    if cov_summary_dict:
        html.append('<h2>Coverage</h2>')
        html.append('<table>')
        html.append('<tr><th>Metric</th><th>Coverage</th></tr>')
        for metric, value in cov_summary_dict.items():
            if value is not None:
                html.append(f'<tr><td>{metric}</td>')
                html.append(f'<td style="{pct_style(value)}">{pct_str(value)}</td></tr>')
        html.append('</table>')

    # Failing test details
    html.append('<h2>Test Failure Details</h2>')
    failing = [t for t in all_tests if not t.passed]
    if not failing:
        html.append('<p>No failing tests.</p>')
    else:
        for test in failing:
            html.append(f'<pre>{gen_test_run_result_text(test)}</pre>')

    html.append('</body>')
    html.append('</html>')

    dest.write('\n'.join(html))

# SPDX-License-Identifier: Apache-2.0
# dvsim-compatible JSON report generation for EH2 regression results.
# Adapted from lowRISC ibex.

from typing import Dict, TextIO
import json


def create_dvsim_report_dict(tool: str, block_name: str, block_variant: str,
                             test_summary_dict: Dict[str, Dict[str, int]],
                             cov_summary_dict: Dict[str, float]) -> Dict:
    '''Produces a dvsim json style dict for given test and coverage results.'''

    dvsim_test_info = []

    for test_name, test_info in test_summary_dict.items():
        total_runs = test_info['passing'] + test_info['failing']

        dvsim_test_info.append({
            'name': test_name,
            'max_runtime_s': 0,
            'simulated_time_us': 0,
            'passing_runs': test_info['passing'],
            'total_runs': total_runs,
            'pass_rate': round((test_info['passing'] / total_runs) * 100, 2)
            if total_runs > 0 else 0
        })

    if cov_summary_dict:
        dvsim_cov_summary_dict = {
            cov_name: cov_value * 100
            for cov_name, cov_value in cov_summary_dict.items()
        }
    else:
        dvsim_cov_summary_dict = {}

    return {
        'tool': 'xcelium' if tool == 'xlm' else tool,
        'block_name': block_name,
        'block_variant': block_variant,
        'results': {
            'coverage': dvsim_cov_summary_dict,
            'testpoints': [],
            'unmapped_tests': dvsim_test_info
        },
    }


def output_results_dvsim_json(test_summary_dict: Dict[str, Dict[str, int]],
                              cov_summary_dict: Dict[str, float],
                              dest: TextIO,
                              tool: str = 'vcs',
                              block_name: str = 'eh2',
                              block_variant: str = 'default'):
    '''Write dvsim compatible JSON for given test and coverage results to dest.'''
    json_content = json.dumps(
        create_dvsim_report_dict(tool, block_name, block_variant,
                                 test_summary_dict, cov_summary_dict),
        indent=2
    )
    dest.write(json_content)

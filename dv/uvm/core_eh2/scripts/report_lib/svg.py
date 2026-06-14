# SPDX-License-Identifier: Apache-2.0
# SVG dashboard generation for EH2 regression reports.
# Adapted from lowRISC ibex.

from textwrap import dedent
from functools import reduce
from .util import css_red_green_gradient
from typing import List, TextIO, Dict

SVG_DASHBOARD_HEIGHT = 20
SVG_DASHBOARD_GAP = 5
SVG_DASHBOARD_STYLE = dedent("""
    .text { font: 12px sans-serif;
            text-anchor: middle;
            dominant-baseline: middle;}
    .name { fill: white; }
    .value { fill: black; }
""")
SVG_DASHBOARD_VALUE_WIDTH = 60
SVG_DASHBOARD_NAME_BG_COLOUR = "#666"
SVG_DASHBOARD_PLAIN_VALUE_BG_COLOUR = "#6cf"


class DashboardElement:
    '''A name and value pair SVG dashboard element.'''

    def __init__(self, name: str, value: str, name_width: int,
                 value_colour: str = SVG_DASHBOARD_PLAIN_VALUE_BG_COLOUR,
                 value_width: int = SVG_DASHBOARD_VALUE_WIDTH,
                 height: int = SVG_DASHBOARD_HEIGHT):
        self.name = name
        self.name_width = name_width
        self.value = value
        self.value_width = value_width
        self.height = height
        self.value_colour = value_colour

    def to_svg(self) -> str:
        '''Generate SVG markup for this element.'''
        label_x = self.name_width / 2
        label_y = self.height / 2
        value_x = self.value_width / 2
        value_y = self.height / 2
        return (
            f'<g>'
            f'<rect x="0" y="0" width="{self.name_width}" height="{self.height}" '
            f'fill="{SVG_DASHBOARD_NAME_BG_COLOUR}" stroke-width="0"/>'
            f'<text x="{label_x}" y="{label_y}" class="text name">{self.name}</text>'
            f'</g>'
            f'<g transform="translate({self.name_width}, 0)">'
            f'<rect x="0" y="0" width="{self.value_width}" height="{self.height}" '
            f'fill="{self.value_colour}" stroke-width="0"/>'
            f'<text x="{value_x}" y="{value_y}" class="text value">{self.value}</text>'
            f'</g>'
        )

    def calc_total_width(self) -> int:
        return self.name_width + self.value_width


class Dashboard:
    '''A collection of dashboard elements arranged side by side.'''

    def __init__(self, dashboard_elements: List[DashboardElement],
                 element_gap: int):
        self.dashboard_elements = dashboard_elements
        self.element_gap = element_gap

    def to_svg(self) -> str:
        '''Generate SVG markup for the full dashboard.'''
        elements_svg = []
        cur_x = 0
        for de in self.dashboard_elements:
            elements_svg.append(
                f'<g transform="translate({cur_x}, 0)">{de.to_svg()}</g>'
            )
            cur_x += de.calc_total_width() + self.element_gap
        return ''.join(elements_svg)

    def calc_total_width(self) -> int:
        return reduce(
            lambda acc, de: acc + de.calc_total_width() + self.element_gap,
            self.dashboard_elements,
            0
        ) - self.element_gap


def output_results_svg(test_summary_dict: Dict[str, Dict[str, int]],
                       cov_summary_dict: Dict[str, float],
                       dest: TextIO) -> None:
    '''Write an SVG summary dashboard for the given test and coverage results.'''

    passing_tests = sum(
        info['passing'] for info in test_summary_dict.values()
    )
    failing_tests = sum(
        info['failing'] for info in test_summary_dict.values()
    )
    total_tests = passing_tests + failing_tests

    if total_tests == 0:
        dest.write('<svg xmlns="http://www.w3.org/2000/svg"></svg>')
        return

    passing_pct = passing_tests / total_tests

    dashboard_elements = [
        DashboardElement("Total Tests", str(total_tests), 120),
        DashboardElement("Tests Passing", f"{passing_pct * 100:.1f}%", 120,
                         value_colour=css_red_green_gradient(passing_pct)),
    ]

    if cov_summary_dict:
        code_cov_keys = ['block', 'branch', 'statement', 'expression', 'fsm']
        code_coverage_vals = [cov_summary_dict.get(k, 0) for k in code_cov_keys]
        code_coverage = sum(code_coverage_vals) / len(code_coverage_vals)

        dashboard_elements.append(
            DashboardElement("Functional Coverage",
                             f"{cov_summary_dict.get('covergroup', 0) * 100:.1f}%",
                             150,
                             value_colour=css_red_green_gradient(
                                 cov_summary_dict.get('covergroup', 0)))
        )
        dashboard_elements.append(
            DashboardElement("Code Coverage",
                             f"{code_coverage * 100:.1f}%",
                             120,
                             value_colour=css_red_green_gradient(code_coverage))
        )

    regression_dashboard = Dashboard(dashboard_elements, SVG_DASHBOARD_GAP)
    total_width = regression_dashboard.calc_total_width()

    svg_content = (
        f'<svg xmlns="http://www.w3.org/2000/svg" '
        f'width="{total_width}" height="{SVG_DASHBOARD_HEIGHT}">'
        f'<style>{SVG_DASHBOARD_STYLE}</style>'
        f'{regression_dashboard.to_svg()}'
        f'</svg>'
    )

    dest.write(svg_content)

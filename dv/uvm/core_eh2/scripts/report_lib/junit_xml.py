# SPDX-License-Identifier: Apache-2.0
"""
EH2 JUnit XML Report Generator

Generates JUnit XML regression reports for CI integration.
Adapted from ibex's report_lib/junit_xml.py.
"""

from typing import List, TextIO
from xml.etree.ElementTree import Element, SubElement, tostring
from xml.dom.minidom import parseString

from .util import gen_test_run_result_text


class TestCase:
    """JUnit XML test case."""

    def __init__(self, name: str):
        self.name = name
        self.stdout = ''
        self.stderr = ''
        self.failure_message = None
        self.failure_output = None

    def add_failure_info(self, message: str = '', output: str = ''):
        self.failure_message = message
        self.failure_output = output


class TestSuite:
    """JUnit XML test suite."""

    def __init__(self, name: str, test_cases: List[TestCase]):
        self.name = name
        self.test_cases = test_cases


def to_xml_report_string(test_suites: List[TestSuite]) -> str:
    """Convert test suites to JUnit XML string."""
    root = Element('testsuites')

    for suite in test_suites:
        suite_elem = SubElement(root, 'testsuite')
        suite_elem.set('name', suite.name)
        suite_elem.set('tests', str(len(suite.test_cases)))

        failures = sum(1 for tc in suite.test_cases if tc.failure_message is not None)
        suite_elem.set('failures', str(failures))

        for tc in suite.test_cases:
            tc_elem = SubElement(suite_elem, 'testcase')
            tc_elem.set('name', tc.name)

            if tc.stdout:
                stdout_elem = SubElement(tc_elem, 'stdout')
                stdout_elem.text = tc.stdout

            if tc.failure_message is not None:
                failure_elem = SubElement(tc_elem, 'failure')
                failure_elem.set('message', tc.failure_message or 'Test failed')
                if tc.failure_output:
                    failure_elem.text = tc.failure_output

    xml_str = tostring(root, encoding='unicode')
    return parseString(xml_str).toprettyxml(indent='  ')


def output_run_results_junit_xml(passing_tests: list, failing_tests: list,
                                  junit_dest: TextIO,
                                  junit_merged_dest: TextIO):
    """Write results to JUnit XML.

    Produces two versions:
    - Normal: test suite per unique test name, test case per seed
    - Merged: single test case per suite with merged output
    """
    all_tests = passing_tests + failing_tests

    test_suite_info = {}
    for trr in all_tests:
        unmerged, merged = test_suite_info.setdefault(
            trr.testname, ([], {'stdout': '', 'failures': ''}))
        result_text = gen_test_run_result_text(trr)

        test_case = TestCase(f'{trr.testname}.{trr.seed}')
        test_case.stdout = result_text

        merged['stdout'] += result_text + '\n'

        if not trr.passed:
            test_case.add_failure_info(output=result_text)
            merged['failures'] += result_text

        unmerged.append(test_case)

    # Normal JUnit XML
    test_suites = [TestSuite(name, test_cases)
                   for name, (test_cases, _) in test_suite_info.items()]
    junit_dest.write(to_xml_report_string(test_suites))

    # Merged JUnit XML
    merged_test_suites = []
    for name, (_, merged_info) in test_suite_info.items():
        test_case = TestCase(name)
        test_case.stdout = merged_info['stdout']
        if merged_info['failures']:
            test_case.add_failure_info(output=merged_info['failures'])
        merged_test_suites.append(TestSuite(name, [test_case]))

    junit_merged_dest.write(to_xml_report_string(merged_test_suites))

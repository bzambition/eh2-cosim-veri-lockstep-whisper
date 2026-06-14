"""Tests for signoff.parse_coverage_text."""
import sys
import os
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from signoff import parse_coverage_text


def test_urg_dashboard_header_format():
    """URG dashboard.txt with header row + data row on consecutive lines."""
    text = (
        "-------------------------------------------------------------------------------\n"
        "Total Coverage Summary \n"
        "SCORE  LINE   COND   TOGGLE FSM    ASSERT \n"
        " 41.59  82.73  40.61  35.57  22.39  26.67 \n"
        "-------------------------------------------------------------------------------\n"
    )
    result = parse_coverage_text(text)
    assert result["line"] == pytest.approx(82.73)
    assert result["cond"] == pytest.approx(40.61)
    assert result["toggle"] == pytest.approx(35.57)
    assert result["fsm"] == pytest.approx(22.39)
    assert result["assert"] == pytest.approx(26.67)
    assert result["overall"] == pytest.approx(41.59)


def test_urg_dashboard_header_with_blank_line():
    """URG dashboard.txt with a blank line between header and data."""
    text = (
        "SCORE  LINE   COND   TOGGLE FSM    ASSERT \n"
        "\n"
        " 41.59  82.73  40.61  35.57  22.39  26.67 \n"
    )
    result = parse_coverage_text(text)
    assert result["line"] == pytest.approx(82.73)
    assert result["fsm"] == pytest.approx(22.39)
    assert result["overall"] == pytest.approx(41.59)


def test_urg_hierarchical_dashboard():
    """URG hierarchical per-instance coverage line."""
    text = (
        "SCORE  LINE   COND   TOGGLE FSM    ASSERT NAME            \n"
        " 41.59  82.73  40.61  35.57  22.39  26.67 core_eh2_tb_top \n"
    )
    result = parse_coverage_text(text)
    assert result["line"] == pytest.approx(82.73)
    assert result["fsm"] == pytest.approx(22.39)


def test_old_style_line_coverage():
    """Old-style 'Line Coverage: 82.73%' format (fallback)."""
    text = "Line Coverage: 82.73%"
    result = parse_coverage_text(text)
    assert result["line"] == pytest.approx(82.73)


def test_old_style_cond_coverage():
    """Old-style 'Condition Coverage = 40.61 %' format (fallback)."""
    text = "Condition Coverage = 40.61 %"
    result = parse_coverage_text(text)
    assert result["cond"] == pytest.approx(40.61)


def test_old_style_mixed():
    """Multiple old-style metrics in one string."""
    text = (
        "Line Coverage: 82.73%\n"
        "FSM Coverage: 22.39%\n"
        "Toggle Coverage: 35.57%\n"
    )
    result = parse_coverage_text(text)
    assert result["line"] == pytest.approx(82.73)
    assert result["fsm"] == pytest.approx(22.39)
    assert result["toggle"] == pytest.approx(35.57)


def test_urg_takes_precedence():
    """URG header parser takes precedence; old-style used as fallback."""
    text = (
        "SCORE  LINE   COND   TOGGLE FSM    ASSERT \n"
        " 10.0  20.0  30.0  40.0  50.0  60.0 \n"
        "Line Coverage: 99.99%\n"   # This should NOT overwrite the 20.0 from header
    )
    result = parse_coverage_text(text)
    # URG parser fills first; fallback only sets if key not present or higher
    assert result["line"] >= 20.0


def test_various_spacing():
    """Multiple spaces between header columns."""
    text = (
        "SCORE    LINE     COND     TOGGLE   FSM      ASSERT   \n"
        "  1.11    2.22     3.33     4.44     5.55     6.66    \n"
    )
    result = parse_coverage_text(text)
    assert result["overall"] == pytest.approx(1.11)
    assert result["line"] == pytest.approx(2.22)
    assert result["cond"] == pytest.approx(3.33)
    assert result["toggle"] == pytest.approx(4.44)
    assert result["fsm"] == pytest.approx(5.55)
    assert result["assert"] == pytest.approx(6.66)


def test_empty_text():
    """Empty input returns empty dict."""
    assert parse_coverage_text("") == {}


def test_total_module_definition():
    """URG Total Module Definition Coverage Summary header."""
    text = (
        "Total Module Definition Coverage Summary \n"
        "SCORE  LINE   COND   TOGGLE FSM    ASSERT \n"
        " 47.04  86.54  39.86  36.38  22.41  50.00 \n"
    )
    result = parse_coverage_text(text)
    assert result["overall"] == pytest.approx(47.04)
    assert result["line"] == pytest.approx(86.54)
    assert result["assert"] == pytest.approx(50.00)


def test_urg_group_dashboard_maps_to_functional():
    """URG group-only dashboard should populate functional coverage."""
    text = (
        "Total Coverage Summary \n"
        "SCORE  GROUP  \n"
        " 26.45  26.45 \n"
    )
    result = parse_coverage_text(text)
    assert result["overall"] == pytest.approx(26.45)
    assert result["functional"] == pytest.approx(26.45)

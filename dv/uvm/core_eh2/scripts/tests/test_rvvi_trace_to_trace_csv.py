#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import csv
import io
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import rvvi_trace_to_trace_csv


def _convert(text):
    out = io.StringIO()
    rvvi_trace_to_trace_csv.convert_rvvi_trace_fd(io.StringIO(text), out)
    out.seek(0)
    return list(csv.DictReader(out))


def test_retire_line_converts_to_riscv_dv_csv_with_abi_gpr():
    rows = _convert("0|7|80000004|00108093|0|3|gpr=x1:12345678|csr=\n")

    assert rows == [{
        "pc": "80000004",
        "instr": "",
        "gpr": "ra:12345678",
        "csr": "",
        "binary": "00108093",
        "mode": "3",
        "instr_str": "",
        "operand": "",
        "pad": "",
    }]


def test_legacy_six_field_dump_still_converts_without_state_updates():
    rows = _convert("0|0|80000000|00000013|0|3\n")

    assert rows[0]["pc"] == "80000000"
    assert rows[0]["binary"] == "00000013"
    assert rows[0]["gpr"] == ""
    assert rows[0]["csr"] == ""


def test_async_writeback_is_lazily_attached_to_matching_div_retire():
    rows = _convert(
        "A|0|div|x5:00000003\n"
        "0|0|80000000|025342b3|0|3|gpr=|csr=\n")

    assert rows[0]["gpr"] == "t0:00000003"


def test_future_async_writeback_is_lazily_attached_to_matching_load_retire():
    rows = _convert(
        "0|0|80000000|00032283|0|3|gpr=|csr=\n"
        "A|0|load|x5:feed0001\n")

    assert rows[0]["gpr"] == "t0:feed0001"

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


def test_stale_async_writeback_before_retire_is_ignored():
    rows = _convert(
        "A|0|div|x5:00000003\n"
        + "".join(
            "0|{}|800000{:02x}|00000013|0|3|gpr=|csr=\n".format(i, i * 4)
            for i in range(rvvi_trace_to_trace_csv.ASYNC_LOOKAHEAD_RETIRES + 1))
        +
        "0|0|80000000|025342b3|0|3|gpr=|csr=\n")

    assert rows[-1]["gpr"] == ""


def test_nearby_async_writeback_before_retire_matches_div():
    rows = _convert(
        "A|0|div|x5:00000003\n"
        "0|0|80000000|025342b3|0|3|gpr=|csr=\n")

    assert rows[0]["gpr"] == "t0:00000003"


def test_future_async_writeback_is_lazily_attached_to_matching_div_retire():
    rows = _convert(
        "0|0|80000000|025342b3|0|3|gpr=|csr=\n"
        "A|0|div|x5:00000003\n")

    assert rows[0]["gpr"] == "t0:00000003"


def test_future_async_writeback_is_lazily_attached_to_matching_load_retire():
    rows = _convert(
        "0|0|80000000|00032283|0|3|gpr=|csr=\n"
        "A|0|load|x5:feed0001\n")

    assert rows[0]["gpr"] == "t0:feed0001"


def test_long_delay_load_writeback_still_matches_retire():
    rows = _convert(
        "0|0|80000000|00032283|0|3|gpr=|csr=\n"
        + "".join(
            "0|{}|800001{:02x}|00000013|0|3|gpr=|csr=\n".format(i, i * 4)
            for i in range(rvvi_trace_to_trace_csv.LOAD_WRITEBACK_RETIRES - 1))
        +
        "A|0|load|x5:feed0001\n")

    assert rows[0]["gpr"] == "t0:feed0001"


def test_stale_load_writeback_does_not_attach_after_window():
    rows = _convert(
        "0|0|80000000|00032283|0|3|gpr=|csr=\n"
        + "".join(
            "0|{}|800001{:02x}|00000013|0|3|gpr=|csr=\n".format(i, i * 4)
            for i in range(rvvi_trace_to_trace_csv.LOAD_WRITEBACK_RETIRES + 1))
        +
        "A|0|load|x5:feed0001\n")

    assert rows[0]["gpr"] == ""


def test_tagged_load_writeback_matches_exact_retire():
    rows = _convert(
        "0|0|80000000|00032283|0|3|gpr=|csr=|tag=load:1\n"
        "0|1|80000004|00432283|0|3|gpr=|csr=|tag=load:2\n"
        "A|0|load|x5:00000001|tag=1\n"
        "0|2|80000008|001282b3|0|3|gpr=x5:00000002|csr=\n"
        "0|3|8000000c|00832283|0|3|gpr=|csr=|tag=load:3\n"
        "A|0|load|x5:00000003|tag=3\n"
        "A|0|load|x5:00000004|tag=2\n")

    assert rows[0]["gpr"] == "t0:00000001"
    assert rows[1]["gpr"] == "t0:00000004"
    assert rows[2]["gpr"] == "t0:00000002"
    assert rows[3]["gpr"] == "t0:00000003"


def test_stale_async_writeback_does_not_attach_to_future_div_retire():
    rows = _convert(
        "A|0|div|x8:ffffffff\n"
        + "".join(
            "0|{}|800001{:02x}|00000013|0|3|gpr=|csr=\n".format(i, i * 4)
            for i in range(rvvi_trace_to_trace_csv.ASYNC_LOOKAHEAD_RETIRES + 1))
        +
        "0|0|80000000|02804433|0|3|gpr=|csr=\n"
        "A|0|div|x8:00000000\n")

    assert rows[-1]["gpr"] == "s0:00000000"

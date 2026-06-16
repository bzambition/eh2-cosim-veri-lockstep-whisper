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
        "operand": "hart=0",
        "pad": "",
    }]


def test_retire_line_preserves_hart_and_memory_metadata():
    rows = _convert(
        "1|7|80000004|00a12023|0|3|gpr=|csr=|mem=80001000:000000aa:1\n")

    assert rows[0]["operand"] == "hart=1;mem=80001000:000000aa:1"


def test_future_memory_write_is_lazily_attached_to_store_retire():
    rows = _convert(
        "0|0|80000000|00a12023|0|3|gpr=|csr=\n"
        "M|0|80001000:000000aa:1\n")

    assert rows[0]["operand"] == "hart=0;mem=80001000:000000aa:1"


def test_past_memory_write_is_attached_to_next_store_retire():
    rows = _convert(
        "M|0|80001000:000000aa:1\n"
        "0|0|80000000|00000013|0|3|gpr=|csr=\n"
        "0|1|80000004|00a12023|0|3|gpr=|csr=\n")

    assert rows[0]["operand"] == "hart=0"
    assert rows[1]["operand"] == "hart=0;mem=80001000:000000aa:1"


def test_memory_write_does_not_attach_to_non_store_retire():
    rows = _convert(
        "0|0|80000000|00000013|0|3|gpr=|csr=\n"
        "M|0|80001000:000000aa:1\n"
        "0|1|80000004|00a12023|0|3|gpr=|csr=\n")

    assert rows[0]["operand"] == "hart=0"
    assert rows[1]["operand"] == "hart=0;mem=80001000:000000aa:1"


def test_atomic_memory_write_attaches_to_sc_not_later_store():
    rows = _convert(
        "0|0|80000000|1002a32f|0|3|gpr=x6:00000000|csr=\n"
        "M|0|f0040000:00000001:f\n"
        "0|1|80000004|1872ae2f|0|3|gpr=x28:00000000|csr=\n"
        "0|2|80000008|0062a023|0|3|gpr=|csr=\n"
        "M|0|d0580000:000000ff:f\n")

    assert rows[0]["operand"] == "hart=0"
    assert rows[1]["operand"] == "hart=0;mem=f0040000:00000001:f"
    assert rows[2]["operand"] == "hart=0;mem=d0580000:000000ff:f"


def test_riscv_dv_test_pass_mailbox_stops_trace_before_epilogue_retire():
    rows = _convert(
        "0|0|80000000|00a12023|0|3|gpr=|csr=\n"
        "M|0|d0580000:00000002:f\n"
        "0|1|80000004|34151073|0|3|gpr=|csr=341:00000004\n")

    assert len(rows) == 1
    assert rows[0]["operand"] == "hart=0;mem=d0580000:00000002:f"


def test_past_riscv_dv_test_pass_mailbox_stops_trace_at_matching_store():
    rows = _convert(
        "M|0|d0580000:00000002:f\n"
        "0|0|80000000|00a12023|0|3|gpr=|csr=\n"
        "0|1|80000004|34151073|0|3|gpr=|csr=341:00000004\n")

    assert len(rows) == 1
    assert rows[0]["operand"] == "hart=0;mem=d0580000:00000002:f"


def test_riscv_dv_signature_words_with_pass_low_byte_do_not_stop_trace():
    rows = _convert(
        "0|0|80000000|00a12023|0|3|gpr=|csr=\n"
        "M|0|d0580000:00030002:f\n"
        "0|1|80000004|00000013|0|3|gpr=|csr=\n")

    assert len(rows) == 2
    assert rows[0]["operand"] == "hart=0;mem=d0580000:00030002:f"
    assert rows[1]["pc"] == "80000004"


def test_memory_write_queues_are_hart_specific():
    rows = _convert(
        "M|1|80001000:000000bb:1\n"
        "0|0|80000000|00a12023|0|3|gpr=|csr=\n"
        "1|1|80000004|00a12023|0|3|gpr=|csr=\n"
        "M|0|80001004:000000aa:1\n")

    assert rows[0]["operand"] == "hart=0;mem=80001004:000000aa:1"
    assert rows[1]["operand"] == "hart=1;mem=80001000:000000bb:1"


def test_past_csr_write_is_attached_to_next_csr_retire():
    rows = _convert(
        "C|0|301:40101105\n"
        "0|0|8000000e|10550513|0|3|gpr=x10:40001105|csr=\n"
        "0|1|80000012|30151073|0|3|gpr=|csr=\n")

    assert rows[0]["csr"] == ""
    assert rows[1]["csr"] == "301:40101105"


def test_future_csr_write_is_lazily_attached_to_csr_retire():
    rows = _convert(
        "0|0|80000012|30151073|0|3|gpr=|csr=\n"
        "C|0|301:40101105\n")

    assert rows[0]["csr"] == "301:40101105"


def test_csr_write_queues_are_hart_specific():
    rows = _convert(
        "C|1|301:00000001\n"
        "0|0|80000012|30151073|0|3|gpr=|csr=\n"
        "1|1|80000012|30151073|0|3|gpr=|csr=\n"
        "C|0|301:00000000\n")

    assert rows[0]["csr"] == "301:00000000"
    assert rows[1]["csr"] == "301:00000001"


def test_csr_read_does_not_consume_pending_csr_write():
    rows = _convert(
        "0|0|80000000|30002573|0|3|gpr=x10:00001800|csr=\n"
        "C|0|320:00000000\n"
        "0|1|80000004|32029073|0|3|gpr=|csr=\n")

    assert rows[0]["csr"] == ""
    assert rows[1]["csr"] == "320:00000000"


def test_pending_csr_write_matches_by_csr_address_not_fifo_order():
    rows = _convert(
        "C|0|320:00000000\n"
        "0|0|80000000|30151073|0|3|gpr=|csr=\n"
        "C|0|301:40001105\n"
        "0|1|80000004|32029073|0|3|gpr=|csr=\n")

    assert rows[0]["csr"] == "301:40001105"
    assert rows[1]["csr"] == "320:00000000"


def test_future_csr_event_matches_waiting_row_by_address():
    rows = _convert(
        "0|0|80000000|30151073|0|3|gpr=|csr=\n"
        "0|1|80000004|32029073|0|3|gpr=|csr=\n"
        "C|0|320:00000000\n"
        "C|0|301:40001105\n")

    assert rows[0]["csr"] == "301:40001105"
    assert rows[1]["csr"] == "320:00000000"


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


def test_long_delay_div_writeback_still_matches_retire():
    rows = _convert(
        "0|0|80000000|025342b3|0|3|gpr=|csr=\n"
        + "".join(
            "0|{}|800001{:02x}|00000013|0|3|gpr=|csr=\n".format(i, i * 4)
            for i in range(rvvi_trace_to_trace_csv.ASYNC_LOOKAHEAD_RETIRES - 1))
        +
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


def test_tagged_div_writeback_matches_exact_retire():
    rows = _convert(
        "0|0|80000000|025342b3|0|3|gpr=|csr=|tag=div:1\n"
        "0|1|80000004|025342b3|0|3|gpr=|csr=|tag=div:2\n"
        "A|0|div|x5:00000002|tag=2\n"
        "A|0|div|x5:00000001|tag=1\n")

    assert rows[0]["gpr"] == "t0:00000001"
    assert rows[1]["gpr"] == "t0:00000002"


def test_mismatched_load_tags_do_not_cross_attach():
    rows = _convert(
        "0|0|80000000|00032283|0|3|gpr=|csr=|tag=load:1\n"
        "A|0|load|x5:00000001|tag=2\n"
        "0|1|80000004|00432283|0|3|gpr=|csr=|tag=load:2\n")

    assert rows[0]["gpr"] == ""
    assert rows[1]["gpr"] == "t0:00000001"


def test_load_writeback_falls_back_by_rd_when_existing_tag_queue_has_wrong_rd():
    rows = _convert(
        "0|0|80000000|00032c03|0|3|gpr=|csr=|tag=load:3\n"
        "0|1|80000004|00032703|0|3|gpr=|csr=|tag=load:4\n"
        "0|2|80000008|00032803|0|3|gpr=|csr=|tag=load:5\n"
        "A|0|load|x24:ffffffee\n"
        "A|0|load|x14:000000ee|tag=3\n"
        "A|0|load|x16:00004eee|tag=4\n")

    assert rows[0]["gpr"] == "s8:ffffffee"
    assert rows[1]["gpr"] == "a4:000000ee"
    assert rows[2]["gpr"] == "a6:00004eee"


def test_untagged_load_writeback_is_not_attached_when_rd_is_ambiguous():
    rows = _convert(
        "0|0|80000000|00032183|0|3|gpr=|csr=\n"
        "0|1|80000004|00432183|0|3|gpr=|csr=\n"
        "A|0|load|x3:0000b811\n")

    assert rows[0]["gpr"] == ""
    assert rows[1]["gpr"] == ""


def test_younger_gpr_write_marks_older_pending_async_write_suppressed():
    rows = _convert(
        "0|0|80000000|00032a03|0|3|gpr=|csr=\n"
        "0|1|80000004|00000a13|0|3|gpr=x20:00000000|csr=\n")

    assert rows[0]["gpr"] == ""
    assert "suppress_gpr=s4" in rows[0]["operand"]
    assert rows[1]["gpr"] == "s4:00000000"


def test_late_tagged_load_writeback_matches_exact_retire_after_younger_gpr_write():
    rows = _convert(
        "0|0|80000000|00032183|0|3|gpr=|csr=|tag=load:42\n"
        "0|1|80000004|024e11b3|0|3|gpr=x3:00000000|csr=\n"
        "0|2|80000008|00432183|0|3|gpr=|csr=|tag=load:94\n"
        "A|0|load|x3:0000b811|tag=42\n"
        "A|0|load|x3:00000000|tag=94\n")

    assert rows[0]["gpr"] == "gp:0000b811"
    assert "suppress_gpr" not in rows[0]["operand"]
    assert rows[1]["gpr"] == "gp:00000000"
    assert rows[2]["gpr"] == "gp:00000000"


def test_late_exact_load_tag_is_not_transferred_to_younger_same_rd_load():
    rows = _convert(
        "0|0|80000000|00218283|0|3|gpr=|csr=|tag=load:543\n"
        "0|1|80000004|00e1c283|0|3|gpr=|csr=|tag=load:544\n"
        "0|2|80000008|00ee72b3|0|3|gpr=x5:00000072|csr=\n"
        "0|3|8000000c|00f18283|0|3|gpr=|csr=|tag=load:545\n"
        "A|0|load|x5:0000002d|tag=543\n"
        "A|0|load|x5:000000c8|tag=544\n"
        "A|0|load|x5:ffffffb4|tag=545\n")

    assert rows[0]["gpr"] == "t0:0000002d"
    assert rows[1]["gpr"] == "t0:000000c8"
    assert rows[2]["gpr"] == "t0:00000072"
    assert rows[3]["gpr"] == "t0:ffffffb4"
    assert "suppress_gpr" not in rows[0]["operand"]


def test_tagged_load_writeback_rejects_wrong_destination_register():
    rows = _convert(
        "0|0|80000000|00032283|0|3|gpr=|csr=|tag=load:1\n"
        "A|0|load|x28:00000001|tag=1\n")

    assert rows[0]["gpr"] == ""


def test_adapter_load_retire_tag_uses_hardware_retire_tag_before_rd_fallback():
    adapter = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
               "eh2_rvvi_adapter.sv").read_text()
    task_start = adapter.index("task automatic dump_retire_tag")
    task_end = adapter.index("task automatic dump_div_retire_tag")
    task_body = adapter[task_start:task_end]

    assert "nb_load_retire_tag_valid[h][r]" in task_body
    assert "entry.hw_tag = nb_load_retire_tag[h][r]" in task_body
    assert (task_body.index("nb_load_retire_tag_valid[h][r]") <
            task_body.index("foreach (unretired_load_q[h][i])"))


def test_adapter_load_async_emit_uses_exact_match_even_when_write_port_cancels():
    adapter = (SCRIPT_DIR.parent / "common" / "rvvi_agent" /
               "eh2_rvvi_adapter.sv").read_text()
    task_start = adapter.index("task automatic dump_async_wb")
    task_end = adapter.index("always @(posedge clk)")
    task_body = adapter[task_start:task_end]

    assert "if (found) begin" in task_body
    assert "end else if (nb_load_wen[h] && nb_load_waddr[h] != 5'd0) begin" in task_body
    assert "#DBG_LOAD_WB" not in task_body
    assert "rvvi_trace_debug" not in adapter


def test_tb_delays_load_retire_tag_to_trace_wb1_stage():
    tb_top = (SCRIPT_DIR.parent / "tb" / "core_eh2_tb_top.sv").read_text(
        encoding="utf-8")

    assert "nb_load_retire_tag_valid_wb1" in tb_top
    assert "nb_load_retire_tag_wb1" in tb_top
    assert (tb_top.index("always_ff @(posedge core_clk or negedge rst_l)") <
            tb_top.index("assign dut_probe_intf.nb_load_retire_tag_valid"))


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

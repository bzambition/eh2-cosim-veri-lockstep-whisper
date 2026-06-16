import csv
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import trace_compare_full


HEADER = ["pc", "instr", "gpr", "csr", "binary", "mode", "instr_str",
          "operand", "pad"]


def _write_csv(path: Path, rows):
    with path.open("w", encoding="utf-8", newline="") as fd:
        writer = csv.DictWriter(fd, fieldnames=HEADER)
        writer.writeheader()
        for row in rows:
            data = {field: "" for field in HEADER}
            data.update(row)
            writer.writerow(data)


def _compare(tmp_path, dut_rows, ref_rows, masks=None):
    dut = tmp_path / "dut.csv"
    ref = tmp_path / "ref.csv"
    _write_csv(dut, dut_rows)
    _write_csv(ref, ref_rows)
    return trace_compare_full.compare_trace_csv(
        str(dut), str(ref), "dut", "ref", csr_masks=masks or {})


def test_full_compare_passes_pc_gpr_csr_and_memory(tmp_path):
    rows = [{
        "pc": "80000000",
        "binary": "00a12023",
        "gpr": "ra:80000004",
        "csr": "300:00001800;7c0:00000002",
        "pad": "hart=0;mem=80001000:000000aa:1",
    }]

    result = _compare(tmp_path, rows, rows)

    assert result.passed
    assert result.matched == 1


def test_full_compare_catches_pc_mismatch_without_gpr_change(tmp_path):
    result = _compare(
        tmp_path,
        [{"pc": "80000000", "binary": "00000013"}],
        [{"pc": "80000004", "binary": "00000013"}],
    )

    assert not result.passed
    assert "PC mismatch" in result.mismatches[0]


def test_full_compare_catches_csr_mismatch(tmp_path):
    result = _compare(
        tmp_path,
        [{"pc": "80000000", "csr": "300:00001800"}],
        [{"pc": "80000000", "csr": "300:00000000"}],
    )

    assert not result.passed
    assert "CSR 300 mismatch" in result.mismatches[0]


def test_full_compare_masks_csr_from_external_config(tmp_path):
    result = _compare(
        tmp_path,
        [{"pc": "80000000", "csr": "b00:00000001"}],
        [{"pc": "80000000", "csr": "b00:00000002"}],
        masks={"b00": 0},
    )

    assert result.passed


def test_full_compare_catches_memory_data_mismatch(tmp_path):
    result = _compare(
        tmp_path,
        [{"pc": "80000000", "pad": "hart=0;mem=80001000:000000aa:1"}],
        [{"pc": "80000000", "pad": "hart=0;mem=80001000:000000bb:1"}],
    )

    assert not result.passed
    assert "MEM bytes mismatch" in result.mismatches[0]


def test_full_compare_matches_aggregate_store_against_byte_writes(tmp_path):
    result = _compare(
        tmp_path,
        [{"pc": "80000000",
          "pad": "hart=0;mem=80001002:80000000:f"}],
        [{"pc": "80000000",
          "pad": "hart=0;mem=80001002:00000000:1;"
                 "mem=80001003:00000000:1;"
                 "mem=80001004:00000000:1;"
                 "mem=80001005:00000080:1"}],
    )

    assert result.passed


def test_full_compare_masks_unwritten_memory_bytes(tmp_path):
    result = _compare(
        tmp_path,
        [{"pc": "80000000", "pad": "hart=0;mem=80001000:ffff00aa:1"}],
        [{"pc": "80000000", "pad": "hart=0;mem=80001000:000000aa:1"}],
    )

    assert result.passed


def test_full_compare_catches_hart_mismatch(tmp_path):
    result = _compare(
        tmp_path,
        [{"pc": "80000000", "pad": "hart=0"}],
        [{"pc": "80000000", "pad": "hart=1"}],
    )

    assert not result.passed
    assert "hart mismatch" in result.mismatches[0]


def test_full_compare_honors_explicit_suppressed_gpr_marker(tmp_path):
    result = _compare(
        tmp_path,
        [{"pc": "80000000", "binary": "00032a03",
          "operand": "hart=0;suppress_gpr=s4"}],
        [{"pc": "80000000", "binary": "00032a03", "gpr": "s4:00000000",
          "operand": "hart=0"}],
    )

    assert result.passed


def test_full_compare_does_not_mask_unsuppressed_gpr_mismatch(tmp_path):
    result = _compare(
        tmp_path,
        [{"pc": "80000000", "binary": "00032a03", "operand": "hart=0"}],
        [{"pc": "80000000", "binary": "00032a03", "gpr": "s4:00000000",
          "operand": "hart=0"}],
    )

    assert not result.passed
    assert "GPR s4 mismatch" in result.mismatches[0]

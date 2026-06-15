#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Convert EH2 RVVI retire dump to riscv-dv trace CSV.

Input records are pipe-delimited and intentionally simple so the SystemVerilog
collector remains a dumb trace source:

  hart|order|pc|insn|trap|mode|gpr=x1:00000001;...|csr=300:...|tag=load:1
  A|hart|div|x5:00000003
  A|hart|load|x6:00000004|tag=1

Async records are lazily consumed by matching load/div retire instructions and
attached to that instruction's CSV row, hiding microarchitectural writeback
latency from trace comparison.
"""

import argparse
import os
import sys
from collections import defaultdict, deque

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
EH2_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(SCRIPT_DIR))))
RISCV_DV_SCRIPTS = os.path.join(EH2_ROOT, "vendor", "google_riscv-dv",
                                "scripts")
ASYNC_LOOKAHEAD_RETIRES = 8
LOAD_WRITEBACK_RETIRES = 256
_OLD_SYS_PATH = list(sys.path)
try:
    sys.path.insert(0, RISCV_DV_SCRIPTS)
    from riscv_trace_csv import RiscvInstructionTraceCsv, RiscvInstructionTraceEntry
    from lib import gpr_to_abi
finally:
    sys.path = _OLD_SYS_PATH


def _norm_hex(value, width=8):
    value = str(value or "").strip().lower()
    if value.startswith("0x"):
        value = value[2:]
    if not value:
        return ""
    return value.zfill(width)[-width:]


def _xreg_to_abi(reg):
    reg = str(reg or "").strip().lower()
    if not reg:
        return ""
    if reg.startswith("x") and reg[1:].isdigit():
        abi = gpr_to_abi(reg)
        return reg if abi == "na" else abi
    return reg


def _parse_updates(field, prefix):
    if not field.startswith(prefix + "="):
        return []
    payload = field.split("=", 1)[1].strip()
    if not payload:
        return []

    updates = []
    for item in payload.split(";"):
        item = item.strip()
        if not item:
            continue
        if ":" not in item:
            raise RuntimeError("Malformed {} update: {}".format(prefix, item))
        name, value = item.split(":", 1)
        updates.append((name.strip(), _norm_hex(value)))
    return updates


def _is_compressed(insn):
    return (insn & 0x3) != 0x3


def _compressed_rd(insn):
    funct3 = (insn >> 13) & 0x7
    quadrant = insn & 0x3
    if quadrant == 0:
        if funct3 in (0, 2):
            return 8 + ((insn >> 2) & 0x7)
    elif quadrant == 1:
        if funct3 in (0, 2, 3):
            return (insn >> 7) & 0x1f
        if funct3 == 1:
            return 1
        if funct3 == 4:
            return 8 + ((insn >> 7) & 0x7)
    elif quadrant == 2:
        if funct3 in (0, 2):
            return (insn >> 7) & 0x1f
        if funct3 == 4:
            if ((insn >> 12) & 1) and (((insn >> 2) & 0x1f) == 0):
                return 1
            if ((insn >> 2) & 0x1f) != 0:
                return (insn >> 7) & 0x1f
    return 0


def _write_rd(insn):
    if _is_compressed(insn):
        return _compressed_rd(insn)
    return (insn >> 7) & 0x1f


def _is_compressed_load(insn):
    if not _is_compressed(insn):
        return False
    funct3 = (insn >> 13) & 0x7
    quadrant = insn & 0x3
    return ((quadrant == 0 and funct3 == 2) or
            (quadrant == 2 and funct3 == 2))


def _is_lr(insn):
    return ((insn & 0x7f) == 0x2f and ((insn >> 27) & 0x1f) == 0x02)


def _is_load(insn):
    return _is_compressed_load(insn) or ((insn & 0x7f) == 0x03) or _is_lr(insn)


def _is_div(insn):
    if _is_compressed(insn):
        return False
    return ((insn & 0x7f) == 0x33 and ((insn >> 25) & 0x7f) == 0x01 and
            ((insn >> 12) & 0x7) in (4, 5, 6, 7))


def _async_source_for(insn):
    if _is_div(insn):
        return "div"
    if _is_load(insn):
        return "load"
    return ""


def _parse_tag(field):
    if not field.startswith("tag="):
        return None
    payload = field.split("=", 1)[1].strip()
    if not payload:
        return None
    if ":" in payload:
        source, tag = payload.split(":", 1)
        return source.strip().lower(), int(tag.strip(), 0)
    return "", int(payload, 0)


def _parse_async(parts):
    if len(parts) < 4:
        raise RuntimeError("Malformed async RVVI trace line: {}".format("|".join(parts)))
    hart = int(parts[1], 0)
    source = parts[2].strip().lower()
    reg, value = parts[3].split(":", 1)
    if not reg.strip().lower().startswith("x"):
        raise RuntimeError("Async writeback must use xN register: {}".format(parts[3]))
    tag = None
    for field in parts[4:]:
        parsed_tag = _parse_tag(field)
        if parsed_tag is not None:
            _tag_source, tag = parsed_tag
    return hart, source, int(reg.strip()[1:], 0), _norm_hex(value), tag


def _parse_retire(parts):
    if len(parts) < 6:
        raise RuntimeError("Malformed retire RVVI trace line: {}".format("|".join(parts)))
    hart = int(parts[0], 0)
    pc = _norm_hex(parts[2])
    insn_text = _norm_hex(parts[3])
    mode = parts[5].strip()
    gpr_updates = []
    csr_updates = []
    async_tag = None
    for field in parts[6:]:
        if field.startswith("gpr="):
            gpr_updates.extend(_parse_updates(field, "gpr"))
        elif field.startswith("csr="):
            csr_updates.extend(_parse_updates(field, "csr"))
        elif field.startswith("tag="):
            async_tag = _parse_tag(field)
    return hart, pc, insn_text, mode, gpr_updates, csr_updates, async_tag


def _entry_from_retire(pc, insn_text, mode, gpr_updates, csr_updates):
    entry = RiscvInstructionTraceEntry()
    entry.pc = pc
    entry.binary = insn_text
    entry.mode = mode

    for reg, value in gpr_updates:
        entry.gpr.append("{}:{}".format(_xreg_to_abi(reg), value))
    for csr, value in csr_updates:
        entry.csr.append("{}:{}".format(csr.lower().replace("0x", ""), value))
    return entry


def _pending_key(hart, insn_text):
    insn = int(insn_text, 16) if insn_text else 0
    source = _async_source_for(insn)
    rd = _write_rd(insn)
    if not source or rd == 0:
        return None
    return hart, source, rd


def _tagged_key(hart, source, tag):
    if tag is None:
        return None
    return hart, source, "tag", tag


def _patch_entry_gpr(entry, rd, value):
    entry.gpr = ["{}:{}".format(_xreg_to_abi("x{}".format(rd)), value)]


def _flush_ready(trace_csv, ordered_entries):
    while ordered_entries and not ordered_entries[0]["waiting"]:
        entry = ordered_entries.popleft()["entry"]
        trace_csv.write_trace_entry(entry)


def _flush_all(trace_csv, ordered_entries):
    while ordered_entries:
        entry = ordered_entries.popleft()["entry"]
        trace_csv.write_trace_entry(entry)


def _age_pending_values(pending_values):
    for key in list(pending_values.keys()):
        aged = deque()
        for rd, value, ttl in pending_values[key]:
            if ttl > 1:
                aged.append((rd, value, ttl - 1))
        if aged:
            pending_values[key] = aged
        else:
            del pending_values[key]


def _age_pending_rows(ordered_entries):
    for row in ordered_entries:
        if not row["waiting"]:
            continue
        if row["ttl"] is None:
            continue
        if row["ttl"] > 1:
            row["ttl"] -= 1
        else:
            row["waiting"] = False
            row["ttl"] = 0


def _consume_pending_value(pending_values, key):
    q = pending_values[key]
    if not q:
        return None
    rd, value, _ttl = q.popleft()
    if not q:
        del pending_values[key]
    return rd, value


def convert_rvvi_trace_fd(trace_fd, csv_fd):
    trace_csv = RiscvInstructionTraceCsv(csv_fd)
    trace_csv.start_new_trace()
    pending_async = defaultdict(deque)
    pending_values = defaultdict(deque)
    ordered_entries = deque()
    count = 0
    for raw_line in trace_fd:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if parts[0] == "A":
            hart, source, rd, value, async_tag = _parse_async(parts)
            key = _tagged_key(hart, source, async_tag) or (hart, source, rd)
            while pending_async[key]:
                row = pending_async[key].popleft()
                if not row["waiting"]:
                    continue
                entry = row["entry"]
                _patch_entry_gpr(entry, rd, value)
                row["waiting"] = False
                row["ttl"] = 0
                _flush_ready(trace_csv, ordered_entries)
                break
            else:
                pending_values[key].append(
                    (rd, value, ASYNC_LOOKAHEAD_RETIRES))
            continue

        hart, pc, insn_text, mode, gpr_updates, csr_updates, async_tag = _parse_retire(parts)
        _age_pending_values(pending_values)
        _age_pending_rows(ordered_entries)
        entry = _entry_from_retire(pc, insn_text, mode, gpr_updates,
                                   csr_updates)
        row = {"entry": entry, "waiting": False, "ttl": 0}
        if not gpr_updates:
            key = _pending_key(hart, insn_text)
            if key:
                source = key[1]
                tagged = _tagged_key(hart, source, async_tag[1]) if async_tag else None
                if tagged:
                    key = tagged
                pending_value = _consume_pending_value(pending_values, key)
                if pending_value:
                    rd, value = pending_value
                    _patch_entry_gpr(entry, rd, value)
                else:
                    row["waiting"] = True
                    row["ttl"] = (ASYNC_LOOKAHEAD_RETIRES
                                  if key[1] == "div"
                                  else LOAD_WRITEBACK_RETIRES)
                    pending_async[key].append(row)
        ordered_entries.append(row)
        _flush_ready(trace_csv, ordered_entries)
        count += 1

    _flush_all(trace_csv, ordered_entries)

    if count == 0:
        raise RuntimeError("No retire records found in RVVI trace")
    return count


def convert_rvvi_trace(trace_path, csv_path):
    with open(trace_path, "r", encoding="utf-8") as trace_fd:
        with open(csv_path, "w", encoding="utf-8", newline="") as csv_fd:
            return convert_rvvi_trace_fd(trace_fd, csv_fd)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, help="Input RVVI trace dump")
    parser.add_argument("--csv", required=True, help="Output riscv-dv trace CSV")
    args = parser.parse_args()

    convert_rvvi_trace(args.log, args.csv)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as err:
        sys.stderr.write("Error: {}\n".format(err))
        sys.exit(1)

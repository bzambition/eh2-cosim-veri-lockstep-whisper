#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Convert EH2 RVVI retire dump to riscv-dv trace CSV.

Input records are pipe-delimited and intentionally simple so the SystemVerilog
collector remains a dumb trace source:

  hart|order|pc|insn|trap|mode|gpr=x1:00000001;...|csr=300:...|mem=80001000:000000aa:1|tag=load:1
  A|hart|div|x5:00000003
  A|hart|load|x6:00000004|tag=1
  C|hart|301:40101105
  M|hart|80001000:000000aa:1

Async records are lazily consumed by matching load/div retire instructions and
attached to that instruction's CSV row, hiding microarchitectural writeback
latency from trace comparison.

Memory records are similarly attached to store retire rows so bus/writeback
timing does not leak into the architectural trace.
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
ASYNC_LOOKAHEAD_RETIRES = 256
LOAD_WRITEBACK_RETIRES = 256
MEM_WRITE_RETIRES = 256
CSR_WRITE_RETIRES = 256
MAILBOX_ADDR = "d0580000"
RISCV_DV_TEST_PASS = "00000002"
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


def _is_atomic_store(insn):
    if (insn & 0x7f) != 0x2f or ((insn >> 12) & 0x7) != 2:
        return False
    # LR.W is the atomic load-only operation. SC.W and AMO* all have an
    # architectural memory write that may arrive as a separate RVVI M record.
    return ((insn >> 27) & 0x1f) != 0x02


def _is_load(insn):
    return _is_compressed_load(insn) or ((insn & 0x7f) == 0x03) or _is_lr(insn)


def _is_store(insn):
    if _is_compressed(insn):
        funct3 = (insn >> 13) & 0x7
        quadrant = insn & 0x3
        return ((quadrant == 0 and funct3 == 6) or
                (quadrant == 2 and funct3 == 6))
    return (insn & 0x7f) == 0x23 or _is_atomic_store(insn)


def _is_csr_write_insn(insn):
    if _is_compressed(insn) or (insn & 0x7f) != 0x73:
        return False
    funct3 = (insn >> 12) & 0x7
    rs1_or_uimm = (insn >> 15) & 0x1f
    if funct3 in (1, 5):  # CSRRW/CSRRWI always write the CSR.
        return True
    if funct3 in (2, 3, 6, 7):  # CSRRS/CSRRC write only with non-zero rs1/uimm.
        return rs1_or_uimm != 0
    return False


def _csr_addr(insn):
    if _is_compressed(insn) or (insn & 0x7f) != 0x73:
        return None
    return "{:03x}".format((insn >> 20) & 0xfff)


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


def _parse_mem_write(parts):
    if len(parts) != 3:
        raise RuntimeError("Malformed memory RVVI trace line: {}".format("|".join(parts)))
    hart = int(parts[1], 0)
    fields = parts[2].split(":")
    if len(fields) != 3:
        raise RuntimeError("Malformed memory write: {}".format(parts[2]))
    addr, data, be = fields
    return hart, "{}:{}:{}".format(_norm_hex(addr), _norm_hex(data),
                                   be.strip().lower().replace("0x", ""))


def _is_riscv_dv_test_pass_mem_write(mem_write):
    fields = str(mem_write or "").split(":")
    if len(fields) < 2:
        return False
    addr, data = fields[0], fields[1]
    return _norm_hex(addr) == MAILBOX_ADDR and _norm_hex(data) == RISCV_DV_TEST_PASS


def _parse_csr_write(parts):
    if len(parts) != 3:
        raise RuntimeError("Malformed CSR RVVI trace line: {}".format("|".join(parts)))
    hart = int(parts[1], 0)
    if ":" not in parts[2]:
        raise RuntimeError("Malformed CSR write: {}".format(parts[2]))
    csr, value = parts[2].split(":", 1)
    csr_addr = csr.strip().lower().replace("0x", "")
    return hart, csr_addr, "{}:{}".format(csr_addr, _norm_hex(value))


def _parse_mem(field):
    if not field.startswith("mem="):
        return []
    payload = field.split("=", 1)[1].strip()
    if not payload:
        return []
    writes = []
    for item in payload.split(";"):
        item = item.strip()
        if not item:
            continue
        fields = item.split(":")
        if len(fields) != 3:
            raise RuntimeError("Malformed memory write: {}".format(item))
        addr, data, be = fields
        writes.append("{}:{}:{}".format(_norm_hex(addr), _norm_hex(data),
                                        be.strip().lower().replace("0x", "")))
    return writes


def _parse_retire(parts):
    if len(parts) < 6:
        raise RuntimeError("Malformed retire RVVI trace line: {}".format("|".join(parts)))
    hart = int(parts[0], 0)
    pc = _norm_hex(parts[2])
    insn_text = _norm_hex(parts[3])
    mode = parts[5].strip()
    gpr_updates = []
    csr_updates = []
    mem_writes = []
    async_tag = None
    for field in parts[6:]:
        if field.startswith("gpr="):
            gpr_updates.extend(_parse_updates(field, "gpr"))
        elif field.startswith("csr="):
            csr_updates.extend(_parse_updates(field, "csr"))
        elif field.startswith("mem="):
            mem_writes.extend(_parse_mem(field))
        elif field.startswith("tag="):
            async_tag = _parse_tag(field)
    return hart, pc, insn_text, mode, gpr_updates, csr_updates, mem_writes, async_tag


def _entry_from_retire(hart, pc, insn_text, mode, gpr_updates, csr_updates,
                       mem_writes):
    entry = RiscvInstructionTraceEntry()
    entry.pc = pc
    entry.binary = insn_text
    entry.mode = mode
    pad_items = ["hart={}".format(hart)]

    for reg, value in gpr_updates:
        entry.gpr.append("{}:{}".format(_xreg_to_abi(reg), value))
    for csr, value in csr_updates:
        entry.csr.append("{}:{}".format(csr.lower().replace("0x", ""), value))
    for mem in mem_writes:
        pad_items.append("mem={}".format(mem))
    entry.operand = ";".join(pad_items)
    return entry


def _append_entry_mem(entry, mem_write):
    operand = entry.operand or ""
    if operand:
        entry.operand = "{};mem={}".format(operand, mem_write)
    else:
        entry.operand = "mem={}".format(mem_write)


def _append_entry_csr(entry, csr_write):
    entry.csr.append(csr_write)


def _append_entry_suppress_gpr(entry, rd):
    reg = _xreg_to_abi("x{}".format(rd))
    operand = entry.operand or ""
    token = "suppress_gpr={}".format(reg)
    entry.operand = "{};{}".format(operand, token) if operand else token


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


def _row_accepts_async_rd(row, rd):
    expected_rd = row.get("rd")
    return expected_rd is None or expected_rd == rd


def _row_waiting(row):
    return row["waiting"] or row["waiting_mem"] or row["waiting_csr"]


def _finish_suppressed_async_row(row):
    if row["waiting"] and row.get("suppress_candidate"):
        row["waiting"] = False
        row["ttl"] = 0
        _append_entry_suppress_gpr(row["entry"], row["rd"])
        return True
    return False


def _flush_ready(trace_csv, ordered_entries):
    while ordered_entries and not _row_waiting(ordered_entries[0]):
        entry = ordered_entries.popleft()["entry"]
        trace_csv.write_trace_entry(entry)


def _flush_all(trace_csv, ordered_entries):
    while ordered_entries:
        row = ordered_entries.popleft()
        _finish_suppressed_async_row(row)
        entry = row["entry"]
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
        if row["waiting"]:
            if row["ttl"] is not None:
                if row["ttl"] > 1:
                    row["ttl"] -= 1
                else:
                    if not _finish_suppressed_async_row(row):
                        row["waiting"] = False
                        row["ttl"] = 0
        if row["waiting_mem"]:
            if row["mem_ttl"] > 1:
                row["mem_ttl"] -= 1
            else:
                row["waiting_mem"] = False
                row["mem_ttl"] = 0
        if row["waiting_csr"]:
            if row["csr_ttl"] > 1:
                row["csr_ttl"] -= 1
            else:
                row["waiting_csr"] = False
                row["csr_ttl"] = 0


def _consume_pending_value(pending_values, key):
    q = pending_values[key]
    if not q:
        return None
    rd, value, _ttl = q.popleft()
    if not q:
        del pending_values[key]
    return rd, value


def _consume_waiting_async_row(pending_async, key, rd):
    q = pending_async.get(key)
    if not q:
        return None, False
    kept = deque()
    matches = []
    had_key = False
    while q:
        row = q.popleft()
        had_key = True
        if (row["waiting"] and not row.get("suppress_candidate") and
                _row_accepts_async_rd(row, rd)):
            matches.append(row)
        else:
            kept.append(row)
    matched = None
    if len(matches) == 1 or (len(key) >= 4 and key[2] == "tag" and matches):
        matched = matches[0]
        kept.extend(matches[1:])
    else:
        kept.extend(matches)
    if kept:
        pending_async[key] = kept
    else:
        del pending_async[key]
    return matched, had_key


def _consume_exact_async_row(pending_async, key, rd):
    q = pending_async.get(key)
    if not q:
        return None, False
    kept = deque()
    matched = None
    had_key = False
    while q:
        row = q.popleft()
        had_key = True
        if matched is None and row["waiting"] and _row_accepts_async_rd(row, rd):
            matched = row
        elif row["waiting"]:
            kept.append(row)
    if kept:
        pending_async[key] = kept
    else:
        del pending_async[key]
    return matched, had_key


def _remove_pending_async_row(pending_async, target):
    for key in list(pending_async.keys()):
        kept = deque()
        while pending_async[key]:
            row = pending_async[key].popleft()
            if row is not target and row["waiting"]:
                kept.append(row)
        if kept:
            pending_async[key] = kept
        else:
            del pending_async[key]


def _find_waiting_async_row_by_rd(ordered_entries, hart, source, rd):
    matches = []
    for row in ordered_entries:
        if (row["waiting"] and not row.get("suppress_candidate") and
                row["hart"] == hart and row["source"] == source and
                _row_accepts_async_rd(row, rd)):
            matches.append(row)
    if len(matches) == 1:
        return matches[0]
    return None


def _find_waiting_async_row_by_rd_in_queues(pending_async, hart, source, rd):
    matches = []
    for queue in pending_async.values():
        for row in queue:
            if (row["waiting"] and not row.get("suppress_candidate") and
                    row["hart"] == hart and row["source"] == source and
                    _row_accepts_async_rd(row, rd)):
                matches.append(row)
    if len(matches) == 1:
        return matches[0]
    return None


def _select_async_row_for_writeback(pending_async, ordered_entries, hart,
                                    source, rd, async_tag):
    had_key = False
    if async_tag is not None:
        key = _tagged_key(hart, source, async_tag)
        exact_row, had_key = _consume_exact_async_row(pending_async, key, rd)
        if exact_row is not None:
            exact_row["suppress_candidate"] = False
            return exact_row, had_key

    key = (hart, source, rd)
    row, rd_had_key = _consume_waiting_async_row(pending_async, key, rd)
    had_key = had_key or rd_had_key
    if row is None and (async_tag is None or had_key):
        row = _find_waiting_async_row_by_rd(ordered_entries, hart, source, rd)
    if row is None and had_key:
        row = _find_waiting_async_row_by_rd_in_queues(
            pending_async, hart, source, rd)
        if row is not None:
            _remove_pending_async_row(pending_async, row)
    return row, had_key


def _suppress_older_async_rows(ordered_entries, pending_async, hart, rd):
    for row in ordered_entries:
        if (row["waiting"] and row["hart"] == hart and row["rd"] == rd and
                row["source"] in ("load", "div") and
                row.get("async_tag") is None):
            row["suppress_candidate"] = True
    for queue in pending_async.values():
        for row in queue:
            if (row["waiting"] and row["hart"] == hart and row["rd"] == rd and
                    row["source"] in ("load", "div") and
                    row.get("async_tag") is None):
                row["suppress_candidate"] = True


def _consume_pending_mem(pending_mem, hart):
    q = pending_mem[hart]
    if not q:
        return None
    mem_write, _ttl = q.popleft()
    if not q:
        del pending_mem[hart]
    return mem_write


def _age_pending_mem(pending_mem):
    for hart in list(pending_mem.keys()):
        aged = deque()
        for mem_write, ttl in pending_mem[hart]:
            if ttl > 1:
                aged.append((mem_write, ttl - 1))
        if aged:
            pending_mem[hart] = aged
        else:
            del pending_mem[hart]


def _consume_pending_csr(pending_csr, key):
    q = pending_csr[key]
    if not q:
        return None
    csr_write, _ttl = q.popleft()
    if not q:
        del pending_csr[key]
    return csr_write


def _age_pending_csr(pending_csr):
    for key in list(pending_csr.keys()):
        aged = deque()
        for csr_write, ttl in pending_csr[key]:
            if ttl > 1:
                aged.append((csr_write, ttl - 1))
        if aged:
            pending_csr[key] = aged
        else:
            del pending_csr[key]


def convert_rvvi_trace_fd(trace_fd, csv_fd):
    trace_csv = RiscvInstructionTraceCsv(csv_fd)
    trace_csv.start_new_trace()
    pending_async = defaultdict(deque)
    pending_values = defaultdict(deque)
    pending_mem = defaultdict(deque)
    pending_mem_rows = defaultdict(deque)
    pending_csr = defaultdict(deque)
    pending_csr_rows = defaultdict(deque)
    ordered_entries = deque()
    count = 0
    stop_after_flush = False
    for raw_line in trace_fd:
        if stop_after_flush:
            break
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if parts[0] == "A":
            hart, source, rd, value, async_tag = _parse_async(parts)
            row, had_key = _select_async_row_for_writeback(
                pending_async, ordered_entries, hart, source, rd, async_tag)
            if row is not None:
                entry = row["entry"]
                _patch_entry_gpr(entry, rd, value)
                row["waiting"] = False
                row["ttl"] = 0
                _flush_ready(trace_csv, ordered_entries)
            else:
                key = _tagged_key(hart, source, async_tag) or (hart, source, rd)
                pending_values[key].append(
                    (rd, value, ASYNC_LOOKAHEAD_RETIRES))
            continue
        if parts[0] == "M":
            hart, mem_write = _parse_mem_write(parts)
            is_test_pass = _is_riscv_dv_test_pass_mem_write(mem_write)
            while pending_mem_rows[hart]:
                row = pending_mem_rows[hart].popleft()
                if not row["waiting_mem"]:
                    continue
                _append_entry_mem(row["entry"], mem_write)
                row["waiting_mem"] = False
                row["mem_ttl"] = 0
                _flush_ready(trace_csv, ordered_entries)
                if is_test_pass:
                    _flush_all(trace_csv, ordered_entries)
                    stop_after_flush = True
                break
            else:
                pending_mem[hart].append((mem_write, MEM_WRITE_RETIRES))
            continue
        if parts[0] == "C":
            hart, csr_addr, csr_write = _parse_csr_write(parts)
            csr_key = (hart, csr_addr)
            while pending_csr_rows[csr_key]:
                row = pending_csr_rows[csr_key].popleft()
                if not row["waiting_csr"]:
                    continue
                _append_entry_csr(row["entry"], csr_write)
                row["waiting_csr"] = False
                row["csr_ttl"] = 0
                _flush_ready(trace_csv, ordered_entries)
                break
            else:
                pending_csr[csr_key].append((csr_write, CSR_WRITE_RETIRES))
            continue

        hart, pc, insn_text, mode, gpr_updates, csr_updates, mem_writes, async_tag = _parse_retire(parts)
        _age_pending_values(pending_values)
        _age_pending_mem(pending_mem)
        _age_pending_csr(pending_csr)
        _age_pending_rows(ordered_entries)
        entry = _entry_from_retire(hart, pc, insn_text, mode, gpr_updates,
                                   csr_updates, mem_writes)
        row = {
            "entry": entry,
            "hart": hart,
            "waiting": False,
            "ttl": 0,
            "rd": None,
            "source": "",
            "async_tag": None,
            "suppress_candidate": False,
            "waiting_mem": False,
            "mem_ttl": 0,
            "waiting_csr": False,
            "csr_ttl": 0,
        }
        insn_value = int(insn_text, 16) if insn_text else 0
        for reg, _value in gpr_updates:
            reg_name = reg.strip().lower()
            if reg_name.startswith("x") and reg_name[1:].isdigit():
                rd = int(reg_name[1:], 0)
                if rd != 0:
                    _suppress_older_async_rows(
                        ordered_entries, pending_async, hart, rd)
        if not csr_updates and _is_csr_write_insn(insn_value):
            csr_key = (hart, _csr_addr(insn_value))
            pending_write = _consume_pending_csr(pending_csr, csr_key)
            if pending_write:
                _append_entry_csr(entry, pending_write)
            else:
                row["waiting_csr"] = True
                row["csr_ttl"] = CSR_WRITE_RETIRES
                pending_csr_rows[csr_key].append(row)
        if not mem_writes and _is_store(insn_value):
            pending_write = _consume_pending_mem(pending_mem, hart)
            if pending_write:
                _append_entry_mem(entry, pending_write)
                if _is_riscv_dv_test_pass_mem_write(pending_write):
                    stop_after_flush = True
            else:
                row["waiting_mem"] = True
                row["mem_ttl"] = MEM_WRITE_RETIRES
                pending_mem_rows[hart].append(row)
        if not gpr_updates:
            key = _pending_key(hart, insn_text)
            if key:
                source = key[1]
                row["rd"] = key[2]
                row["source"] = source
                tagged = _tagged_key(hart, source, async_tag[1]) if async_tag else None
                if tagged:
                    row["async_tag"] = async_tag[1]
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
        if stop_after_flush:
            _flush_all(trace_csv, ordered_entries)
            break

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

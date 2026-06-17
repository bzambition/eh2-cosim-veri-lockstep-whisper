#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Core-agnostic offline architectural trace comparison.

The riscv-dv comparator used by upstream flows only checks GPR updates.  This
comparator is intentionally core-agnostic: it consumes generic trace CSV
columns and optional metadata in the standard ``pad`` column:

  pc,instr,gpr,csr,binary,mode,instr_str,operand,pad
  80000000,,ra:80000004,300:00001800,00000013,3,,,hart=0;mem=80001000:000000aa:1

Compared state per retire row:
  * hart id (from ``pad`` token ``hart=N``, default 0)
  * PC
  * instruction binary when either side provides it
  * GPR write set
  * CSR write set, with optional caller-provided masks
  * memory writes from ``mem=addr:data:be`` tokens

CSR masks are provided externally to keep the checker core-agnostic:
  --csr-mask 0xb00:0x0      # ignore all mcycle bits
  --csr-mask 0x300:0xffff   # compare only selected bits
"""

import argparse
import csv
import sys
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Tuple


def _norm_name(name: str) -> str:
    return (name or "").strip().lower()


def _parse_int(value: str) -> int:
    value = (value or "").strip().lower()
    if not value:
        return 0
    return int(value, 0 if value.startswith("0x") else 16)


def _norm_hex(value: str, width: int = 8) -> str:
    return f"{_parse_int(value) & ((1 << (width * 4)) - 1):0{width}x}"


def _parse_updates(text: str) -> Dict[str, str]:
    updates: Dict[str, str] = {}
    for item in (text or "").split(";"):
        item = item.strip()
        if not item:
            continue
        if ":" not in item:
            raise ValueError(f"Malformed state update '{item}'")
        name, value = item.split(":", 1)
        updates[_norm_name(name).replace("0x", "")] = _norm_hex(value)
    return updates


def _byte_enable_mask(be: int) -> int:
    mask = 0
    bit = 0
    while be:
        if be & 1:
            mask |= 0xff << (bit * 8)
        bit += 1
        be >>= 1
    return mask


@dataclass(frozen=True)
class MemWrite:
    addr: int
    data: int
    be: int

    @property
    def masked_data(self) -> int:
        return self.data & _byte_enable_mask(self.be)

    def short(self) -> str:
        return f"mem[{self.addr:08x}]={self.masked_data:08x}/be={self.be:x}"


@dataclass
class TraceRow:
    index: int
    hart: int
    pc: str
    binary: str
    gpr: Dict[str, str] = field(default_factory=dict)
    csr: Dict[str, str] = field(default_factory=dict)
    mem: List[MemWrite] = field(default_factory=list)
    suppress_gpr: set = field(default_factory=set)

    def label(self, name: str) -> str:
        return f"{name}[{self.index}] hart={self.hart} pc={self.pc} insn={self.binary}"


@dataclass
class CompareResult:
    matched: int = 0
    mismatches: List[str] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return not self.mismatches


def _parse_metadata(metadata: str) -> Tuple[int, List[MemWrite], set]:
    hart = 0
    mem: List[MemWrite] = []
    suppress_gpr = set()
    for token in (metadata or "").split(";"):
        token = token.strip()
        if not token:
            continue
        if token.startswith("hart="):
            hart = int(token.split("=", 1)[1], 0)
        elif token.startswith("mem="):
            payload = token.split("=", 1)[1]
            parts = payload.split(":")
            if len(parts) != 3:
                raise ValueError(f"Malformed memory write token '{token}'")
            mem.append(MemWrite(_parse_int(parts[0]), _parse_int(parts[1]),
                                _parse_int(parts[2])))
        elif token.startswith("suppress_gpr="):
            suppress_gpr.add(_norm_name(token.split("=", 1)[1]))
    return hart, mem, suppress_gpr


def read_trace_csv(path: str) -> List[TraceRow]:
    rows: List[TraceRow] = []
    with open(path, "r", encoding="utf-8", newline="") as fd:
        reader = csv.DictReader(fd)
        for index, row in enumerate(reader):
            metadata = ";".join(item for item in (
                row.get("pad", ""), row.get("operand", "")) if item)
            hart, mem, suppress_gpr = _parse_metadata(metadata)
            rows.append(TraceRow(
                index=index,
                hart=hart,
                pc=_norm_hex(row.get("pc", "")),
                binary=_norm_hex(row.get("binary", "")) if row.get("binary") else "",
                gpr=_parse_updates(row.get("gpr", "")),
                csr=_parse_updates(row.get("csr", "")),
                mem=mem,
                suppress_gpr=suppress_gpr,
            ))
    return rows


def parse_csr_masks(items: Iterable[str]) -> Dict[str, int]:
    masks: Dict[str, int] = {}
    for item in items:
        if ":" not in item:
            raise ValueError(f"CSR mask must be CSR:MASK, got '{item}'")
        csr, mask = item.split(":", 1)
        masks[_norm_name(csr).replace("0x", "")] = _parse_int(mask)
    return masks


def _masked_csr(csr: str, value: str, masks: Dict[str, int]) -> str:
    mask = masks.get(csr)
    if mask is None:
        return value
    return f"{_parse_int(value) & mask:08x}"


def _compare_dict(kind: str, dut: Dict[str, str], ref: Dict[str, str],
                  ctx: str, csr_masks: Dict[str, int],
                  mismatches: List[str], suppress_keys: Optional[set] = None) -> None:
    suppress_keys = suppress_keys or set()
    keys = sorted(set(dut) | set(ref))
    for key in keys:
        dut_val = dut.get(key)
        ref_val = ref.get(key)
        if key in suppress_keys and dut_val is None and ref_val is not None:
            continue
        if kind == "CSR":
            if dut_val is not None:
                dut_val = _masked_csr(key, dut_val, csr_masks)
            if ref_val is not None:
                ref_val = _masked_csr(key, ref_val, csr_masks)
        if dut_val != ref_val:
            mismatches.append(
                f"{ctx}: {kind} {key} mismatch dut={dut_val} ref={ref_val}")


def _compare_mem(dut: List[MemWrite], ref: List[MemWrite], ctx: str,
                 mismatches: List[str]) -> None:
    def byte_map(writes: List[MemWrite]) -> Dict[int, int]:
        data: Dict[int, int] = {}
        for write in writes:
            lane = 0
            be = write.be
            while be:
                if be & 1:
                    data[write.addr + lane] = (write.data >> (lane * 8)) & 0xff
                lane += 1
                be >>= 1
        return data

    def short_bytes(data: Dict[int, int]) -> str:
        return ",".join(f"{addr:08x}:{value:02x}"
                        for addr, value in sorted(data.items()))

    dut_bytes = byte_map(dut)
    ref_bytes = byte_map(ref)
    if dut_bytes != ref_bytes:
        mismatches.append(
            f"{ctx}: MEM bytes mismatch dut=[{short_bytes(dut_bytes)}] "
            f"ref=[{short_bytes(ref_bytes)}]")


def compare_traces(dut_rows: List[TraceRow], ref_rows: List[TraceRow],
                   name1: str = "dut", name2: str = "ref",
                   csr_masks: Optional[Dict[str, int]] = None,
                   mismatch_limit: int = 20) -> CompareResult:
    csr_masks = csr_masks or {}
    result = CompareResult()

    if len(dut_rows) != len(ref_rows):
        result.mismatches.append(
            f"retire count mismatch {name1}={len(dut_rows)} {name2}={len(ref_rows)}")

    for idx, (dut, ref) in enumerate(zip(dut_rows, ref_rows)):
        ctx = f"row {idx}: {dut.label(name1)} / {ref.label(name2)}"
        before = len(result.mismatches)
        if dut.hart != ref.hart:
            result.mismatches.append(f"{ctx}: hart mismatch dut={dut.hart} ref={ref.hart}")
        if dut.pc != ref.pc:
            result.mismatches.append(f"{ctx}: PC mismatch dut={dut.pc} ref={ref.pc}")
        if (dut.binary or ref.binary) and dut.binary != ref.binary:
            result.mismatches.append(
                f"{ctx}: INSN mismatch dut={dut.binary} ref={ref.binary}")
        _compare_dict("GPR", dut.gpr, ref.gpr, ctx, csr_masks,
                      result.mismatches, dut.suppress_gpr)
        _compare_dict("CSR", dut.csr, ref.csr, ctx, csr_masks, result.mismatches)
        _compare_mem(dut.mem, ref.mem, ctx, result.mismatches)
        if len(result.mismatches) == before:
            result.matched += 1
        if len(result.mismatches) >= mismatch_limit:
            break

    return result


def compare_trace_csv(csv1: str, csv2: str, name1: str, name2: str,
                      log: str = "", csr_masks: Optional[Dict[str, int]] = None,
                      mismatch_limit: int = 20) -> CompareResult:
    result = compare_traces(read_trace_csv(csv1), read_trace_csv(csv2),
                            name1, name2, csr_masks, mismatch_limit)
    out = open(log, "w", encoding="utf-8") if log else sys.stdout
    try:
        out.write(f"{name1} : {csv1}\n")
        out.write(f"{name2} : {csv2}\n")
        for mismatch in result.mismatches:
            out.write(f"Mismatch: {mismatch}\n")
        if result.passed:
            out.write(f"[PASSED]: {result.matched} retire rows matched\n")
        else:
            out.write(f"[FAILED]: {result.matched} matched, {len(result.mismatches)} mismatch\n")
    finally:
        if log:
            out.close()
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv_file_1", required=True)
    parser.add_argument("--csv_file_2", required=True)
    parser.add_argument("--csv_name_1", default="dut")
    parser.add_argument("--csv_name_2", default="ref")
    parser.add_argument("--log", default="")
    parser.add_argument("--csr-mask", action="append", default=[],
                        help="CSR:MASK comparison mask. May be repeated.")
    parser.add_argument("--mismatch-limit", type=int, default=20)
    args = parser.parse_args()

    result = compare_trace_csv(
        args.csv_file_1, args.csv_file_2,
        args.csv_name_1, args.csv_name_2,
        args.log, parse_csr_masks(args.csr_mask), args.mismatch_limit)
    return 0 if result.passed else 1


if __name__ == "__main__":
    sys.exit(main())

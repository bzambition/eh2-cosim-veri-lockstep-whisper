#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
EH2 Coverage Merge Script

Merges VCS coverage databases using urg. Modeled after lowRISC Ibex's
dv/uvm/core_ibex/scripts/merge_cov.py.

Two invocation modes:
  1. Metadata-driven (legacy ibex-compatible):
       merge_cov.py --dir-metadata <path>
  2. Standalone (signoff.py integration):
       merge_cov.py --dirs DIR1 DIR2 ... --output OUT_DIR

NC/Incisive does NOT participate in sign-off coverage. NC is reserved for
single-test waveform debugging only (`make smoke|regress SIMULATOR=nc
WAVES=1`). Coverage instrumentation, merge, and report generation all run
on the VCS path exclusively.
"""

import argparse
import logging
import os
import subprocess
import sys
from pathlib import Path
from typing import List

logger = logging.getLogger(__name__)


def find_vdb_dirs(start_dir: Path) -> List[Path]:
    """Find all VCS .vdb coverage directories under start_dir.

    Recognises both the per-test ``test.vdb`` layout and standalone
    ``*.vdb`` directories. Order is preserved for deterministic urg merge.
    """
    if not start_dir.is_dir():
        return []
    if start_dir.name.endswith(".vdb"):
        return [start_dir]
    cov_dbs: List[Path] = []
    seen = set()
    for p in start_dir.rglob("test.vdb"):
        if p.is_dir() and p not in seen:
            seen.add(p)
            cov_dbs.append(p)
    if not cov_dbs:
        for p in start_dir.rglob("*.vdb"):
            if p.is_dir() and p not in seen:
                seen.add(p)
                cov_dbs.append(p)
    return cov_dbs


def merge_cov_vcs(cov_dirs: List[Path], output_dir: Path) -> int:
    """Merge VCS coverage databases using urg.

    Produces:
      <output_dir>/merged.vdb           — merged coverage database
      <output_dir>/report/              — urg HTML + text reports
      <output_dir>/report/dashboard.txt — dashboard for signoff parsing
      <output_dir>/dashboard.txt        — mirrored dashboard (sign-off entry)
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    log_path = output_dir / "merge.log"
    stdout_log = output_dir / "merge.log.stdout"

    cmd = [
        "urg", "-full64",
        "-format", "both",
        "-dbname", str(output_dir / "merged.vdb"),
        "-report", str(output_dir / "report"),
        "-log", str(log_path),
        "-dir",
    ] + [str(d) for d in cov_dirs]

    logger.info("Merging %d VCS coverage databases via urg", len(cov_dirs))
    with open(stdout_log, "wb") as fd:
        fd.write(("+ " + " ".join(cmd) + "\n").encode("utf-8"))
        try:
            proc = subprocess.run(cmd, stdout=fd, stderr=subprocess.STDOUT,
                                  timeout=3600)
        except subprocess.TimeoutExpired:
            fd.write(b"\nERROR: urg merge timed out\n")
            return 124
        except FileNotFoundError:
            fd.write(b"\nERROR: urg not found in PATH (no VCS license?)\n")
            return 127

    # Mirror urg's report/dashboard.txt to the output root so signoff.py
    # auto-detects it without knowing about the urg subdir.
    dashboard_src = output_dir / "report" / "dashboard.txt"
    dashboard_dst = output_dir / "dashboard.txt"
    if dashboard_src.exists():
        dashboard_dst.write_bytes(dashboard_src.read_bytes())

    return proc.returncode


def find_nc_run_dirs(start_dir: Path) -> List[Path]:
    """Find NC/imc per-test coverage run directories (folders that contain a
    .ucd or .ucm file).

    Typical layout under build/<target>/cov_work/scope/:
        cov_work/scope/<test_name_1>/<hash>.ucd
        cov_work/scope/<test_name_2>/<hash>.ucd
        cov_work/scope/*.ucm    (shared design model)
    """
    runs: List[Path] = []
    if not start_dir.is_dir():
        return runs
    seen = set()
    for ucd in start_dir.rglob("*.ucd"):
        if ucd.parent in seen:
            continue
        seen.add(ucd.parent)
        runs.append(ucd.parent)
    return runs


def _parse_cumulative_metric(path: Path) -> float:
    """Pull the DUT-subtree cumulative percentage from an IMC per-metric report.

    IMC's ``report -metrics <X> -cumulative on -summary`` emits a column
    called ``<Metric>* Average`` whose value at each scope is the
    cumulative aggregate across that scope's entire subtree. We prefer the
    ``dut`` row (real RTL only); when the DUT row shows n/a we fall back
    to the testbench-top row (``core_eh2_tb_top``) since some metrics
    (assertion, covergroup) only exist on sibling interfaces bound at the
    TB level. Returns None if neither row carries a number.
    """
    import re
    if not path or not path.exists():
        return None
    text = path.read_text(encoding="utf-8", errors="replace")
    pct_re = re.compile(r"(\d+(?:\.\d+)?)%")
    rows = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("---") or stripped.startswith("Legend"):
            continue
        name_part = stripped.lstrip("| ").lstrip("-").strip()
        if not name_part:
            continue
        scope = name_part.split(None, 1)[0]
        if scope in rows:
            continue
        m = pct_re.search(stripped)
        if m:
            rows[scope] = float(m.group(1))
    for preferred in ("dut", "core_eh2_tb_top"):
        if preferred in rows:
            return rows[preferred]
    return None


def _write_nc_dashboard(path: Path, metrics: dict, runs: List[Path]) -> None:
    """Emit dashboard.txt compatible with urg's text format so signoff.py's
    URG parser can consume NC coverage data the same way as VCS data.

    Columns (mirror VCS urg dashboard):
      SCORE LINE TOGGLE FSM BRANCH ASSERT GROUP
    Where:
      LINE   = IMC Block cumulative on dut (含 branch — NC 152 IMC 把 branch
               合并到 block，不像 VCS 把它们拆开。所以 NC LINE 数字 ≈ VCS
               LINE+BRANCH 的合集，单独一个数表达不了。)
      TOGGLE = IMC Toggle cumulative on dut（cov_full_nc.ccf 已 set_toggle_portsonly
               与 VCS -cm_tgl portsonly 对齐口径）
      FSM    = average of IMC State + Transition cumulative
      BRANCH = n/a — NC 152 IMC 工具本体限制：没有独立 branch metric，
               已合并到 block (LINE) 中。这是 Cadence Incisive 152 (2016)
               工具能力限制，不是脚本问题。Xcelium 新版同样如此。要拆
               line vs branch，必须用 VCS。诚实标注 n/a 优于错误映射。
      ASSERT = IMC Assertion cumulative
      GROUP  = IMC Covergroup cumulative
      SCORE  = arithmetic mean of populated metrics
    """
    line       = metrics.get("block")
    toggle     = metrics.get("toggle")
    state      = metrics.get("state")
    transition = metrics.get("transition")
    fsm        = metrics.get("fsm")
    assertion  = metrics.get("assertion")
    group      = metrics.get("covergroup")

    if state is not None and transition is not None:
        fsm_combined = (state + transition) / 2.0
    elif fsm is not None:
        fsm_combined = fsm
    else:
        fsm_combined = state if state is not None else transition

    # NC 152 IMC has no independent branch metric; branch is merged into
    # block coverage by `set_branch_scoring` (Cadence doc: "Scores branches
    # together with block coverage"). Mark BRANCH as n/a in the dashboard
    # rather than mapping it to FSM transition (which is semantically
    # different and would mislead readers).
    branch = None

    pops = [v for v in (line, toggle, fsm_combined, branch, assertion, group)
            if v is not None]
    score = sum(pops) / len(pops) if pops else None

    def _f(v):
        return "{:>6.2f}".format(v) if v is not None else "  n/a "

    body = (
        "Dashboard (synthesised from imc -metrics ... -cumulative on; "
        "tool=NC/imc; scope=dut subtree)\n"
        "# Notes:\n"
        "#   - LINE   ≈ VCS LINE + BRANCH (NC 152 merges branch into block)\n"
        "#   - BRANCH   n/a (NC 152 工具本体限制；要拆 branch 用 VCS)\n"
        "#   - TOGGLE   portsonly (与 VCS 同口径)\n"
        "#   - FSM      mean(state, transition)\n"
        "Number of tests: {}\n\n".format(len(runs)) +
        "SCORE  LINE   TOGGLE FSM    BRANCH ASSERT GROUP\n" +
        "{} {} {} {} {} {} {}\n".format(
            _f(score), _f(line), _f(toggle), _f(fsm_combined),
            _f(branch), _f(assertion), _f(group))
    )
    path.write_text(body, encoding="utf-8")


def merge_imc(run_dirs: List[Path], output_dir: Path) -> int:
    """Merge NC/imc coverage runs and emit a urg-compatible dashboard.txt.

    The NC path mirrors the VCS path in semantics: a single dashboard.txt
    at output_dir/ with VCS urg-style columns so signoff.py can parse both
    without branching. Data comes from IMC's `-cumulative on` reports
    (DUT-subtree real aggregates, not the misleading instance-local row).
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    merged_db = output_dir / "merged_imc"
    log_path = output_dir / "merge.log"

    # Per-metric cumulative reports. IMC metric names differ from VCS;
    # there is no native branch metric (closest equivalent is FSM transition).
    per_metric_files = {
        "block":      output_dir / "imc_block_cum.txt",
        "toggle":     output_dir / "imc_toggle_cum.txt",
        "fsm":        output_dir / "imc_fsm_cum.txt",
        "state":      output_dir / "imc_state_cum.txt",
        "transition": output_dir / "imc_transition_cum.txt",
        "assertion":  output_dir / "imc_assertion_cum.txt",
        "covergroup": output_dir / "imc_covergroup_cum.txt",
    }

    runs = " ".join(str(r) for r in run_dirs)
    tcl_lines = [
        f"merge -out {merged_db} -overwrite {runs}",
        f"load {merged_db}",
    ]
    for metric, out_file in per_metric_files.items():
        tcl_lines.append(
            f"report -metrics {metric} -cumulative on -summary "
            f"-out {out_file} -text")
    tcl_cmds = " ; ".join(tcl_lines)

    cmd = ["imc", "-execcmd", tcl_cmds]
    logger.info("Merging %d NC/imc coverage runs", len(run_dirs))
    with open(log_path, "w") as log_fd:
        log_fd.write("+ " + " ".join(cmd) + "\n")
        try:
            proc = subprocess.run(cmd, stdout=log_fd, stderr=subprocess.STDOUT,
                                  timeout=3600)
        except subprocess.TimeoutExpired:
            log_fd.write("\nERROR: imc merge timed out\n")
            return 124
        except FileNotFoundError:
            log_fd.write("\nERROR: imc not found in PATH\n")
            return 127

    if proc.returncode != 0:
        return proc.returncode

    # Extract DUT-subtree cumulative numbers from each per-metric file.
    metrics = {}
    for name, fpath in per_metric_files.items():
        if fpath.exists():
            v = _parse_cumulative_metric(fpath)
            if v is not None:
                metrics[name] = v

    dashboard = output_dir / "dashboard.txt"
    _write_nc_dashboard(dashboard, metrics, run_dirs)
    return 0


def metadata_main(args) -> int:
    """Ibex-style metadata-driven mode (legacy callers)."""
    try:
        from metadata import RegressionMetadata
    except ImportError:
        sys.stderr.write(
            "merge_cov: --dir-metadata requires RegressionMetadata module\n")
        return 1

    md = RegressionMetadata.construct_from_metadata_dir(args.dir_metadata)
    if md.simulator != "vcs":
        # NC and XLM intentionally do not participate in sign-off cov.
        sys.stderr.write(
            "merge_cov: simulator {!r} skipped — only vcs participates in "
            "coverage merge\n".format(md.simulator))
        return 0  # no-op success

    cov_dir = Path(md.coverage_dir)
    cov_dir.mkdir(parents=True, exist_ok=True)
    run_dir = Path(md.work_dir)
    vdb_dirs = find_vdb_dirs(run_dir)
    if not vdb_dirs:
        sys.stderr.write("merge_cov: no .vdb directories found in {}\n".format(
            run_dir))
        return 1
    return merge_cov_vcs(vdb_dirs, cov_dir)


def standalone_main(args) -> int:
    """signoff.py integration mode.

    Detects simulator by the database type:
      - .vdb files / dirs → VCS urg
      - .ucd files under cov_work/scope/ → NC imc
    Both paths write a urg-compatible dashboard.txt to <output>/dashboard.txt
    so the signoff parser is simulator-agnostic.
    """
    output_dir = Path(args.output)
    vcs_dirs: List[Path] = []
    nc_run_dirs: List[Path] = []
    for d_str in args.dirs:
        d = Path(d_str)
        if not d.is_dir():
            continue
        if d.name.endswith(".vdb"):
            vcs_dirs.append(d)
        elif d.name == "cov_work" or "cov_work" in d.parts:
            nc_run_dirs.extend(find_nc_run_dirs(d))
        else:
            # Walk: prefer .vdb (VCS), fall back to .ucd (NC).
            nested_vdb = find_vdb_dirs(d)
            if nested_vdb:
                vcs_dirs.extend(nested_vdb)
            else:
                nc_run_dirs.extend(find_nc_run_dirs(d))

    # Deduplicate preserving order.
    def _dedup(items):
        seen = set()
        uniq = []
        for x in items:
            real = x.resolve()
            if real not in seen:
                seen.add(real)
                uniq.append(x)
        return uniq

    vcs_dirs = _dedup(vcs_dirs)
    nc_run_dirs = _dedup(nc_run_dirs)

    if vcs_dirs:
        return merge_cov_vcs(vcs_dirs, output_dir)
    if nc_run_dirs:
        return merge_imc(nc_run_dirs, output_dir)
    sys.stderr.write(
        "merge_cov: no valid coverage dirs supplied (looked for .vdb / cov_work/*.ucd)\n")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(
        description="EH2 VCS coverage merge (Ibex-aligned)")
    parser.add_argument("--dir-metadata", type=Path,
                        help="Metadata-driven mode: path to metadata dir")
    parser.add_argument("--dirs", nargs="+",
                        help="Standalone mode: list of coverage directories")
    parser.add_argument("--output", type=Path,
                        help="Standalone mode: merged output directory")
    parser.add_argument("--verbose", action="store_true",
                        help="Enable info-level logging")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(levelname)s %(message)s")

    if args.dir_metadata:
        return metadata_main(args)
    if args.dirs and args.output:
        return standalone_main(args)
    parser.error("Either --dir-metadata or --dirs + --output must be given")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)

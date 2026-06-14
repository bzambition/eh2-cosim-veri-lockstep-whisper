#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate a self-contained EH2 sign-off HTML dashboard.

The report is intentionally static:
  * all CSS and JavaScript are embedded;
  * logs are linked by relative path;
  * no external network resources are referenced.

Inputs are the sign-off JSON, the URG text dashboard, and the stage run
directory.  The script does not mutate those inputs.
"""

import argparse
import html
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


EH2_ROOT = Path(__file__).resolve().parents[4]
DEFAULT_SIGNOFF_STATUS = EH2_ROOT / "build" / "r3b_final" / "signoff_status.json"
DEFAULT_COVERAGE_DASHBOARD = EH2_ROOT / "build" / "r3b_cov_report" / "dashboard.txt"
DEFAULT_RUNS_DIR = EH2_ROOT / "build" / "r3b_final" / "runs"
DEFAULT_OUTPUT = EH2_ROOT / "build" / "r3b_final" / "report.html"

DETAIL_STAGE_ORDER = [
    "smoke",
    "directed",
    "cosim",
    "riscvdv",
    "compliance",
]

SUMMARY_STAGE_ORDER = [
    "smoke",
    "directed",
    "cosim",
    "riscvdv",
    "compliance",
]

COVERAGE_METRICS = [
    ("line", "Line"),
    ("toggle", "Toggle"),
    ("fsm", "FSM"),
    ("branch", "Branch"),
    ("assert", "Assertion"),
    ("functional", "Functional / Group"),
]

MODULE_METRIC_KEYS = {
    "line": "line",
    "toggle": "toggle",
    "fsm": "fsm",
    "branch": "branch",
    "assert": "assert",
    "functional": "score",
}


def esc(value: Any) -> str:
    """HTML-escape a value for text nodes."""
    if value is None:
        return ""
    return html.escape(str(value), quote=True)


def pct(value: Any) -> Optional[float]:
    """Parse an URG percentage value, accepting '--' as missing."""
    if value is None:
        return None
    text = str(value).strip()
    if not text or text == "--":
        return None
    try:
        return float(text)
    except ValueError:
        return None


def pct_text(value: Any) -> str:
    value = pct(value)
    if value is None:
        return "--"
    return "{:.2f}".format(value)


def status_class(status: str) -> str:
    status = (status or "").upper()
    if status in ("PASS", "PASSED", "SUCCEEDED"):
        return "pass"
    if status in ("PASS_WITH_WAIVERS", "WAIVE_TOOL_LIMITED", "PARTIAL"):
        return "warn"
    if status in ("FAIL", "FAILED", "TIMEOUT", "UVM_FATAL", "TEST_FAIL"):
        return "fail"
    return "neutral"


def bool_status(passed: Any, failure_mode: str = "") -> Tuple[str, str]:
    if bool(passed):
        return "PASS", "pass"
    mode = (failure_mode or "FAIL").upper()
    if "TIMEOUT" in mode:
        return "TIMEOUT", "fail"
    return mode, "fail"


def load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def rel_href(path_text: str, output_path: Path) -> str:
    """Return a browser-friendly relative link from output_path to path_text."""
    if not path_text:
        return ""
    path = Path(path_text)
    if not path.is_absolute():
        path = (EH2_ROOT / path).resolve()
    base = output_path.resolve().parent
    try:
        rel = os.path.relpath(str(path), str(base))
    except ValueError:
        return str(path)
    return rel.replace(os.sep, "/")


def read_text_if_exists(path: Path) -> str:
    if not path.exists() or not path.is_file():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def parse_total_coverage(text: str) -> Dict[str, float]:
    """Parse the Total Coverage Summary block from URG dashboard text."""
    lines = text.splitlines()
    for idx, line in enumerate(lines):
        if not re.search(r"\bSCORE\b.*\bLINE\b", line):
            continue
        if idx + 1 >= len(lines):
            continue
        data_line = lines[idx + 1].strip()
        if not data_line and idx + 2 < len(lines):
            data_line = lines[idx + 2].strip()
        headers = [token.lower() for token in line.split()]
        values = data_line.split()
        if len(values) < 2:
            continue
        result: Dict[str, float] = {}
        aliases = {
            "score": "overall",
            "line": "line",
            "toggle": "toggle",
            "tgl": "toggle",
            "fsm": "fsm",
            "branch": "branch",
            "assert": "assert",
            "assertion": "assert",
            "group": "functional",
            "covergroup": "functional",
            "functional": "functional",
        }
        for header, value in zip(headers, values):
            metric = aliases.get(header)
            parsed = pct(value)
            if metric and parsed is not None:
                result[metric] = parsed
        if result:
            return result
    return {}


def parse_number_of_tests(text: str) -> int:
    match = re.search(r"Number of tests:\s*([0-9]+)", text)
    return int(match.group(1)) if match else 0


def parse_metric_table(path: Path, expected_name: bool = True) -> List[Dict[str, Any]]:
    """Parse URG SCORE/LINE/COND/TOGGLE/FSM/NAME tables.

    This parser handles `modlist.txt`, where columns are whitespace separated
    and the final NAME column can contain a single module name. Rows with no
    usable score are retained so the HTML can show uncovered/unmeasured modules.
    """
    text = read_text_if_exists(path)
    if not text:
        return []
    rows: List[Dict[str, Any]] = []
    active = False
    for raw in text.splitlines():
        line = raw.rstrip()
        if re.search(r"\bSCORE\b.*\bTOGGLE\b.*\bNAME\b", line):
            active = True
            continue
        if not active:
            continue
        if not line.strip() or set(line.strip()) == {"-"}:
            continue
        parts = line.split()
        if len(parts) < 6:
            continue
        score = pct(parts[0])
        name = " ".join(parts[5:]).strip()
        if expected_name and not name:
            continue
        if score is None and all(pct(p) is None for p in parts[1:6]):
            rows.append({
                "name": name,
                "score": None,
                "line": None,
                "toggle": None,
                "fsm": None,
                "branch": None,
                "assert": None,
            })
            continue
        rows.append({
            "name": name,
            "score": score,
            "line": pct(parts[1]),
            "toggle": pct(parts[2]),
            "fsm": pct(parts[3]),
            "branch": pct(parts[4]),
            "assert": pct(parts[5]),
        })
    rows.sort(key=lambda row: (9999.0 if row["score"] is None else row["score"],
                               row["name"]))
    return rows


def parse_group_table(path: Path) -> List[Dict[str, Any]]:
    text = read_text_if_exists(path)
    if not text:
        return []
    rows: List[Dict[str, Any]] = []
    active = False
    for raw in text.splitlines():
        line = raw.rstrip()
        if re.search(r"\bSCORE\b.*\bINSTANCES\b.*\bNAME\b", line):
            active = True
            continue
        if not active:
            continue
        if not line.strip() or set(line.strip()) == {"-"}:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        score = pct(parts[0])
        # The URG table has many fixed columns before the group name.  The
        # final token is the group name in this flow.
        name = parts[-1]
        rows.append({
            "name": name,
            "score": score,
            "instances": pct(parts[1]),
            "weight": parts[2],
            "goal": parts[3],
        })
    rows.sort(key=lambda row: (9999.0 if row["score"] is None else row["score"],
                               row["name"]))
    return rows


def parse_coverage_report(dashboard_path: Path) -> Dict[str, Any]:
    """Parse URG dashboard, module, and group text reports."""
    dashboard_path = dashboard_path.resolve()
    text = read_text_if_exists(dashboard_path)
    report_dir = dashboard_path.parent
    # urg 原生布局把 dashboard.txt / modlist.txt / groups.txt / hierarchy.txt
    # 全放在同一个 report/ 子目录里；merge_cov.py 为了 signoff 解析方便把
    # dashboard.txt 镜像到了 cov_merged/ 顶层，但 detail 文件仍只在 report/。
    # 优先看 dashboard 同目录，找不到再回退 report/ 子目录。
    detail_dir = report_dir
    if not (detail_dir / "modlist.txt").exists() \
            and (report_dir / "report" / "modlist.txt").exists():
        detail_dir = report_dir / "report"
    metrics = parse_total_coverage(text)
    modules = parse_metric_table(detail_dir / "modlist.txt")
    groups = parse_group_table(detail_dir / "groups.txt")
    return {
        "dashboard_path": str(dashboard_path),
        "number_of_tests": parse_number_of_tests(text),
        "metrics": metrics,
        "modules": modules,
        "groups": groups,
        "raw_dashboard": text,
    }


def stage_sort_key(name: str) -> Tuple[int, str]:
    if name in SUMMARY_STAGE_ORDER:
        return SUMMARY_STAGE_ORDER.index(name), name
    return len(SUMMARY_STAGE_ORDER), name


def get_stage_list(status: Dict[str, Any]) -> List[Dict[str, Any]]:
    stages = status.get("stages", {})
    if isinstance(stages, dict):
        items = list(stages.items())
        items.sort(key=lambda item: stage_sort_key(item[0]))
        return [dict(value, stage=name) for name, value in items]
    return list(stages or [])


def normalize_test_entry(stage_name: str, test: Dict[str, Any],
                         output_path: Path) -> Dict[str, Any]:
    status, cls = bool_status(test.get("passed"), test.get("failure_mode") or "")
    log_path = test.get("sim_log") or test.get("uvm_log") or ""
    return {
        "stage": stage_name,
        "name": test.get("name", ""),
        "seed": test.get("seed", ""),
        "status": status,
        "status_class": cls,
        "passed": bool(test.get("passed")),
        "failure_mode": test.get("failure_mode") or "",
        "warnings": test.get("warnings", 0),
        "sim_time": test.get("sim_time_sec", test.get("sim_time", "")),
        "cycles": test.get("cycles", ""),
        "instructions": test.get("instructions", ""),
        "log_path": log_path,
        "log_href": rel_href(log_path, output_path) if log_path else "",
    }


def gather_stage_details(status: Dict[str, Any],
                         output_path: Path) -> List[Dict[str, Any]]:
    details = []
    stages_by_name = {stage["stage"]: stage for stage in get_stage_list(status)}
    for stage_name in DETAIL_STAGE_ORDER:
        stage = stages_by_name.get(stage_name)
        if not stage:
            continue
        tests = [
            normalize_test_entry(stage_name, test, output_path)
            for test in stage.get("tests", [])
        ]
        details.append({
            "stage": stage_name,
            "status": stage.get("status", "UNKNOWN"),
            "total": stage.get("total", len(tests)),
            "passed": stage.get("passed", 0),
            "failed": stage.get("failed", 0),
            "pass_rate": stage.get("pass_rate", 0.0),
            "waivers": stage.get("waivers", []),
            "blockers": stage.get("blockers", []),
            "tests": tests,
        })
    return details


def normalize_stage_summary(stage: Dict[str, Any]) -> Dict[str, Any]:
    total = int(stage.get("total") or 0)
    passed = int(stage.get("passed") or 0)
    failed = int(stage.get("failed") or 0)
    if total > 0:
        ratio = 100.0 * passed / total
    else:
        ratio = float(stage.get("pass_rate") or 0.0)
    note = stage.get("note") or "; ".join(stage.get("waivers", []))
    return {
        "stage": stage.get("stage", ""),
        "status": stage.get("status", "UNKNOWN"),
        "status_class": status_class(stage.get("status", "")),
        "total": total,
        "passed": passed,
        "failed": failed,
        "pass_rate": ratio,
        "note": note,
    }


def gather_stage_waivers(status: Dict[str, Any]) -> List[Dict[str, Any]]:
    rows = []
    for stage in get_stage_list(status):
        for waiver in stage.get("waivers", []) or []:
            rows.append({
                "stage": stage.get("stage", ""),
                "text": waiver,
            })
    return rows


def load_report_data(signoff_status: Path, coverage_dashboard: Path,
                     runs_dir: Path, output: Path) -> Dict[str, Any]:
    status = load_json(signoff_status)
    coverage = parse_coverage_report(coverage_dashboard)
    stage_summaries = [
        normalize_stage_summary(stage)
        for stage in get_stage_list(status)
    ]
    stage_details = gather_stage_details(status, output)
    per_stage_entry_count = sum(len(stage["tests"]) for stage in stage_details)
    display_test_count = coverage.get("number_of_tests") or per_stage_entry_count
    return {
        "status": status,
        "signoff_status_path": str(signoff_status.resolve()),
        "coverage_dashboard_path": str(coverage_dashboard.resolve()),
        "runs_dir": str(runs_dir.resolve()),
        "output_path": str(output.resolve()),
        "stage_summaries": stage_summaries,
        "stages": stage_details,
        "coverage": coverage,
        "coverage_metrics": coverage["metrics"] or
        status.get("coverage", {}).get("metrics", {}),
        "test_entry_count": display_test_count,
        "per_stage_entry_count": per_stage_entry_count,
        "stage_waivers": gather_stage_waivers(status),
    }


def progress_bar(label: str, value: Any) -> str:
    parsed = pct(value)
    width = 0.0 if parsed is None else max(0.0, min(100.0, parsed))
    text = "--" if parsed is None else "{:.2f}%".format(parsed)
    return (
        '<div class="metric">'
        '<div class="metric-head"><span>{}</span><strong>{}</strong></div>'
        '<div class="bar"><div class="bar-fill" style="width:{:.2f}%"></div></div>'
        '</div>'
    ).format(esc(label), esc(text), width)


def cell(value: Any, cls: str = "") -> str:
    if cls:
        return '<td class="{}">{}</td>'.format(cls, esc(value))
    return '<td>{}</td>'.format(esc(value))


def raw_cell(value: str, cls: str = "") -> str:
    """Return a table cell containing trusted HTML generated by this script."""
    if cls:
        return '<td class="{}">{}</td>'.format(cls, value)
    return '<td>{}</td>'.format(value)


def link_or_text(label: str, href: str) -> str:
    if not href:
        return esc(label or "")
    return '<a href="{}">{}</a>'.format(esc(href), esc(label or href))


def render_stage_summary(data: Dict[str, Any]) -> str:
    rows = []
    for stage in data["stage_summaries"]:
        rows.append(
            "<tr>"
            "{stage}{status}{total}{passed}{failed}{rate}{note}"
            "</tr>".format(
                stage=cell(stage["stage"]),
                status=cell(stage["status"], "badge " + stage["status_class"]),
                total=cell(stage["total"]),
                passed=cell(stage["passed"]),
                failed=cell(stage["failed"]),
                rate=cell("{:.2f}%".format(stage["pass_rate"])),
                note=cell(stage["note"]),
            )
        )
    return (
        '<section id="summary" class="card">'
        '<h2>Stage Summary</h2>'
        '<table class="sortable"><thead><tr>'
        '<th>Stage</th><th>Status</th><th>Total</th><th>Passed</th>'
        '<th>Failed</th><th>Pass Rate</th><th>Note</th>'
        '</tr></thead><tbody>{}</tbody></table></section>'
    ).format("\n".join(rows))


def render_coverage_bars(data: Dict[str, Any]) -> str:
    metrics = data["coverage_metrics"]
    bars = []
    for key, label in COVERAGE_METRICS:
        bars.append(progress_bar(label, metrics.get(key)))
    return (
        '<section id="coverage-summary" class="card">'
        '<h2>Coverage Summary</h2>'
        '<div class="metric-grid">{}</div>'
        '<p class="muted">Coverage DB tests: {}</p>'
        '</section>'
    ).format("\n".join(bars), esc(data["test_entry_count"]))


def render_stage_details(data: Dict[str, Any]) -> str:
    panels = []
    for stage in data["stages"]:
        rows = []
        for test in stage["tests"]:
            log = link_or_text("log", test["log_href"]) if test["log_href"] else ""
            rows.append(
                '<tr class="row-{}">'.format(test["status_class"]) +
                cell(test["name"]) +
                cell(test["seed"]) +
                cell(test["status"], "badge " + test["status_class"]) +
                cell(test["sim_time"]) +
                cell(test["failure_mode"]) +
                raw_cell(log, "raw-html") +
                "</tr>"
            )
        body = "\n".join(rows) if rows else (
            '<tr><td colspan="6">No test entries in this stage.</td></tr>')
        panels.append(
            '<details class="card stage-panel">'
            '<summary><span>{stage}</span><span class="summary-count">'
            '{passed}/{total} {status}</span></summary>'
            '<input class="filter" type="search" placeholder="Filter test name...">'
            '<table class="sortable filterable"><thead><tr>'
            '<th>Test name</th><th>Seed</th><th>Status</th><th>Sim time</th>'
            '<th>Failure mode</th><th>Log link</th>'
            '</tr></thead><tbody>{body}</tbody></table>'
            '</details>'.format(
                stage=esc(stage["stage"]),
                passed=esc(stage["passed"]),
                total=esc(stage["total"]),
                status=esc(stage["status"]),
                body=body,
            )
        )
    return '<section id="tests"><h2>Per-Stage Test Results</h2>{}</section>'.format(
        "\n".join(panels))


def render_metric_table(metric_key: str, title: str,
                        data: Dict[str, Any]) -> str:
    coverage = data["coverage"]
    metrics = data["coverage_metrics"]
    total = metrics.get(metric_key)
    # IMC 152 (NC) 不输出 urg-style modlist.txt / groups.txt 模块级 detail。
    # 我们在 NC 合并 dashboard 时打了 "tool=NC/imc" 印记，用它判断信息源，
    # 给出工具能力说明而不是误导的 "No detail table available"。
    raw_dashboard = coverage.get("raw_dashboard", "") or ""
    is_imc = "tool=NC/imc" in raw_dashboard
    imc_fallback = (
        'NC/IMC 152 不输出 urg-style 模块级 detail '
        '(工具能力限制)。总分已在 '
        'Coverage 总览卡。如需模块级查'
        '看：imc -gui build/signoff_nc/cov_merged/merged_imc 或'
        '改走 SIMULATOR=vcs 。')
    default_fallback = "No detail table available."
    fallback_msg = imc_fallback if is_imc else default_fallback
    if metric_key == "functional":
        rows_data = coverage.get("groups", [])
        header = '<th>Group</th><th>Score</th><th>Instances</th><th>Weight</th>'
        rows = []
        for row in rows_data:
            rows.append(
                "<tr>{}</tr>".format(
                    cell(row.get("name")) +
                    cell(pct_text(row.get("score"))) +
                    cell(pct_text(row.get("instances"))) +
                    cell(row.get("weight"))
                )
            )
    else:
        modules = list(coverage.get("modules", []))
        sort_key = MODULE_METRIC_KEYS[metric_key]
        modules.sort(key=lambda row: (
            9999.0 if row.get(sort_key) is None else row.get(sort_key),
            row.get("name", "")))
        header = ('<th>Module</th><th>Score</th><th>Line</th>'
                  '<th>Toggle</th><th>FSM</th><th>Branch</th><th>Assert</th>')
        rows = []
        for row in modules:
            rows.append(
                "<tr>{}</tr>".format(
                    cell(row.get("name")) +
                    cell(pct_text(row.get("score"))) +
                    cell(pct_text(row.get("line"))) +
                    cell(pct_text(row.get("toggle"))) +
                    cell(pct_text(row.get("fsm"))) +
                    cell(pct_text(row.get("branch"))) +
                    cell(pct_text(row.get("assert")))
                )
            )
    body = "\n".join(rows) if rows else (
        '<tr><td colspan="6">{}</td></tr>'.format(esc(fallback_msg)))
    return (
        '<details class="card coverage-detail">'
        '<summary>{title}: {total}</summary>'
        '<table class="sortable"><thead><tr>{header}</tr></thead>'
        '<tbody>{body}</tbody></table></details>'
    ).format(title=esc(title), total=esc(pct_text(total)),
             header=header, body=body)


def render_coverage_details(data: Dict[str, Any]) -> str:
    parts = []
    for key, label in COVERAGE_METRICS:
        parts.append(render_metric_table(key, label, data))
    return '<section id="coverage-detail"><h2>Coverage Detail</h2>{}</section>'.format(
        "\n".join(parts))


def render_waivers_section(data: Dict[str, Any]) -> str:
    status = data["status"]
    cosim = status.get("cosim_disabled_tests", []) or []
    skipped = status.get("skip_in_signoff_tests", []) or []
    stage_waivers = data.get("stage_waivers", [])

    def list_items(items: Iterable[Any]) -> str:
        values = list(items)
        if not values:
            return "<li>None</li>"
        return "\n".join("<li>{}</li>".format(esc(item)) for item in values)

    waiver_rows = []
    for waiver in stage_waivers:
        waiver_rows.append(
            "<tr>{}</tr>".format(cell(waiver["stage"]) + cell(waiver["text"]))
        )
    if not waiver_rows:
        waiver_rows.append('<tr><td colspan="2">None</td></tr>')

    return (
        '<section id="waivers" class="card">'
        '<h2>Waivers</h2>'
        '<h3>Cosim Disabled Tests</h3><ul>{cosim}</ul>'
        '<h3>Skip-in-Signoff Tests</h3><ul>{skipped}</ul>'
        '<h3>Stage Waivers</h3>'
        '<table><thead><tr><th>Stage</th><th>Waiver</th></tr></thead>'
        '<tbody>{waivers}</tbody></table>'
        '</section>'
    ).format(cosim=list_items(cosim), skipped=list_items(skipped),
             waivers="\n".join(waiver_rows))


def render_nav() -> str:
    links = [
        ("#summary", "Stages"),
        ("#coverage-summary", "Coverage"),
        ("#tests", "Tests"),
        ("#coverage-detail", "Coverage Detail"),
        ("#waivers", "Waivers"),
    ]
    return '<nav>{}</nav>'.format(
        "\n".join('<a href="{}">{}</a>'.format(href, esc(label))
                  for href, label in links))


def render_header(data: Dict[str, Any]) -> str:
    status = data["status"].get("status", "UNKNOWN")
    metrics = data["coverage_metrics"]
    return (
        '<header class="top">'
        '<div>'
        '<h1>EH2 Sign-off Dashboard</h1>'
        '<p class="muted">Timestamp: {timestamp} | Profile: {profile} | '
        'Output: {output}</p>'
        '<p class="muted">Sign-off JSON: {json_path}</p>'
        '</div>'
        '<div class="hero-stats">'
        '<span class="status-badge {status_class}">{status}</span>'
        '<span><strong>{tests}</strong><small>coverage tests</small></span>'
        '<span><strong>{line}%</strong><small>line</small></span>'
        '<span><strong>{toggle}%</strong><small>toggle</small></span>'
        '<span><strong>{functional}%</strong><small>functional</small></span>'
        '</div>'
        '</header>'
    ).format(timestamp=esc(data["status"].get("timestamp", "")),
             profile=esc(data["status"].get("profile", "")),
             output=esc(data["status"].get("output_dir", "")),
             json_path=esc(data["signoff_status_path"]),
             status_class=status_class(status),
             status=esc(status),
             tests=esc(data["test_entry_count"]),
             line=esc(pct_text(metrics.get("line"))),
             toggle=esc(pct_text(metrics.get("toggle"))),
             functional=esc(pct_text(metrics.get("functional"))))


def css() -> str:
    return r"""
:root {
  color-scheme: light;
  --bg: #f6f7f9;
  --panel: #ffffff;
  --text: #17202a;
  --muted: #667085;
  --line: #d0d5dd;
  --pass: #177245;
  --pass-bg: #e8f5ee;
  --warn: #a15c00;
  --warn-bg: #fff3df;
  --fail: #b42318;
  --fail-bg: #fde7e7;
  --blue: #175cd3;
  --blue-bg: #e8f0fe;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
a { color: var(--blue); text-decoration: none; }
a:hover { text-decoration: underline; }
.top {
  position: sticky;
  top: 0;
  z-index: 5;
  background: rgba(255,255,255,0.96);
  border-bottom: 1px solid var(--line);
  padding: 18px 28px;
  display: flex;
  justify-content: space-between;
  gap: 24px;
  align-items: center;
}
h1, h2, h3 { margin: 0 0 12px; line-height: 1.2; }
h1 { font-size: 26px; }
h2 { font-size: 20px; }
h3 { font-size: 15px; margin-top: 18px; }
.muted { color: var(--muted); margin: 4px 0; }
.hero-stats {
  display: grid;
  grid-template-columns: repeat(5, max-content);
  gap: 10px;
  align-items: stretch;
}
.hero-stats span {
  display: flex;
  flex-direction: column;
  justify-content: center;
  min-width: 92px;
  padding: 8px 10px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: #fff;
}
.hero-stats strong { font-size: 18px; }
.hero-stats small { color: var(--muted); }
.status-badge, .badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-weight: 700;
  border-radius: 999px;
  padding: 3px 8px;
  white-space: nowrap;
}
.status-badge { font-size: 16px; min-width: 96px; }
.pass { color: var(--pass); background: var(--pass-bg); }
.warn { color: var(--warn); background: var(--warn-bg); }
.fail { color: var(--fail); background: var(--fail-bg); }
.neutral { color: var(--muted); background: #f2f4f7; }
main { max-width: 1500px; margin: 0 auto; padding: 22px 28px 60px; }
nav {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin: 0 0 18px;
}
nav a {
  padding: 7px 10px;
  border: 1px solid var(--line);
  border-radius: 7px;
  background: #fff;
}
.card, details.card {
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 16px;
  margin: 14px 0;
  box-shadow: 0 1px 2px rgba(16,24,40,0.04);
}
details > summary {
  cursor: pointer;
  font-weight: 700;
  display: flex;
  justify-content: space-between;
  align-items: center;
}
.summary-count { color: var(--muted); font-weight: 600; }
table {
  width: 100%;
  border-collapse: collapse;
  table-layout: auto;
  margin-top: 8px;
}
th, td {
  border-bottom: 1px solid #eaecf0;
  padding: 8px 9px;
  text-align: left;
  vertical-align: top;
}
th {
  background: #f9fafb;
  color: #344054;
  position: sticky;
  top: 82px;
  z-index: 2;
  cursor: pointer;
  user-select: none;
}
td.raw-html a { font-weight: 600; }
tr.row-pass { background: #fbfffd; }
tr.row-fail { background: #fff8f8; }
.metric-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
  gap: 12px;
}
.metric {
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 10px;
  background: #fff;
}
.metric-head {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 8px;
}
.bar {
  height: 10px;
  border-radius: 999px;
  background: #edf2f7;
  overflow: hidden;
}
.bar-fill {
  height: 100%;
  background: linear-gradient(90deg, #175cd3, #17a56b);
}
.filter {
  width: min(420px, 100%);
  padding: 8px 10px;
  border: 1px solid var(--line);
  border-radius: 7px;
  margin: 12px 0 4px;
}
ul { margin-top: 4px; }
.coverage-detail summary { font-size: 15px; }
@media (max-width: 900px) {
  .top { position: static; flex-direction: column; align-items: flex-start; }
  .hero-stats { grid-template-columns: repeat(2, minmax(130px, 1fr)); width: 100%; }
  th { position: static; }
}
"""


def javascript() -> str:
    return r"""
(function () {
  function cellText(row, index) {
    return (row.children[index] && row.children[index].innerText || '').trim();
  }
  function asNumber(text) {
    var cleaned = text.replace(/[% ,]/g, '');
    if (cleaned === '' || cleaned === '--') return NaN;
    return Number(cleaned);
  }
  function sortTable(table, index, reverse) {
    var tbody = table.tBodies[0];
    if (!tbody) return;
    var rows = Array.prototype.slice.call(tbody.rows);
    rows.sort(function (a, b) {
      var av = cellText(a, index);
      var bv = cellText(b, index);
      var an = asNumber(av);
      var bn = asNumber(bv);
      var cmp;
      if (!isNaN(an) && !isNaN(bn)) {
        cmp = an - bn;
      } else {
        cmp = av.localeCompare(bv);
      }
      return reverse ? -cmp : cmp;
    });
    rows.forEach(function (row) { tbody.appendChild(row); });
  }
  Array.prototype.forEach.call(document.querySelectorAll('table.sortable'), function (table) {
    Array.prototype.forEach.call(table.querySelectorAll('thead th'), function (th, index) {
      th.addEventListener('click', function () {
        var reverse = th.getAttribute('data-sort-dir') === 'asc';
        Array.prototype.forEach.call(th.parentNode.children, function (other) {
          other.removeAttribute('data-sort-dir');
        });
        th.setAttribute('data-sort-dir', reverse ? 'desc' : 'asc');
        sortTable(table, index, reverse);
      });
    });
  });
  Array.prototype.forEach.call(document.querySelectorAll('.filter'), function (input) {
    var table = input.parentElement.querySelector('table.filterable');
    if (!table || !table.tBodies[0]) return;
    input.addEventListener('input', function () {
      var needle = input.value.toLowerCase();
      Array.prototype.forEach.call(table.tBodies[0].rows, function (row) {
        var haystack = row.innerText.toLowerCase();
        row.style.display = haystack.indexOf(needle) === -1 ? 'none' : '';
      });
    });
  });
})();
"""


def render_html(data: Dict[str, Any]) -> str:
    """Render complete self-contained HTML."""
    parts = [
        "<!DOCTYPE html>",
        '<html lang="en">',
        "<head>",
        '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        "<title>EH2 Sign-off Dashboard</title>",
        "<style>{}</style>".format(css()),
        "</head>",
        "<body>",
        render_header(data),
        "<main>",
        render_nav(),
        render_stage_summary(data),
        render_coverage_bars(data),
        render_stage_details(data),
        render_coverage_details(data),
        render_waivers_section(data),
        "</main>",
        "<script>{}</script>".format(javascript()),
        "</body>",
        "</html>",
    ]
    return "\n".join(parts) + "\n"


def write_report(data: Dict[str, Any], output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(render_html(data), encoding="utf-8")


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate a self-contained EH2 sign-off HTML report")
    parser.add_argument("--signoff-status", type=Path,
                        default=DEFAULT_SIGNOFF_STATUS,
                        help="Path to signoff_status.json")
    parser.add_argument("--coverage-dashboard", type=Path,
                        default=DEFAULT_COVERAGE_DASHBOARD,
                        help="Path to URG dashboard.txt")
    parser.add_argument("--runs-dir", type=Path, default=DEFAULT_RUNS_DIR,
                        help="Path to sign-off runs directory")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT,
                        help="Output HTML path")
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    if not args.signoff_status.exists():
        print("ERROR: signoff status not found: {}".format(args.signoff_status),
              file=sys.stderr)
        return 1
    if not args.coverage_dashboard.exists():
        print("ERROR: coverage dashboard not found: {}".format(
            args.coverage_dashboard), file=sys.stderr)
        return 1
    data = load_report_data(args.signoff_status, args.coverage_dashboard,
                            args.runs_dir, args.output)
    write_report(data, args.output)
    print(args.output)
    print("HTML report: {} ({} bytes, {} displayed tests)".format(
        args.output, args.output.stat().st_size, data["test_entry_count"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Runs the warehouse load (etl.usp_run) and writes the run report.

The whole load lives in T-SQL, inside the database. Python only calls it, reads the result and
writes a Markdown report (for the CI summary and for the people who follow the nightly runs).
"""

from __future__ import annotations

from datetime import date
from pathlib import Path

from insurance_dw.db import DW_DB, connect, query

REPORTS = Path("reports")


def run_etl(as_of: date, mode: str = "incremental") -> dict:
    with connect(DW_DB) as conn:
        result = query(conn, "EXEC etl.usp_run @as_of_date = %s, @mode = %s", (as_of, mode))[0]
        result["checks"] = query(
            conn,
            "SELECT check_name, severity, passed, legacy_value, dw_value, detail "
            "FROM dq.check_result WHERE run_id = %s ORDER BY check_order",
            (result["run_id"],),
        )
        result["steps"] = query(
            conn,
            "SELECT step, rows_affected, DATEDIFF(MILLISECOND, started_at, finished_at) AS ms "
            "FROM etl.step_log WHERE run_id = %s ORDER BY started_at, step",
            (result["run_id"],),
        )
        result["rejected"] = query(
            conn,
            "SELECT source_table, reason, COUNT(*) AS records, SUM(amount) AS amount FROM etl.rejected_row "
            "WHERE resolved_run_id IS NULL GROUP BY source_table, reason ORDER BY records DESC",
        )
    write_report(result)
    return result


def _number(value) -> str:
    if value is None:
        return ""
    return f"{value:,.2f}" if value % 1 else f"{value:,.0f}"


def write_report(result: dict) -> Path:
    icon = {"passed": "✅", "failed": "❌", "error": "💥"}.get(result["status"], "")
    lines = [
        f"## Run {result['run_id']} · {result['mode']} · as of {result['as_of_date']} · {icon} {result['status']}",
        "",
    ]
    if result.get("error_message"):
        lines += [f"> {result['error_message']}", ""]
    if result["checks"]:
        lines += ["| Check | Severity | Result | Legacy | Warehouse | Detail |", "|---|---|---|---:|---:|---|"]
        for c in result["checks"]:
            mark = "✅" if c["passed"] else ("❌" if c["severity"] == "critical" else "⚠️")
            lines.append(
                f"| {c['check_name']} | {c['severity']} | {mark} | {_number(c['legacy_value'])} | "
                f"{_number(c['dw_value'])} | {c['detail'] or ''} |"
            )
        lines.append("")
    if result["steps"]:
        lines += ["| Step | Rows | ms |", "|---|---:|---:|"]
        lines += [f"| {s['step']} | {s['rows_affected']:,} | {s['ms']:,} |" for s in result["steps"]]
        lines.append("")
    if result["rejected"]:
        lines += ["| Rejected (waiting for a fix at the source) | Table | Records | Money involved |", "|---|---|---:|---:|"]
        lines += [
            f"| {r['reason']} | {r['source_table']} | {r['records']:,} | {_number(r['amount'])} |" for r in result["rejected"]
        ]
        lines.append("")
    REPORTS.mkdir(exist_ok=True)
    path = REPORTS / f"run_{result['run_id']}.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    (REPORTS / "latest.md").write_text("\n".join(lines), encoding="utf-8")
    return path

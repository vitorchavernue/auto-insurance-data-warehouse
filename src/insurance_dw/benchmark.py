"""Before and after: the legacy loss ratio report versus the same report on the warehouse.

What it measures, for each version, on a cold cache (data pages removed from memory first, so
both start from disk):
- elapsed time;
- logical reads (8 KB pages read): the work the server does, independent of the machine;
- CPU time.
Then it compares the two results line by line. The point is not only "faster": the warehouse
must give exactly the same numbers as the report the business already trusts.
"""

from __future__ import annotations

import time
from datetime import date
from decimal import Decimal
from pathlib import Path

from insurance_dw.db import DW_DB, LEGACY_DB, connect, query

SESSION_STATS = "SELECT cpu_time, logical_reads FROM sys.dm_exec_sessions WHERE session_id = @@SPID"

LEGACY_SQL = "EXEC dbo.usp_RelatorioSinistralidade @Ano = %s, @DataFechamento = %s"
WAREHOUSE_SQL = """
SELECT year AS Ano, month AS Mes, category_code AS Categoria, coverage_code AS Cobertura,
       earned_premium AS PremioGanho, incurred_claims AS SinistroIncorrido, claim_count AS QtdSinistros
FROM mart.vw_loss_ratio_monthly
WHERE year = %s AND month_start <= (SELECT date_value FROM etl.control WHERE name = 'earned_closed_through')
ORDER BY month, category_code, coverage_code
"""


def _measure(database: str, sql: str, params: tuple) -> tuple[list[dict], dict]:
    with connect(database) as conn:
        cursor = conn.cursor()
        cursor.execute("CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;")  # cold cache for a fair comparison
        before = query(conn, SESSION_STATS)[0]
        started = time.perf_counter()
        rows = query(conn, sql, params)
        elapsed = time.perf_counter() - started
        after = query(conn, SESSION_STATS)[0]
    return rows, {
        "seconds": round(elapsed, 2),
        "logical_reads": after["logical_reads"] - before["logical_reads"],
        "cpu_ms": after["cpu_time"] - before["cpu_time"],
    }


def compare(legacy: list[dict], warehouse: list[dict]) -> list[str]:
    """Differences between the two results (empty = identical). Rows missing on one side count as zero."""

    def index(rows):
        return {(r["Mes"], r["Categoria"], r["Cobertura"]): r for r in rows}

    zero = {"PremioGanho": Decimal(0), "SinistroIncorrido": Decimal(0), "QtdSinistros": 0}
    a, b = index(legacy), index(warehouse)
    problems = []
    for key in sorted(set(a) | set(b)):
        x, y = a.get(key, zero), b.get(key, zero)
        for field in ("PremioGanho", "SinistroIncorrido", "QtdSinistros"):
            if Decimal(x[field] or 0) != Decimal(y[field] or 0):
                problems.append(f"{key} {field}: legacy {x[field]} vs warehouse {y[field]}")
    return problems


def run_benchmark(year: int, closing: date) -> dict:
    legacy_rows, legacy = _measure(LEGACY_DB, LEGACY_SQL, (year, closing))
    dw_rows, warehouse = _measure(DW_DB, WAREHOUSE_SQL, (year,))
    result = {
        "year": year,
        "closing": closing,
        "rows": len(legacy_rows),
        "legacy": legacy,
        "warehouse": warehouse,
        "differences": compare(legacy_rows, dw_rows),
    }
    write_report(result)
    return result


def write_report(result: dict) -> Path:
    legacy, warehouse = result["legacy"], result["warehouse"]

    def times(metric):
        return f"{legacy[metric] / warehouse[metric]:,.0f}x less" if warehouse[metric] else "-"

    same = "✅ identical" if not result["differences"] else f"❌ {len(result['differences'])} differences"
    lines = [
        f"## Loss ratio report {result['year']} (months closed through {result['closing']}): legacy vs warehouse",
        "",
        "| | Legacy report (OLTP, scalar functions) | Warehouse (star schema, columnstore) | |",
        "|---|---:|---:|---:|",
        f"| Elapsed time (s) | {legacy['seconds']:,} | {warehouse['seconds']:,} | {times('seconds')} |",
        f"| Logical reads (8 KB pages) | {legacy['logical_reads']:,} | {warehouse['logical_reads']:,} "
        f"| {times('logical_reads')} |",
        f"| CPU time (ms) | {legacy['cpu_ms']:,} | {warehouse['cpu_ms']:,} | {times('cpu_ms')} |",
        "",
        f"Result: {result['rows']} lines (month x category x coverage) — {same}.",
        "",
    ]
    lines += [f"- {p}" for p in result["differences"][:20]]
    Path("reports").mkdir(exist_ok=True)
    path = Path("reports") / "benchmark.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path

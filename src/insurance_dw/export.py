"""Exports the Power BI feed (the pbi views of the warehouse) as Parquet files.

What: one file per view, with the business column names the dashboard uses. Money is written as
fixed decimals (never floating point), so the dashboard shows the same cents as the warehouse.

Why files: the dashboard in the repository opens anywhere (Power BI Desktop reads the folder),
without access to the database. In production the same views are read directly by the gateway.
"""

from __future__ import annotations

from decimal import Decimal
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

from insurance_dw.db import DW_DB, connect

# view -> file name (the dashboard tables)
VIEWS = {
    "vw_date": "date",
    "vw_coverage": "coverage",
    "vw_product": "product",
    "vw_broker": "broker",
    "vw_geography": "geography",
    "vw_vehicle_profile": "vehicle_profile",
    "vw_earned_premium": "earned_premium",
    "vw_written_premium": "written_premium",
    "vw_claims": "claims",
    "vw_claim_movements": "claim_movements",
    "vw_renewals": "renewals",
}
MONEY = pa.decimal128(18, 2)
# earned premium is a daily pro rata kept with 6 decimals (rounded only when shown), exposure with 4
PRECISE = {"Earned Premium": pa.decimal128(24, 6), "Exposure Years": pa.decimal128(18, 4)}


def _to_arrow(columns: list[str], rows: list[tuple]) -> pa.Table:
    """Builds the Arrow table column by column; money keeps 2 decimal places (earned premium 6)."""
    arrays = {}
    for i, name in enumerate(columns):
        values = [row[i] for row in rows]
        sample = next((v for v in values if v is not None), None)
        if isinstance(sample, Decimal):
            arrays[name] = pa.array(values, type=PRECISE.get(name, MONEY))
        else:
            arrays[name] = pa.array(values)
    return pa.table(arrays)


def export(out: str | Path) -> dict[str, int]:
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    counts = {}
    with connect(DW_DB) as conn:
        cursor = conn.cursor()
        for view, name in VIEWS.items():
            cursor.execute(f"SELECT * FROM pbi.{view}")
            columns = [d[0] for d in cursor.description]
            rows = cursor.fetchall()
            pq.write_table(_to_arrow(columns, rows), out / f"{name}.parquet", compression="zstd")
            counts[name] = len(rows)
    return counts

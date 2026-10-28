"""Creates both databases from scratch and runs every SQL script in order.

Development and CI only: existing databases are dropped first. The legacy database is set to
compatibility level 110 (SQL Server 2012, as the original system), the warehouse to 160
(SQL Server 2022, which enables batch mode on columnstore and scalar function inlining).
"""

from __future__ import annotations

from insurance_dw import seed as seed_mod
from insurance_dw.db import DW_DB, LEGACY_DB, SQL_DIR, connect, run_script


def recreate_database(name: str, compatibility_level: int) -> None:
    with connect("master") as conn:
        cursor = conn.cursor()
        cursor.execute(
            f"IF DB_ID('{name}') IS NOT NULL BEGIN "
            f"ALTER DATABASE [{name}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{name}]; END"
        )
        cursor.execute(f"CREATE DATABASE [{name}]")
        cursor.execute(f"ALTER DATABASE [{name}] SET RECOVERY SIMPLE")  # no log backups needed for a demo warehouse
        cursor.execute(f"ALTER DATABASE [{name}] SET COMPATIBILITY_LEVEL = {compatibility_level}")


def deploy() -> None:
    # 1. Legacy system: tables and the original report
    recreate_database(LEGACY_DB, 110)
    with connect(LEGACY_DB) as conn:
        for path in sorted((SQL_DIR / "legacy").glob("*.sql")):
            run_script(conn, path)

    # 2. Warehouse: schemas, ODS, star schema, ETL procedures, data quality, marts
    recreate_database(DW_DB, 160)
    with connect(DW_DB) as conn:
        for path in sorted((SQL_DIR / "dw").glob("*.sql")):
            run_script(conn, path)


def load_legacy(scale: float = 1.0) -> dict[str, int]:
    """Fills the legacy system with the data it holds on the day of the first load."""
    world = seed_mod.generate(scale=scale)
    rows = seed_mod.snapshot(world, seed_mod.FIRST_LOAD)
    with connect(LEGACY_DB) as conn:
        for table, values in rows.items():
            insert_rows(conn, table, values)
    return {table: len(values) for table, values in rows.items()}


def apply_month_of_activity(scale: float = 1.0) -> dict[str, int]:
    """One month of business in the legacy system: new and renewed policies, cancellations,
    customers moving, claims reported and paid, records fixed at the branches."""
    world = seed_mod.generate(scale=scale)
    changed = seed_mod.changes(world, seed_mod.FIRST_LOAD, seed_mod.MONTH_LATER)
    with connect(LEGACY_DB) as conn:
        for table, values in changed.items():
            replace_rows(conn, table, values)
    return {table: len(values) for table, values in changed.items()}


def insert_rows(conn, table: str, rows: list[tuple]) -> None:
    """Multi-row INSERTs (SQL Server accepts up to 1,000 rows per VALUES list)."""
    if not rows:
        return
    columns = seed_mod.TABLES[table]
    placeholders = "(" + ",".join(["%s"] * len(columns)) + ")"
    cursor = conn.cursor()
    for start in range(0, len(rows), 1000):
        chunk = rows[start : start + 1000]
        sql = f"INSERT INTO dbo.{table} ({','.join(columns)}) VALUES " + ",".join([placeholders] * len(chunk))
        cursor.execute(sql, tuple(value for row in chunk for value in row))


def replace_rows(conn, table: str, rows: list[tuple]) -> None:
    """Changed rows are written as delete + insert by primary key (the legacy system has no
    triggers or history, so for the warehouse this is the same as an update in place)."""
    if not rows:
        return
    columns = seed_mod.TABLES[table]
    width = seed_mod.KEYS.get(table, 1)
    keys = columns[:width]
    cursor = conn.cursor()
    for start in range(0, len(rows), 500):
        chunk = rows[start : start + 500]
        condition = " OR ".join("(" + " AND ".join(f"{k} = %s" for k in keys) + ")" for _ in chunk)
        cursor.execute(f"DELETE FROM dbo.{table} WHERE {condition}", tuple(v for row in chunk for v in row[:width]))
    insert_rows(conn, table, rows)

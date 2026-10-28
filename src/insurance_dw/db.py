"""Connection to SQL Server and execution of the .sql scripts.

The project has two databases on the same server:
- SeguroLegado: the legacy policy system (source, read-only for the warehouse)
- SeguroDW: the warehouse (ODS, star schema, ETL procedures, data quality, marts)

The connection settings come from environment variables (see .env.example), so the same code
runs on a laptop, in Docker and in CI.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import pymssql

LEGACY_DB = "SeguroLegado"
DW_DB = "SeguroDW"
SQL_DIR = Path(__file__).resolve().parents[2] / "sql"

# A batch separator is a line containing only GO (the sqlcmd / SSMS convention)
_GO = re.compile(r"^\s*GO\s*$", re.IGNORECASE | re.MULTILINE)


def connect(database: str = "master", autocommit: bool = True) -> pymssql.Connection:
    return pymssql.connect(
        server=os.environ.get("MSSQL_HOST", "localhost"),
        port=int(os.environ.get("MSSQL_PORT", "1433")),
        user=os.environ.get("MSSQL_USER", "sa"),
        password=os.environ["MSSQL_PASSWORD"],
        database=database,
        autocommit=autocommit,
        login_timeout=30,
        timeout=0,  # no query timeout: the legacy report can take minutes on purpose
    )


def batches(script: str) -> list[str]:
    """Splits a script into the batches SQL Server executes one at a time."""
    return [b.strip() for b in _GO.split(script) if b.strip()]


def run_script(conn: pymssql.Connection, path: Path) -> None:
    cursor = conn.cursor()
    for batch in batches(path.read_text(encoding="utf-8")):
        try:
            cursor.execute(batch)
        except pymssql.Error as exc:  # say which file and batch failed, not only the server message
            first_line = batch.splitlines()[0][:80]
            raise RuntimeError(f"{path.name}: batch starting with '{first_line}' failed: {exc}") from exc
        while cursor.nextset():  # drain any result sets so the next batch can run
            pass


def query(conn: pymssql.Connection, sql: str, params: tuple | dict | None = None) -> list[dict]:
    cursor = conn.cursor(as_dict=True)
    cursor.execute(sql, params)
    return cursor.fetchall()

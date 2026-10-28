# ADR 0002 — ETL in T-SQL stored procedures, one transaction per run

**Status:** accepted

## Context

Source and target are SQL Server databases on the same instance. The team that supports the warehouse knows
T-SQL and SQL Server Agent. A failed night must be easy to recover from without manual cleanup.

Options considered:

1. **SSIS packages.** Good for heterogeneous sources and file handling; here every step is a set-based SQL statement
   between two databases on the same server, so the package would only call SQL. Packages are also harder to review
   in Git and to test automatically.
2. **An external orchestrator (Python, Airflow) running SQL.** Adds infrastructure for a single-server workload.
3. **Stored procedures called by one orchestrator procedure, scheduled by SQL Server Agent.** Chosen.

## Decision

- Each step is a stored procedure (`etl.usp_load_ods_*`, `etl.usp_load_dim_*`, `etl.usp_load_facts`,
  `dq.usp_run_checks`); `etl.usp_run` calls them in dependency order.
- The whole run is **one transaction** with `XACT_ABORT ON`. On any error everything is rolled back, watermarks
  included, and the run is recorded as `error` with the procedure, line and message. The next run simply reads the
  same changes again.
- The run is **incremental by watermark** (the legacy "changed at" column, 5-minute overlap) and **idempotent**
  (`MERGE` only touches rows whose values changed; facts of changed policies are deleted and inserted again).
- The data quality gate runs inside the same transaction; its result decides `passed` or `failed`.
- The Agent job step fails when the status is not `passed`, so the standard Agent alerting notifies the operators.
- Python is used only around the database: synthetic data, deployment, tests and the benchmark.

## Consequences

- The load is reviewed and versioned as plain `.sql` files and tested on a real SQL Server in CI.
- A long transaction holds locks on the warehouse tables during the load; acceptable at night, and readers can use
  read committed snapshot isolation if the load ever overlaps working hours.
- If sources outside SQL Server are added (files, APIs), an orchestrator or SSIS for those extractions can feed
  the ODS; the procedures from the ODS onward do not change.

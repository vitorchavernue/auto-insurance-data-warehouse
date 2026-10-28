# Runbook — SeguroDW nightly load

## Schedule

SQL Server Agent job **"SeguroDW - nightly load"** runs `etl.usp_run` every night at 02:30, closing the previous
day. An incremental run takes a few seconds at the current volume; a full run about a minute.

## Checking the night

```sql
-- Last runs and their status
SELECT TOP (10) run_id, as_of_date, mode, status, started_at, finished_at, error_message
FROM etl.run ORDER BY run_id DESC;

-- Checks of the last run
SELECT check_name, severity, passed, legacy_value, dw_value, detail
FROM dq.check_result WHERE run_id = (SELECT MAX(run_id) FROM etl.run) ORDER BY check_order;

-- Rows touched by each step
SELECT step, rows_affected, DATEDIFF(MILLISECOND, started_at, finished_at) AS ms
FROM etl.step_log WHERE run_id = (SELECT MAX(run_id) FROM etl.run) ORDER BY started_at;
```

## When the job fails

| Status | Meaning | What to do |
|---|---|---|
| `error` | The run stopped and **everything was rolled back** (watermarks included). The warehouse still shows the previous night. | Read `error_message` (procedure, line, message). Fix the cause (space, permissions, a changed legacy column) and run again: `EXEC etl.usp_run @as_of_date = '<date>'`. It picks up the same changes. |
| `failed` | Data loaded, but a critical check did not pass. **Reports must not be refreshed.** | Look at the failed check. Differences in money usually mean someone changed the warehouse by hand or a legacy table changed meaning. After finding the cause, rebuild from the legacy system: `EXEC etl.usp_run @as_of_date = '<date>', @mode = 'full'`. |

A full run re-reads every legacy row and rebuilds every fact. History of the customer dimension is preserved.

## Rejected records

```sql
SELECT source_table, reason, COUNT(*) AS records, SUM(amount) AS amount
FROM etl.rejected_row WHERE resolved_run_id IS NULL
GROUP BY source_table, reason;
```

The list (with the legacy row in `payload`) goes to the owners: claims typed with a wrong policy number and payments
for claims that do not exist to the **claims team**; coverages with zero premium to **underwriting**. They are fixed
in the legacy system; the next run retries them and marks them resolved.

Flagged, not rejected (the money is real and stays in the numbers): customers with an invalid CPF
(`ods.customer.cpf_is_valid = 0`, registration team) and claims outside the policy period
(`dw.fact_claim.is_outside_policy_period = 1`, claims team).

## Adding a new spelling of a vehicle category

Vehicles with an unknown category are loaded as `OUTROS`. Add the spelling to the mapping table and run a full load:

```sql
INSERT INTO etl.map_vehicle_category (typed_value, category_code) VALUES (N'MOTONETA', 'MOTO');
EXEC etl.usp_run @mode = 'full';
```

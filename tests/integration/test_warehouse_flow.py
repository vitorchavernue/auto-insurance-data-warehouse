"""The full life of the warehouse, in order, against a real SQL Server.

first load -> running again changes nothing -> one month of business in the legacy system ->
incremental load (customer history, late cancellations, late claims, fixed records) ->
the warehouse gives the same numbers as the legacy report -> a manual edit in the warehouse
is caught by the gate -> a full run repairs it -> the nightly SQL Agent job can be created.
The tests share one database and depend on the order of this file.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

from insurance_dw import benchmark, deploy, run
from insurance_dw.db import DW_DB, SQL_DIR, connect, query, run_script
from insurance_dw.seed import FIRST_LOAD, MONTH_LATER


def dw(sql: str, params=None) -> list[dict]:
    with connect(DW_DB) as conn:
        return query(conn, sql, params)


def scalar(sql: str, params=None):
    """First column of the first row (works for unnamed columns such as COUNT(*))."""
    with connect(DW_DB) as conn:
        cursor = conn.cursor()
        cursor.execute(sql, params)
        return cursor.fetchone()[0]


def failed_checks(result: dict) -> list[str]:
    return [f"{c['check_name']}: {c['detail']}" for c in result["checks"] if c["severity"] == "critical" and not c["passed"]]


@pytest.fixture(scope="module")
def first_run(legacy_loaded):
    return run.run_etl(FIRST_LOAD, "full")


def test_first_load_passes_the_gate(first_run, legacy_loaded):
    assert first_run["status"] == "passed", first_run.get("error_message") or failed_checks(first_run)
    assert scalar("SELECT COUNT(*) FROM dw.fact_claim") > 0
    # Earned premium exists for every closed month up to September 2026, and not after
    assert scalar("SELECT MAX(month_key) FROM dw.fact_earned_premium_monthly") == 20260901


def test_running_again_changes_nothing(first_run):
    again = run.run_etl(FIRST_LOAD, "incremental")
    assert again["status"] == "passed"
    touched = {s["step"]: s["rows_affected"] for s in again["steps"] if s["step"] != "dq.checks"}
    assert set(touched.values()) == {0}, touched


def test_bad_records_are_rejected_with_a_reason_and_their_money(first_run):
    reasons = {r["reason"] for r in first_run["rejected"]}
    assert reasons == {
        "premium zero or negative",
        "policy does not exist in the legacy system or was not loaded",
        "claim does not exist in the legacy system or was rejected",
    }
    # payments recorded against claims that do not exist are kept with their amount
    assert scalar("SELECT SUM(amount) FROM etl.rejected_row WHERE source_table = 'SinistroMovimento'") > 0


def test_cleaning_rules(first_run):
    # CPF typed as a number that lost its leading zeros is repaired to 11 digits
    assert scalar("SELECT COUNT(*) FROM ods.customer WHERE cpf IS NOT NULL AND LEN(cpf) <> 11") == 0
    assert scalar("SELECT COUNT(*) FROM ods.customer WHERE cpf LIKE '0%'") > 0
    # invalid CPFs are flagged, not dropped
    assert scalar("SELECT COUNT(*) FROM ods.customer WHERE cpf_is_valid = 0") > 0
    # every hand-typed vehicle category is mapped to the standard list
    assert {r["category_code"] for r in dw("SELECT DISTINCT category_code FROM ods.vehicle")} == {"AUTO", "MOTO", "CAMINHAO"}
    # birth date placeholders become unknown instead of a wrong age
    assert scalar("SELECT COUNT(*) FROM ods.customer WHERE birth_date IS NULL") > 0
    # an invalid state code goes to the Unknown region and is counted in the report
    assert scalar("SELECT COUNT(*) FROM dw.fact_written_premium WHERE geography_key = -1") > 0


@pytest.fixture(scope="module")
def month_later(first_run, scale):
    with connect(DW_DB) as conn:  # September earned premium of policies cancelled late, before the run
        before = query(
            conn,
            "SELECT p.NrApolice AS policy_number, SUM(f.earned_premium) AS earned FROM SeguroLegado.dbo.Apolice AS p "
            "JOIN dw.fact_earned_premium_monthly AS f ON f.policy_number = p.NrApolice AND f.month_key = 20260901 "
            "WHERE p.DtCancelamento IS NULL GROUP BY p.NrApolice",
        )
    activity = deploy.apply_month_of_activity(scale)
    result = run.run_etl(MONTH_LATER, "incremental")
    return {"result": result, "activity": activity, "september_before": {r["policy_number"]: r["earned"] for r in before}}


def test_incremental_run_after_a_month_of_business(month_later):
    result = month_later["result"]
    assert result["status"] == "passed", result.get("error_message") or failed_checks(result)
    steps = {s["step"]: s["rows_affected"] for s in result["steps"]}
    # only what changed is read: far fewer customers than the whole base
    assert 0 < steps["ods.customer"] <= month_later["activity"]["Segurado"]
    assert scalar("SELECT MAX(month_key) FROM dw.fact_earned_premium_monthly") == 20261001


def test_customer_who_moved_keeps_the_old_address_for_old_policies(month_later):
    moved = dw("SELECT TOP 1 customer_id FROM dw.dim_customer GROUP BY customer_id HAVING COUNT(*) = 2 ORDER BY customer_id")
    assert moved, "no customer history was created"
    versions = dw(
        "SELECT state_code, city, valid_from, valid_to, is_current FROM dw.dim_customer "
        "WHERE customer_id = %s ORDER BY valid_from",
        (moved[0]["customer_id"],),
    )
    old, new = versions
    assert old["valid_to"] == new["valid_from"] and old["is_current"] is False and new["is_current"] is True
    assert new["valid_from"] >= date(2026, 10, 1)
    # policies that started before the move still point to the old version
    assert (
        scalar(
            "SELECT COUNT(*) FROM dw.fact_written_premium AS f JOIN dw.dim_customer AS c ON c.customer_key = f.customer_key "
            "WHERE c.customer_id = %s AND c.is_current = 1 AND f.start_date_key < 20261001",
            (moved[0]["customer_id"],),
        )
        == 0
    )


def test_cancellation_recorded_late_reduces_the_premium_already_earned(month_later):
    cancelled = dw(
        "SELECT NrApolice AS policy_number FROM SeguroLegado.dbo.Apolice "
        "WHERE DtCancelamento < '20261001' AND DtAlteracao >= '20261001'"
    )
    cancelled = [r["policy_number"] for r in cancelled if r["policy_number"] in month_later["september_before"]]
    assert cancelled, "no backdated cancellation in the month of activity"
    for policy in cancelled:
        after = scalar(
            "SELECT ISNULL(SUM(earned_premium), 0) FROM dw.fact_earned_premium_monthly "
            "WHERE policy_number = %s AND month_key = 20260901",
            (policy,),
        )
        assert after < month_later["september_before"][policy]


def test_fixed_records_leave_the_rejected_list(month_later):
    resolved = scalar("SELECT COUNT(*) FROM etl.rejected_row WHERE resolved_run_id IS NOT NULL")
    assert resolved > 0  # claims typed with a wrong policy number, fixed at the branch in October


def test_warehouse_gives_the_same_numbers_as_the_legacy_report(month_later):
    result = benchmark.run_benchmark(2026, MONTH_LATER)
    assert result["rows"] > 0
    assert result["differences"] == []
    assert result["warehouse"]["logical_reads"] < result["legacy"]["logical_reads"]


def test_a_manual_edit_in_the_warehouse_fails_the_gate_and_a_full_run_repairs_it(month_later):
    with connect(DW_DB) as conn:
        conn.cursor().execute(
            "UPDATE TOP (1) dw.fact_written_premium SET written_premium = written_premium + 100 WHERE coverage_key > 0"
        )
    caught = run.run_etl(MONTH_LATER, "incremental")
    assert caught["status"] == "failed"
    assert "Written premium matches the legacy system" in " ".join(failed_checks(caught))

    repaired = run.run_etl(MONTH_LATER, "full")
    assert repaired["status"] == "passed", failed_checks(repaired)


def test_an_error_rolls_the_whole_run_back(month_later):
    watermark = scalar("SELECT last_changed_at FROM etl.watermark WHERE source_table = 'Segurado'")
    with connect(DW_DB) as conn:  # break one step on purpose
        conn.cursor().execute("EXEC sp_rename 'dw.fact_claim_movement', 'fact_claim_movement_hidden'")
    try:
        broken = run.run_etl(MONTH_LATER, "full")
    finally:
        with connect(DW_DB) as conn:
            conn.cursor().execute("EXEC sp_rename 'dw.fact_claim_movement_hidden', 'fact_claim_movement'")
    assert broken["status"] == "error" and broken["error_message"]
    assert scalar("SELECT COUNT(*) FROM etl.step_log WHERE run_id = %s", (broken["run_id"],)) == 0
    assert scalar("SELECT last_changed_at FROM etl.watermark WHERE source_table = 'Segurado'") == watermark
    assert run.run_etl(MONTH_LATER, "incremental")["status"] == "passed"


def test_marts_answer_the_business_questions(month_later):
    renewal = dw("SELECT renewal_rate FROM mart.vw_renewal_rate_monthly WHERE year = 2025")
    assert renewal and all(Decimal("0.5") < r["renewal_rate"] < Decimal("0.95") for r in renewal)
    theft = dw("SELECT category_name, SUM(theft_claims) AS n FROM mart.vw_theft_recovery GROUP BY category_name")
    assert {r["category_name"] for r in theft} >= {"Car", "Motorcycle"}
    brokers = dw("SELECT COUNT(*) AS n FROM mart.vw_broker_scorecard WHERE year = 2026")
    assert brokers[0]["n"] > 10


def test_powerbi_feed_reconciles_with_the_warehouse(month_later, tmp_path):
    import pyarrow.parquet as pq

    from insurance_dw import export

    counts = export.export(tmp_path)
    assert all(n > 0 for n in counts.values()), counts

    def total(name, column):
        return sum(v for v in pq.read_table(tmp_path / f"{name}.parquet").column(column).to_pylist() if v is not None)

    # the summarised files add up to the facts: premium and claim money to the cent
    assert total("written_premium", "Written Premium") == scalar("SELECT SUM(written_premium) FROM dw.fact_written_premium")
    assert total("claim_movements", "Incurred Claims") == scalar("SELECT SUM(incurred_change) FROM dw.fact_claim_movement")
    assert counts["claims"] == scalar("SELECT COUNT(*) FROM dw.fact_claim")
    # earned premium keeps its 6 decimals: the total matches exactly
    assert total("earned_premium", "Earned Premium") == scalar("SELECT SUM(earned_premium) FROM dw.fact_earned_premium_monthly")
    # policies are counted once even when they have several coverages
    assert total("written_premium", "Policies") == scalar("SELECT COUNT(DISTINCT policy_number) FROM dw.fact_written_premium")
    # no personal data in the feed
    columns = {c for name in counts for c in pq.read_schema(tmp_path / f"{name}.parquet").names}
    assert not {"CPF", "Customer", "Plate", "Full Name"} & columns


def test_the_nightly_agent_job_can_be_created(month_later):
    agent = dw(
        "SELECT COUNT(*) AS n FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%%' AND status_desc = 'Running'"
    )
    if not agent[0]["n"]:
        pytest.skip("SQL Server Agent is not running on this server")
    with connect("msdb") as conn:
        run_script(conn, SQL_DIR / "jobs" / "nightly_job.sql")
        jobs = query(conn, "SELECT name, enabled FROM dbo.sysjobs WHERE name = 'SeguroDW - nightly load'")
    assert jobs and jobs[0]["enabled"] == 1

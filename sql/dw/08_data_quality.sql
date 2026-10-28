/* =====================================================================================
   SeguroDW - data quality checks (release gate)
   -------------------------------------------------------------------------------------
   What: after every load, the warehouse is checked against the legacy system and against
   its own rules. Critical checks decide if the run is released ("passed") or not
   ("failed": the data stays loaded for investigation, but reports must not use it).
   Info checks are reported for the business teams and never stop a run.

   Why: "the job finished" does not prove the numbers are right. A check that compares
   the warehouse with the source is what the finance and actuarial teams can trust.
   ===================================================================================== */

CREATE TABLE dq.check_result (
    run_id       INT            NOT NULL,
    check_order  TINYINT        NOT NULL,
    check_name   VARCHAR(100)   NOT NULL,
    severity     VARCHAR(10)    NOT NULL,  -- critical | info
    passed       BIT            NOT NULL,
    legacy_value DECIMAL(18,2)  NULL,
    dw_value     DECIMAL(18,2)  NULL,
    detail       NVARCHAR(400)  NULL,
    CONSTRAINT pk_check_result PRIMARY KEY (run_id, check_name)
);
GO

CREATE OR ALTER PROCEDURE dq.usp_run_checks @run_id INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3) = SYSDATETIME();
    DECLARE @legacy DECIMAL(18,2), @dw DECIMAL(18,2), @rejected DECIMAL(18,2), @n INT;
    DECLARE @closed DATE = (SELECT date_value FROM etl.control WHERE name = 'earned_closed_through');
    DECLARE @closed_end DATE = DATEADD(MONTH, 1, @closed);  -- first day after the last closed month

    /* 1. Every legacy policy coverage is in the warehouse or in the rejected list */
    SELECT @legacy = COUNT(*) FROM SeguroLegado.dbo.ApoliceCobertura;
    SELECT @dw = COUNT(*) FROM dw.fact_written_premium;
    SELECT @rejected = COUNT(*) FROM etl.rejected_row WHERE source_table = 'ApoliceCobertura' AND resolved_run_id IS NULL;
    INSERT INTO dq.check_result VALUES (@run_id, 1, 'Every policy coverage is loaded or rejected', 'critical',
        CASE WHEN @legacy = @dw + @rejected THEN 1 ELSE 0 END, @legacy, @dw,
        CONCAT(FORMAT(@dw, 'N0'), ' loaded + ', FORMAT(@rejected, 'N0'), ' rejected'));

    /* 2. Written premium: not one cent lost or invented */
    SELECT @legacy = SUM(VlPremioLiquido) FROM SeguroLegado.dbo.ApoliceCobertura;
    SELECT @dw = SUM(written_premium) FROM dw.fact_written_premium;
    SELECT @rejected = ISNULL(SUM(amount), 0) FROM etl.rejected_row WHERE source_table = 'ApoliceCobertura' AND resolved_run_id IS NULL;
    INSERT INTO dq.check_result VALUES (@run_id, 2, 'Written premium matches the legacy system', 'critical',
        CASE WHEN @legacy = @dw + @rejected THEN 1 ELSE 0 END, @legacy, @dw + @rejected,
        CONCAT('difference ', FORMAT(@legacy - @dw - @rejected, 'N2')));

    /* 3. Earned premium matches an independent calculation made directly on the legacy tables
          (one formula per coverage over the whole period, instead of month by month).
          Tolerance of R$ 1.00 for the whole portfolio: each month is kept with 6 decimals. */
    SELECT @legacy = SUM(CAST(CAST(c.VlPremioLiquido AS DECIMAL(18,6))
                         * DATEDIFF(DAY, a.DtInicioVigencia, x.until) / DATEDIFF(DAY, a.DtInicioVigencia, a.DtFimVigencia) AS DECIMAL(18,6)))
    FROM SeguroLegado.dbo.ApoliceCobertura AS c
    JOIN SeguroLegado.dbo.Apolice AS a ON a.NrApolice = c.NrApolice
    CROSS APPLY (SELECT CASE WHEN ISNULL(a.DtCancelamento, a.DtFimVigencia) < CAST(@closed_end AS DATETIME)
                             THEN ISNULL(a.DtCancelamento, a.DtFimVigencia) ELSE CAST(@closed_end AS DATETIME) END AS until) AS x
    WHERE c.VlPremioLiquido > 0 AND x.until > a.DtInicioVigencia;
    SELECT @dw = SUM(earned_premium) FROM dw.fact_earned_premium_monthly;
    INSERT INTO dq.check_result VALUES (@run_id, 3, 'Earned premium matches a recalculation from the legacy system', 'critical',
        CASE WHEN ABS(ISNULL(@legacy, 0) - ISNULL(@dw, 0)) <= 1.00 THEN 1 ELSE 0 END, @legacy, @dw,
        CONCAT('months closed through ', CONVERT(CHAR(7), @closed, 126)));

    /* 4. No policy coverage earns more than its premium */
    SELECT @n = COUNT(*)
    FROM (SELECT f.policy_number, f.coverage_key, SUM(f.earned_premium) AS earned
          FROM dw.fact_earned_premium_monthly AS f GROUP BY f.policy_number, f.coverage_key) AS e
    JOIN dw.fact_written_premium AS w ON w.policy_number = e.policy_number AND w.coverage_key = e.coverage_key
    WHERE e.earned > w.written_premium + 0.01;
    INSERT INTO dq.check_result VALUES (@run_id, 4, 'No coverage earns more than its premium', 'critical',
        CASE WHEN @n = 0 THEN 1 ELSE 0 END, NULL, @n, CONCAT(@n, ' coverages above their premium'));

    /* 5. Every legacy claim is loaded or rejected */
    SELECT @legacy = COUNT(*) FROM SeguroLegado.dbo.Sinistro;
    SELECT @dw = COUNT(*) FROM dw.fact_claim;
    SELECT @rejected = COUNT(*) FROM etl.rejected_row WHERE source_table = 'Sinistro' AND resolved_run_id IS NULL;
    INSERT INTO dq.check_result VALUES (@run_id, 5, 'Every claim is loaded or rejected', 'critical',
        CASE WHEN @legacy = @dw + @rejected THEN 1 ELSE 0 END, @legacy, @dw,
        CONCAT(FORMAT(@dw, 'N0'), ' loaded + ', FORMAT(@rejected, 'N0'), ' rejected'));

    /* 6. Claim money (reserves, payments, recoveries) matches the legacy system */
    SELECT @legacy = SUM(VlMovimento) FROM SeguroLegado.dbo.SinistroMovimento;
    SELECT @dw = SUM(amount) FROM dw.fact_claim_movement;
    SELECT @rejected = ISNULL(SUM(amount), 0) FROM etl.rejected_row WHERE source_table = 'SinistroMovimento' AND resolved_run_id IS NULL;
    INSERT INTO dq.check_result VALUES (@run_id, 6, 'Claim movements match the legacy system', 'critical',
        CASE WHEN @legacy = @dw + @rejected THEN 1 ELSE 0 END, @legacy, @dw + @rejected,
        CONCAT('difference ', FORMAT(@legacy - @dw - @rejected, 'N2')));

    /* 7. Claim totals agree with their movements (the two claim facts tell the same story) */
    SELECT @n = COUNT(*)
    FROM dw.fact_claim AS c
    LEFT JOIN (SELECT claim_number, SUM(incurred_change) AS incurred FROM dw.fact_claim_movement GROUP BY claim_number) AS m
           ON m.claim_number = c.claim_number
    WHERE c.incurred_amount <> ISNULL(m.incurred, 0);
    INSERT INTO dq.check_result VALUES (@run_id, 7, 'Claim totals agree with their movements', 'critical',
        CASE WHEN @n = 0 THEN 1 ELSE 0 END, NULL, @n, CONCAT(@n, ' claims with different totals'));

    /* 8. Customer history is consistent: one current version, no gaps or overlaps */
    SELECT @n = COUNT(*) FROM (
        SELECT customer_id FROM dw.dim_customer WHERE customer_key > 0 GROUP BY customer_id HAVING SUM(CAST(is_current AS INT)) <> 1
        UNION ALL
        SELECT customer_id FROM (
            SELECT customer_id, valid_to, LEAD(valid_from) OVER (PARTITION BY customer_id ORDER BY valid_from) AS next_from
            FROM dw.dim_customer WHERE customer_key > 0
        ) AS v WHERE next_from IS NOT NULL AND next_from <> valid_to
    ) AS problems;
    INSERT INTO dq.check_result VALUES (@run_id, 8, 'Customer address history is consistent', 'critical',
        CASE WHEN @n = 0 THEN 1 ELSE 0 END, NULL, @n, CONCAT(@n, ' customers with broken history'));

    /* 9. Every fact row points to existing dimension rows (no orphan keys) */
    SELECT @n =
        (SELECT COUNT(*) FROM dw.fact_written_premium AS f
         WHERE NOT EXISTS (SELECT 1 FROM dw.dim_customer AS d WHERE d.customer_key = f.customer_key)
            OR NOT EXISTS (SELECT 1 FROM dw.dim_vehicle AS d WHERE d.vehicle_key = f.vehicle_key)
            OR NOT EXISTS (SELECT 1 FROM dw.dim_broker AS d WHERE d.broker_key = f.broker_key)
            OR NOT EXISTS (SELECT 1 FROM dw.dim_product AS d WHERE d.product_key = f.product_key)
            OR NOT EXISTS (SELECT 1 FROM dw.dim_coverage AS d WHERE d.coverage_key = f.coverage_key)
            OR NOT EXISTS (SELECT 1 FROM dw.dim_geography AS d WHERE d.geography_key = f.geography_key)
            OR NOT EXISTS (SELECT 1 FROM dw.dim_date AS d WHERE d.date_key = f.start_date_key))
      + (SELECT COUNT(*) FROM dw.fact_claim AS f
         WHERE NOT EXISTS (SELECT 1 FROM dw.dim_customer AS d WHERE d.customer_key = f.customer_key)
            OR NOT EXISTS (SELECT 1 FROM dw.dim_vehicle AS d WHERE d.vehicle_key = f.vehicle_key)
            OR NOT EXISTS (SELECT 1 FROM dw.dim_geography AS d WHERE d.geography_key = f.geography_key)
            OR NOT EXISTS (SELECT 1 FROM dw.dim_date AS d WHERE d.date_key = f.occurred_date_key));
    INSERT INTO dq.check_result VALUES (@run_id, 9, 'Facts point to existing dimension rows', 'critical',
        CASE WHEN @n = 0 THEN 1 ELSE 0 END, NULL, @n, CONCAT(@n, ' rows with orphan keys'));

    /* 10. Grain of the earned premium fact: one row per coverage per month */
    SELECT @n = COUNT(*) FROM (
        SELECT month_key, policy_number, coverage_key FROM dw.fact_earned_premium_monthly
        GROUP BY month_key, policy_number, coverage_key HAVING COUNT(*) > 1
    ) AS d;
    INSERT INTO dq.check_result VALUES (@run_id, 10, 'Earned premium has one row per coverage per month', 'critical',
        CASE WHEN @n = 0 THEN 1 ELSE 0 END, NULL, @n, CONCAT(@n, ' duplicated rows'));

    /* ---------------------------------------------------------------------------------
       Info: for the business teams (never stop a run)
       --------------------------------------------------------------------------------- */
    SELECT @n = COUNT(*) FROM ods.customer WHERE cpf_is_valid = 0;
    INSERT INTO dq.check_result VALUES (@run_id, 11, 'Customers with an invalid CPF (registration team)', 'info',
        CASE WHEN @n = 0 THEN 1 ELSE 0 END, NULL, @n, CONCAT(@n, ' customers loaded and flagged'));

    SELECT @n = COUNT(*), @dw = ISNULL(SUM(incurred_amount), 0) FROM dw.fact_claim WHERE is_outside_policy_period = 1;
    INSERT INTO dq.check_result VALUES (@run_id, 12, 'Claims outside the policy period (claims team)', 'info',
        CASE WHEN @n = 0 THEN 1 ELSE 0 END, NULL, @dw, CONCAT(@n, ' claims, incurred ', FORMAT(@dw, 'N2')));

    SELECT @n = COUNT(*), @dw = ISNULL(SUM(amount), 0) FROM etl.rejected_row WHERE resolved_run_id IS NULL;
    INSERT INTO dq.check_result VALUES (@run_id, 13, 'Rejected legacy records waiting for a fix', 'info',
        CASE WHEN @n = 0 THEN 1 ELSE 0 END, NULL, @dw, CONCAT(@n, ' records, ', FORMAT(@dw, 'N2'), ' involved'));

    SELECT @n = COUNT(*) FROM dw.fact_written_premium WHERE geography_key = -1;
    INSERT INTO dq.check_result VALUES (@run_id, 14, 'Premium rows with unknown customer state', 'info',
        CASE WHEN @n = 0 THEN 1 ELSE 0 END, NULL, @n, CONCAT(@n, ' rows in the Unknown region'));

    EXEC etl.usp_log_step @run_id, 'dq.checks', 14, @started;
END
GO

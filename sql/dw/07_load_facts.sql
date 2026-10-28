/* =====================================================================================
   SeguroDW - loading the facts
   -------------------------------------------------------------------------------------
   Strategy: rebuild only what changed.
   - A policy is "changed" when the policy or one of its coverages changed in this run
     (new policy, cancellation, correction). Its premium rows are deleted and inserted
     again from the ODS. Deleting and inserting a whole policy is simpler and safer than
     updating row by row, and it makes the load idempotent.
   - A claim is "changed" when the claim, one of its movements or its policy changed.
   - When a customer moves, policies starting and claims happening after the move are
     refreshed too, so they point to the customer version with the new address.
   - Earned premium also grows every time a month closes: the new month is added for
     every policy that was in force in it.
   A full run treats every policy and claim as changed (used to repair the warehouse).
   ===================================================================================== */

CREATE OR ALTER PROCEDURE etl.usp_load_facts @run_id INT, @full BIT, @as_of_date DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3), @rows INT;

    /* ---------------------------------------------------------------------------------
       What changed in this run
       --------------------------------------------------------------------------------- */
    CREATE TABLE #changed_policy (policy_number INT NOT NULL PRIMARY KEY);
    INSERT INTO #changed_policy (policy_number)
    SELECT policy_number FROM ods.policy WHERE @full = 1 OR ods_run_id = @run_id
    UNION
    SELECT policy_number FROM ods.policy_coverage WHERE @full = 1 OR ods_run_id = @run_id
    UNION
    -- customers who moved: policies that start after the move must point to the new address
    SELECT p.policy_number
    FROM ods.policy AS p
    JOIN dw.dim_customer AS d ON d.customer_id = p.customer_id
    WHERE d.dw_run_id = @run_id AND d.valid_from > '19000101' AND p.start_date >= d.valid_from;

    CREATE TABLE #changed_claim (claim_number INT NOT NULL PRIMARY KEY);
    INSERT INTO #changed_claim (claim_number)
    SELECT claim_number FROM ods.claim WHERE @full = 1 OR ods_run_id = @run_id
    UNION
    SELECT claim_number FROM ods.claim_movement WHERE ods_run_id = @run_id
    UNION
    SELECT c.claim_number FROM ods.claim AS c JOIN #changed_policy AS p ON p.policy_number = c.policy_number
    UNION
    -- customers who moved: claims that happened after the move belong to the new address
    SELECT c.claim_number
    FROM ods.claim AS c
    JOIN ods.policy AS p ON p.policy_number = c.policy_number
    JOIN dw.dim_customer AS d ON d.customer_id = p.customer_id
    WHERE d.dw_run_id = @run_id AND d.valid_from > '19000101' AND c.occurred_on >= d.valid_from;

    /* ---------------------------------------------------------------------------------
       1. Written premium (one row per policy coverage)
       Dimension keys are taken on the policy start date: the customer version valid on
       that day carries the address the policy was sold with.
       --------------------------------------------------------------------------------- */
    SET @started = SYSDATETIME();
    DELETE f FROM dw.fact_written_premium AS f JOIN #changed_policy AS c ON c.policy_number = f.policy_number;

    INSERT INTO dw.fact_written_premium (policy_number, coverage_key, issue_date_key, start_date_key, end_date_key, cancel_date_key,
                                         customer_key, geography_key, vehicle_key, broker_key, product_key, previous_policy_number,
                                         is_renewal, is_cancelled, sum_insured, written_premium, cancelled_premium, dw_run_id)
    SELECT p.policy_number,
           ISNULL(cv.coverage_key, -1),
           etl.fn_date_key(p.issued_on),
           etl.fn_date_key(p.start_date),
           etl.fn_date_key(p.end_date),
           etl.fn_date_key(p.cancelled_on),
           ISNULL(dc.customer_key, -1),
           ISNULL(dc.geography_key, -1),
           ISNULL(v.vehicle_key, -1),
           ISNULL(b.broker_key, -1),
           ISNULL(pr.product_key, -1),
           p.previous_policy_number,
           CASE WHEN p.previous_policy_number IS NULL THEN 0 ELSE 1 END,
           CASE WHEN p.cancelled_on IS NULL THEN 0 ELSE 1 END,
           pc.sum_insured,
           pc.net_premium,
           -- Premium of the days after the cancellation: never earned
           CASE WHEN p.cancelled_on IS NULL OR p.cancelled_on >= p.end_date THEN 0
                ELSE CAST(CAST(pc.net_premium AS DECIMAL(18,6)) * DATEDIFF(DAY, CASE WHEN p.cancelled_on > p.start_date THEN p.cancelled_on ELSE p.start_date END, p.end_date)
                          / DATEDIFF(DAY, p.start_date, p.end_date) AS DECIMAL(12,2)) END,
           @run_id
    FROM #changed_policy AS c
    JOIN ods.policy AS p ON p.policy_number = c.policy_number
    JOIN ods.policy_coverage AS pc ON pc.policy_number = p.policy_number
    LEFT JOIN dw.dim_coverage AS cv ON cv.coverage_code = pc.coverage_code
    LEFT JOIN dw.dim_customer AS dc ON dc.customer_id = p.customer_id AND p.start_date >= dc.valid_from AND p.start_date < dc.valid_to
    LEFT JOIN dw.dim_vehicle AS v ON v.vehicle_id = p.vehicle_id
    LEFT JOIN dw.dim_broker AS b ON b.broker_id = p.broker_id
    LEFT JOIN dw.dim_product AS pr ON pr.product_id = p.product_id;
    SET @rows = @@ROWCOUNT;
    EXEC etl.usp_log_step @run_id, 'dw.fact_written_premium', @rows, @started;

    /* ---------------------------------------------------------------------------------
       2. Earned premium per closed month
       Closed month = a month whose last day is on or before the as-of date. Closed months
       are never reopened by an older as-of date. Earned in a month =
       premium x days in force in the month / days of the term (same rule as the legacy
       report), kept with 6 decimals so the months of a policy add up to its premium.
       --------------------------------------------------------------------------------- */
    SET @started = SYSDATETIME();
    DECLARE @prev_closed DATE = (SELECT date_value FROM etl.control WHERE name = 'earned_closed_through');
    DECLARE @new_closed DATE = DATEADD(MONTH, -1, DATEFROMPARTS(YEAR(DATEADD(DAY, 1, @as_of_date)), MONTH(DATEADD(DAY, 1, @as_of_date)), 1));
    IF @prev_closed IS NOT NULL AND @prev_closed > @new_closed
        SET @new_closed = @prev_closed;

    SELECT month_start, next_month_start, date_key AS month_key
    INTO #months
    FROM dw.dim_date
    WHERE day_of_month = 1 AND month_start <= @new_closed;

    DELETE f FROM dw.fact_earned_premium_monthly AS f JOIN #changed_policy AS c ON c.policy_number = f.policy_number;

    INSERT INTO dw.fact_earned_premium_monthly (month_key, policy_number, coverage_key, customer_key, geography_key, vehicle_key,
                                                broker_key, product_key, days_in_force, earned_premium, exposure_years, dw_run_id)
    SELECT m.month_key, w.policy_number, w.coverage_key, w.customer_key, w.geography_key, w.vehicle_key, w.broker_key, w.product_key,
           o.days,
           CAST(CAST(w.written_premium AS DECIMAL(18,6)) * o.days / p.term_days AS DECIMAL(18,6)),
           CAST(o.days / 365.0 AS DECIMAL(12,8)),
           @run_id
    FROM dw.fact_written_premium AS w
    JOIN (SELECT policy_number, start_date, ISNULL(cancelled_on, end_date) AS effective_end, DATEDIFF(DAY, start_date, end_date) AS term_days
          FROM ods.policy) AS p ON p.policy_number = w.policy_number
    JOIN #months AS m ON m.month_start < p.effective_end AND m.next_month_start > p.start_date
    CROSS APPLY (SELECT DATEDIFF(DAY,
                                 CASE WHEN p.start_date > m.month_start THEN p.start_date ELSE m.month_start END,
                                 CASE WHEN p.effective_end < m.next_month_start THEN p.effective_end ELSE m.next_month_start END) AS days) AS o
    WHERE w.policy_number IN (SELECT policy_number FROM #changed_policy)   -- changed policies: every closed month again
       OR m.month_start > ISNULL(@prev_closed, '19000101');                -- the others: only the months closed since last run
    SET @rows = @@ROWCOUNT;

    UPDATE etl.control SET date_value = @new_closed WHERE name = 'earned_closed_through';
    EXEC etl.usp_log_step @run_id, 'dw.fact_earned_premium_monthly', @rows, @started;

    /* ---------------------------------------------------------------------------------
       3. Claims (one row per claim, with its milestones and running totals)
       Customer version on the occurrence date; vehicle, broker and product from the policy.
       --------------------------------------------------------------------------------- */
    SET @started = SYSDATETIME();
    DELETE f FROM dw.fact_claim AS f JOIN #changed_claim AS c ON c.claim_number = f.claim_number;

    INSERT INTO dw.fact_claim (claim_number, policy_number, coverage_key, occurred_date_key, reported_date_key, closed_date_key,
                               customer_key, geography_key, vehicle_key, broker_key, product_key, cause, status_code, status_name,
                               is_outside_policy_period, report_lag_days, movement_count, paid_amount, reserve_amount,
                               recovered_amount, incurred_amount, dw_run_id)
    SELECT cl.claim_number,
           cl.policy_number,
           ISNULL(cv.coverage_key, -1),
           etl.fn_date_key(cl.occurred_on),
           etl.fn_date_key(CAST(cl.reported_at AS DATE)),
           CASE WHEN cl.status_code = 'A' THEN -1 ELSE etl.fn_date_key(m.last_movement) END,
           ISNULL(dc.customer_key, -1),
           ISNULL(g.geography_key, -1),
           ISNULL(v.vehicle_key, -1),
           ISNULL(b.broker_key, -1),
           ISNULL(pr.product_key, -1),
           cl.cause,
           cl.status_code,
           CASE cl.status_code WHEN 'A' THEN 'Open' WHEN 'P' THEN 'Paid' WHEN 'N' THEN 'Denied' WHEN 'R' THEN 'Vehicle recovered' END,
           CASE WHEN cl.occurred_on < p.start_date OR cl.occurred_on >= ISNULL(p.cancelled_on, p.end_date) THEN 1 ELSE 0 END,
           DATEDIFF(DAY, cl.occurred_on, CAST(cl.reported_at AS DATE)),
           ISNULL(m.movements, 0),
           ISNULL(m.paid, 0),
           ISNULL(m.reserve, 0),
           ISNULL(m.recovered, 0),
           ISNULL(m.paid, 0) + ISNULL(m.reserve, 0) - ISNULL(m.recovered, 0),
           @run_id
    FROM #changed_claim AS c
    JOIN ods.claim AS cl ON cl.claim_number = c.claim_number
    JOIN ods.policy AS p ON p.policy_number = cl.policy_number
    OUTER APPLY (
        SELECT COUNT(*) AS movements,
               SUM(CASE WHEN mv.movement_type = 'PAG' THEN mv.amount ELSE 0 END) AS paid,
               SUM(CASE WHEN mv.movement_type IN ('AVI', 'AJU') THEN mv.amount ELSE 0 END) AS reserve,
               SUM(CASE WHEN mv.movement_type = 'SAL' THEN mv.amount ELSE 0 END) AS recovered,
               MAX(mv.movement_date) AS last_movement
        FROM ods.claim_movement AS mv
        WHERE mv.claim_number = cl.claim_number
    ) AS m
    LEFT JOIN dw.dim_coverage AS cv ON cv.coverage_code = cl.coverage_code
    LEFT JOIN dw.dim_customer AS dc ON dc.customer_id = p.customer_id AND cl.occurred_on >= dc.valid_from AND cl.occurred_on < dc.valid_to
    LEFT JOIN dw.dim_geography AS g ON g.state_code = cl.state_code
    LEFT JOIN dw.dim_vehicle AS v ON v.vehicle_id = p.vehicle_id
    LEFT JOIN dw.dim_broker AS b ON b.broker_id = p.broker_id
    LEFT JOIN dw.dim_product AS pr ON pr.product_id = p.product_id;
    SET @rows = @@ROWCOUNT;
    EXEC etl.usp_log_step @run_id, 'dw.fact_claim', @rows, @started;

    /* ---------------------------------------------------------------------------------
       4. Claim movements (inherit the claim's dimension keys)
       Effect on the claim cost: payments and reserve changes add, recoveries subtract.
       --------------------------------------------------------------------------------- */
    SET @started = SYSDATETIME();
    DELETE f FROM dw.fact_claim_movement AS f JOIN #changed_claim AS c ON c.claim_number = f.claim_number;

    INSERT INTO dw.fact_claim_movement (claim_number, sequence_number, movement_date_key, coverage_key, customer_key, geography_key,
                                        vehicle_key, broker_key, product_key, movement_type, amount, paid_amount, reserve_change,
                                        recovered_amount, incurred_change, dw_run_id)
    SELECT mv.claim_number,
           mv.sequence_number,
           etl.fn_date_key(mv.movement_date),
           fc.coverage_key, fc.customer_key, fc.geography_key, fc.vehicle_key, fc.broker_key, fc.product_key,
           mv.movement_type,
           mv.amount,
           CASE WHEN mv.movement_type = 'PAG' THEN mv.amount ELSE 0 END,
           CASE WHEN mv.movement_type IN ('AVI', 'AJU') THEN mv.amount ELSE 0 END,
           CASE WHEN mv.movement_type = 'SAL' THEN mv.amount ELSE 0 END,
           CASE WHEN mv.movement_type = 'SAL' THEN -mv.amount ELSE mv.amount END,
           @run_id
    FROM #changed_claim AS c
    JOIN ods.claim_movement AS mv ON mv.claim_number = c.claim_number
    JOIN dw.fact_claim AS fc ON fc.claim_number = mv.claim_number;
    SET @rows = @@ROWCOUNT;
    EXEC etl.usp_log_step @run_id, 'dw.fact_claim_movement', @rows, @started;
END
GO

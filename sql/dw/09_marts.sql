/* =====================================================================================
   SeguroDW - business views (mart)
   -------------------------------------------------------------------------------------
   What: the questions management asks, answered once with the official definitions,
   so every report (and Power BI) uses the same numbers.
   Why views: they always show the current state of the facts, have no load of their own
   and can be secured separately from the star schema.
   ===================================================================================== */

/* -------------------------------------------------------------------------------------
   Monthly loss ratio by vehicle category and coverage (replaces the legacy report)
   - earned premium: closed months only
   - incurred claims: payments + reserve changes - recoveries recorded in the month
   - claims: claims that happened in the month, except denied ones
   - loss ratio = incurred / earned; frequency = claims per 100 vehicle-years;
     severity = incurred / claims
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER VIEW mart.vw_loss_ratio_monthly
AS
WITH earned AS (
    SELECT f.month_key, v.category_code, c.coverage_code,
           SUM(f.earned_premium) AS earned_premium,
           SUM(f.exposure_years) AS exposure_years
    FROM dw.fact_earned_premium_monthly AS f
    JOIN dw.dim_vehicle AS v ON v.vehicle_key = f.vehicle_key
    JOIN dw.dim_coverage AS c ON c.coverage_key = f.coverage_key
    GROUP BY f.month_key, v.category_code, c.coverage_code
),
incurred AS (
    SELECT d.month_start_key AS month_key, v.category_code, c.coverage_code,
           SUM(m.incurred_change) AS incurred_claims
    FROM dw.fact_claim_movement AS m
    JOIN dw.dim_date AS d ON d.date_key = m.movement_date_key
    JOIN dw.dim_vehicle AS v ON v.vehicle_key = m.vehicle_key
    JOIN dw.dim_coverage AS c ON c.coverage_key = m.coverage_key
    GROUP BY d.month_start_key, v.category_code, c.coverage_code
),
claims AS (
    SELECT d.month_start_key AS month_key, v.category_code, c.coverage_code,
           COUNT(*) AS claim_count
    FROM dw.fact_claim AS f
    JOIN dw.dim_date AS d ON d.date_key = f.occurred_date_key
    JOIN dw.dim_vehicle AS v ON v.vehicle_key = f.vehicle_key
    JOIN dw.dim_coverage AS c ON c.coverage_key = f.coverage_key
    WHERE f.status_code <> 'N'
    GROUP BY d.month_start_key, v.category_code, c.coverage_code
),
grid AS (
    SELECT month_key, category_code, coverage_code FROM earned
    UNION SELECT month_key, category_code, coverage_code FROM incurred
    UNION SELECT month_key, category_code, coverage_code FROM claims
)
SELECT d.year,
       d.month,
       d.year_month,
       d.month_start,
       g.category_code,
       g.coverage_code,
       CAST(ROUND(ISNULL(e.earned_premium, 0), 2) AS DECIMAL(18,2)) AS earned_premium,
       ISNULL(i.incurred_claims, 0) AS incurred_claims,
       ISNULL(c.claim_count, 0) AS claim_count,
       CAST(ISNULL(e.exposure_years, 0) AS DECIMAL(18,2)) AS exposure_years,
       CAST(i.incurred_claims / NULLIF(e.earned_premium, 0) AS DECIMAL(9,4)) AS loss_ratio,
       CAST(100.0 * c.claim_count / NULLIF(e.exposure_years, 0) AS DECIMAL(9,2)) AS frequency_per_100,
       CAST(i.incurred_claims / NULLIF(c.claim_count, 0) AS DECIMAL(14,2)) AS severity
FROM grid AS g
JOIN dw.dim_date AS d ON d.date_key = g.month_key
LEFT JOIN earned AS e ON e.month_key = g.month_key AND e.category_code = g.category_code AND e.coverage_code = g.coverage_code
LEFT JOIN incurred AS i ON i.month_key = g.month_key AND i.category_code = g.category_code AND i.coverage_code = g.coverage_code
LEFT JOIN claims AS c ON c.month_key = g.month_key AND c.category_code = g.category_code AND c.coverage_code = g.coverage_code;
GO

/* -------------------------------------------------------------------------------------
   Renewal rate: of the policies that reached the end of their term in a month (not
   cancelled), how many were renewed. A key retention indicator for brokers and sales.
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER VIEW mart.vw_renewal_rate_monthly
AS
WITH expiring AS (
    SELECT DISTINCT w.policy_number, w.end_date_key, w.product_key, w.broker_key
    FROM dw.fact_written_premium AS w
    WHERE w.is_cancelled = 0
),
renewed AS (
    SELECT DISTINCT previous_policy_number AS policy_number FROM dw.fact_written_premium WHERE previous_policy_number IS NOT NULL
)
SELECT d.year, d.month, d.year_month, p.product_name,
       COUNT(*) AS expiring_policies,
       SUM(CASE WHEN r.policy_number IS NOT NULL THEN 1 ELSE 0 END) AS renewed_policies,
       CAST(1.0 * SUM(CASE WHEN r.policy_number IS NOT NULL THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(9,4)) AS renewal_rate
FROM expiring AS x
JOIN dw.dim_date AS d ON d.date_key = x.end_date_key
JOIN dw.dim_product AS p ON p.product_key = x.product_key
LEFT JOIN renewed AS r ON r.policy_number = x.policy_number
WHERE d.month_start <= (SELECT date_value FROM etl.control WHERE name = 'earned_closed_through')
GROUP BY d.year, d.month, d.year_month, p.product_name;
GO

/* -------------------------------------------------------------------------------------
   Broker scorecard per year: production (written premium), result (loss ratio) and
   retention (renewal rate). Used to negotiate commissions.
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER VIEW mart.vw_broker_scorecard
AS
WITH written AS (
    SELECT d.year, w.broker_key, SUM(w.written_premium) AS written_premium, COUNT(DISTINCT w.policy_number) AS policies
    FROM dw.fact_written_premium AS w
    JOIN dw.dim_date AS d ON d.date_key = w.issue_date_key
    GROUP BY d.year, w.broker_key
),
earned AS (
    SELECT d.year, f.broker_key, SUM(f.earned_premium) AS earned_premium
    FROM dw.fact_earned_premium_monthly AS f
    JOIN dw.dim_date AS d ON d.date_key = f.month_key
    GROUP BY d.year, f.broker_key
),
incurred AS (
    SELECT d.year, m.broker_key, SUM(m.incurred_change) AS incurred_claims
    FROM dw.fact_claim_movement AS m
    JOIN dw.dim_date AS d ON d.date_key = m.movement_date_key
    GROUP BY d.year, m.broker_key
)
SELECT w.year, b.broker_name, b.susep_code, b.is_active,
       w.policies,
       w.written_premium,
       CAST(ROUND(ISNULL(e.earned_premium, 0), 2) AS DECIMAL(18,2)) AS earned_premium,
       ISNULL(i.incurred_claims, 0) AS incurred_claims,
       CAST(i.incurred_claims / NULLIF(e.earned_premium, 0) AS DECIMAL(9,4)) AS loss_ratio
FROM written AS w
JOIN dw.dim_broker AS b ON b.broker_key = w.broker_key
LEFT JOIN earned AS e ON e.year = w.year AND e.broker_key = w.broker_key
LEFT JOIN incurred AS i ON i.year = w.year AND i.broker_key = w.broker_key;
GO

/* -------------------------------------------------------------------------------------
   Theft claims by category and state: how many vehicles are recovered and the net cost
   after salvage. Theft is the largest cost for motorcycles and in the big capitals.
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER VIEW mart.vw_theft_recovery
AS
SELECT d.year,
       v.category_name,
       g.state_code,
       g.region,
       COUNT(*) AS theft_claims,
       SUM(CASE WHEN c.status_code = 'R' THEN 1 ELSE 0 END) AS recovered_before_payment,
       SUM(CASE WHEN c.recovered_amount > 0 THEN 1 ELSE 0 END) AS salvage_after_payment,
       SUM(c.paid_amount) AS paid_amount,
       SUM(c.recovered_amount) AS recovered_amount,
       SUM(c.incurred_amount) AS net_incurred
FROM dw.fact_claim AS c
JOIN dw.dim_coverage AS cv ON cv.coverage_key = c.coverage_key
JOIN dw.dim_vehicle AS v ON v.vehicle_key = c.vehicle_key
JOIN dw.dim_geography AS g ON g.geography_key = c.geography_key
JOIN dw.dim_date AS d ON d.date_key = c.occurred_date_key
WHERE cv.coverage_code = 'ROUBO' AND c.status_code <> 'N'
GROUP BY d.year, v.category_name, g.state_code, g.region;
GO

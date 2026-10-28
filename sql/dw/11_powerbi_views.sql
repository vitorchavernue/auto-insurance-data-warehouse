/* =====================================================================================
   SeguroDW - feed of the Power BI dashboard (pbi)
   -------------------------------------------------------------------------------------
   What: the exact tables the dashboard imports, with business names. Facts are
   summarised to the grain the dashboard needs (month x coverage x product x vehicle
   profile x broker x state), so the file is small and fast, and no personal data
   leaves the warehouse (no names, CPFs or plates; claims only by number).

   Why a separate schema: the dashboard depends on these views only. The star schema
   can evolve behind them without breaking the report, and access can be granted to
   the dashboard account without exposing the rest of the warehouse.

   Period: from November 2022 (claims typed before the first policies) to the last
   closed month, so "same period last year" compares complete months only.
   ===================================================================================== */

CREATE SCHEMA pbi;
GO

/* -------------------------------------------------------------------------------------
   Dimensions
   ------------------------------------------------------------------------------------- */

-- Calendar up to the last closed month (a month still running would look like a drop)
CREATE OR ALTER VIEW pbi.vw_date
AS
SELECT d.full_date AS [Date],
       d.year AS [Year],
       d.quarter AS [Quarter Number],
       CONCAT('Q', d.quarter) AS [Quarter],
       d.month AS [Month Number],
       LEFT(d.month_name, 3) AS [Month],
       d.year_month AS [Year Month],
       d.year * 100 + d.month AS [Year Month Number],
       d.month_start AS [Month Start]
FROM dw.dim_date AS d
WHERE d.full_date >= '20221101'
  AND d.full_date < DATEADD(MONTH, 1, (SELECT date_value FROM etl.control WHERE name = 'earned_closed_through'));
GO

CREATE OR ALTER VIEW pbi.vw_coverage
AS
SELECT coverage_key AS [Coverage Key],
       coverage_code AS [Coverage Code],
       coverage_name AS [Coverage],
       CASE coverage_code WHEN 'ROUBO' THEN 1 WHEN 'COLISAO' THEN 2 WHEN 'TERCEIROS' THEN 3 WHEN 'VIDROS' THEN 4 ELSE 9 END AS [Coverage Order]
FROM dw.dim_coverage;
GO

CREATE OR ALTER VIEW pbi.vw_product
AS
SELECT product_key AS [Product Key],
       -- legacy names are upper case: shown in title case on the dashboard
       CASE product_name
           WHEN 'AUTO ESSENCIAL' THEN N'Auto Essential'
           WHEN 'AUTO COMPLETO' THEN N'Auto Complete'
           WHEN 'MOTO ROUBO E FURTO' THEN N'Motorcycle Theft'
           WHEN 'CAMINHAO FROTA' THEN N'Truck Fleet'
           ELSE product_name
       END AS [Product]
FROM dw.dim_product;
GO

CREATE OR ALTER VIEW pbi.vw_broker
AS
SELECT broker_key AS [Broker Key],
       broker_name AS [Broker],
       susep_code AS [SUSEP Code],
       ISNULL(state_code, '??') AS [Broker State],
       CASE WHEN is_active = 1 THEN 'Active' ELSE 'Inactive' END AS [Broker Status]
FROM dw.dim_broker;
GO

CREATE OR ALTER VIEW pbi.vw_geography
AS
SELECT geography_key AS [Geography Key],
       state_code AS [State Code],
       state_name AS [State],
       region AS [Region]
FROM dw.dim_geography;
GO

/* Vehicle profile: category x market value band. The dashboard does not need each
   vehicle, only the risk profile that drives price and claims (a "junk" dimension). */
CREATE OR ALTER VIEW pbi.vw_vehicle_profile
AS
SELECT DISTINCT
       CONCAT(category_code, '|', fipe_band) AS [Vehicle Profile Key],
       category_name AS [Vehicle Category],
       fipe_band AS [Value Band],
       CASE category_code WHEN 'AUTO' THEN 1 WHEN 'MOTO' THEN 2 WHEN 'CAMINHAO' THEN 3 ELSE 9 END AS [Category Order]
FROM dw.dim_vehicle;
GO

/* -------------------------------------------------------------------------------------
   Facts (summarised)
   ------------------------------------------------------------------------------------- */

-- Earned premium and exposure per closed month
CREATE OR ALTER VIEW pbi.vw_earned_premium
AS
SELECT d.full_date AS [Month],
       f.coverage_key AS [Coverage Key],
       f.product_key AS [Product Key],
       CONCAT(v.category_code, '|', v.fipe_band) AS [Vehicle Profile Key],
       f.broker_key AS [Broker Key],
       f.geography_key AS [Geography Key],
       SUM(f.earned_premium) AS [Earned Premium],  -- kept with 6 decimals: totals add up exactly
       CAST(SUM(f.exposure_years) AS DECIMAL(18,4)) AS [Exposure Years]
FROM dw.fact_earned_premium_monthly AS f
JOIN dw.dim_date AS d ON d.date_key = f.month_key
JOIN dw.dim_vehicle AS v ON v.vehicle_key = f.vehicle_key
GROUP BY d.full_date, f.coverage_key, f.product_key, CONCAT(v.category_code, '|', v.fipe_band), f.broker_key, f.geography_key;
GO

/* Written premium per month of issue. Policies are counted once, on the row of their first
   coverage, so the count adds up correctly across coverages. */
CREATE OR ALTER VIEW pbi.vw_written_premium
AS
WITH rows_ AS (
    SELECT w.*,
           CASE WHEN w.coverage_key = MIN(w.coverage_key) OVER (PARTITION BY w.policy_number) THEN 1 ELSE 0 END AS first_coverage
    FROM dw.fact_written_premium AS w
)
SELECT d.month_start AS [Month],
       w.coverage_key AS [Coverage Key],
       w.product_key AS [Product Key],
       CONCAT(v.category_code, '|', v.fipe_band) AS [Vehicle Profile Key],
       w.broker_key AS [Broker Key],
       w.geography_key AS [Geography Key],
       CASE WHEN w.is_renewal = 1 THEN 'Renewal' ELSE 'New business' END AS [Business Type],
       SUM(w.first_coverage) AS [Policies],
       COUNT(*) AS [Coverages],
       SUM(w.written_premium) AS [Written Premium],
       SUM(w.cancelled_premium) AS [Cancelled Premium]
FROM rows_ AS w
JOIN dw.dim_date AS d ON d.date_key = w.issue_date_key
JOIN dw.dim_vehicle AS v ON v.vehicle_key = w.vehicle_key
WHERE d.full_date < DATEADD(MONTH, 1, (SELECT date_value FROM etl.control WHERE name = 'earned_closed_through'))
GROUP BY d.month_start, w.coverage_key, w.product_key, CONCAT(v.category_code, '|', v.fipe_band), w.broker_key, w.geography_key, w.is_renewal;
GO

-- Claims, one row per claim (identified only by its number)
CREATE OR ALTER VIEW pbi.vw_claims
AS
SELECT c.claim_number AS [Claim Number],
       od.full_date AS [Occurred Date],
       rd.full_date AS [Reported Date],
       c.coverage_key AS [Coverage Key],
       c.product_key AS [Product Key],
       CONCAT(v.category_code, '|', v.fipe_band) AS [Vehicle Profile Key],
       c.broker_key AS [Broker Key],
       c.geography_key AS [Geography Key],
       CASE c.cause
           WHEN 'ROUBO' THEN 'Robbery'
           WHEN 'FURTO' THEN 'Theft'
           WHEN 'COLISAO' THEN 'Collision'
           WHEN 'DANOS A TERCEIROS' THEN 'Third-party damage'
           WHEN 'QUEBRA DE VIDRO' THEN 'Glass breakage'
           ELSE ISNULL(c.cause, 'Not informed')
       END AS [Cause],
       c.status_name AS [Status],
       CASE WHEN c.is_outside_policy_period = 1 THEN 'Yes' ELSE 'No' END AS [Outside Policy Period],
       -- the stolen vehicle was found: before payment (status R) or after, sold as salvage
       CASE WHEN c.status_code = 'R' OR c.recovered_amount > 0 THEN 1 ELSE 0 END AS [Vehicle Found],
       c.report_lag_days AS [Report Lag Days],
       c.paid_amount AS [Paid Amount],
       c.reserve_amount AS [Open Reserve],
       c.recovered_amount AS [Recovered Amount],
       c.incurred_amount AS [Incurred Amount]
FROM dw.fact_claim AS c
JOIN dw.dim_date AS od ON od.date_key = c.occurred_date_key
JOIN dw.dim_date AS rd ON rd.date_key = c.reported_date_key
JOIN dw.dim_vehicle AS v ON v.vehicle_key = c.vehicle_key;
GO

-- Claim cost movements per month (the incurred claims of the loss ratio)
CREATE OR ALTER VIEW pbi.vw_claim_movements
AS
SELECT d.month_start AS [Month],
       m.coverage_key AS [Coverage Key],
       m.product_key AS [Product Key],
       CONCAT(v.category_code, '|', v.fipe_band) AS [Vehicle Profile Key],
       m.broker_key AS [Broker Key],
       m.geography_key AS [Geography Key],
       SUM(m.paid_amount) AS [Paid],
       SUM(m.reserve_change) AS [Reserve Change],
       SUM(m.recovered_amount) AS [Recovered],
       SUM(m.incurred_change) AS [Incurred Claims]
FROM dw.fact_claim_movement AS m
JOIN dw.dim_date AS d ON d.date_key = m.movement_date_key
JOIN dw.dim_vehicle AS v ON v.vehicle_key = m.vehicle_key
GROUP BY d.month_start, m.coverage_key, m.product_key, CONCAT(v.category_code, '|', v.fipe_band), m.broker_key, m.geography_key;
GO

/* Renewals: policies that reached the end of their term (not cancelled) in a closed month,
   and how many of them were renewed. */
CREATE OR ALTER VIEW pbi.vw_renewals
AS
WITH expiring AS (
    SELECT DISTINCT w.policy_number, w.end_date_key, w.product_key, w.broker_key, w.geography_key
    FROM dw.fact_written_premium AS w
    WHERE w.is_cancelled = 0
),
renewed AS (
    SELECT DISTINCT previous_policy_number AS policy_number FROM dw.fact_written_premium WHERE previous_policy_number IS NOT NULL
)
SELECT d.month_start AS [Month],
       x.product_key AS [Product Key],
       x.broker_key AS [Broker Key],
       x.geography_key AS [Geography Key],
       COUNT(*) AS [Expiring Policies],
       SUM(CASE WHEN r.policy_number IS NOT NULL THEN 1 ELSE 0 END) AS [Renewed Policies]
FROM expiring AS x
JOIN dw.dim_date AS d ON d.date_key = x.end_date_key
LEFT JOIN renewed AS r ON r.policy_number = x.policy_number
WHERE d.full_date < DATEADD(MONTH, 1, (SELECT date_value FROM etl.control WHERE name = 'earned_closed_through'))
GROUP BY d.month_start, x.product_key, x.broker_key, x.geography_key;
GO

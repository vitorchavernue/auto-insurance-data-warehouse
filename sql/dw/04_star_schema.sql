/* =====================================================================================
   SeguroDW - star schema (dw)
   -------------------------------------------------------------------------------------
   Dimensions (who, what, where, when):
     dim_date, dim_customer (history of address kept: SCD type 2), dim_vehicle,
     dim_broker, dim_product, dim_coverage, dim_geography.
   Facts, one per kind of business question:
     fact_written_premium         - transaction:          one row per policy coverage sold
     fact_earned_premium_monthly  - periodic snapshot:    one row per policy coverage per closed month
     fact_claim                   - accumulating snapshot: one row per claim, updated through its life
     fact_claim_movement          - transaction:          one row per reserve/payment/recovery movement

   Every dimension has an "Unknown" member with key -1, so a fact row is never lost
   because a description is missing; the data quality checks count those rows.
   ===================================================================================== */

/* -------------------------------------------------------------------------------------
   Date dimension (2020-2030) + key -1 "Not applicable"
   ------------------------------------------------------------------------------------- */
CREATE TABLE dw.dim_date (
    date_key         INT         NOT NULL CONSTRAINT pk_dim_date PRIMARY KEY,  -- yyyymmdd
    full_date        DATE        NULL,
    year             SMALLINT    NULL,
    quarter          TINYINT     NULL,
    month            TINYINT     NULL,
    month_name       VARCHAR(10) NULL,
    year_month       CHAR(7)     NULL,   -- 2026-09
    month_start      DATE        NULL,
    month_start_key  INT         NULL,
    next_month_start DATE        NULL,
    day_of_month     TINYINT     NULL,
    is_month_end     BIT         NULL
);

INSERT INTO dw.dim_date (date_key, year_month, month_name) VALUES (-1, 'n/a', 'n/a');

WITH numbers AS (
    SELECT TOP (DATEDIFF(DAY, '20200101', '20310101'))
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
    FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
),
days AS (
    SELECT DATEADD(DAY, n, CAST('20200101' AS DATE)) AS d FROM numbers
)
INSERT INTO dw.dim_date (date_key, full_date, year, quarter, month, month_name, year_month, month_start,
                         month_start_key, next_month_start, day_of_month, is_month_end)
SELECT CONVERT(INT, CONVERT(CHAR(8), d, 112)),
       d,
       YEAR(d),
       DATEPART(QUARTER, d),
       MONTH(d),
       DATENAME(MONTH, d),
       CONVERT(CHAR(7), d, 126),
       DATEFROMPARTS(YEAR(d), MONTH(d), 1),
       CONVERT(INT, CONVERT(CHAR(8), DATEFROMPARTS(YEAR(d), MONTH(d), 1), 112)),
       DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(d), MONTH(d), 1)),
       DAY(d),
       CASE WHEN d = EOMONTH(d) THEN 1 ELSE 0 END
FROM days;

GO

/* -------------------------------------------------------------------------------------
   Geography: Brazilian states and regions (claim location and customer address)
   ------------------------------------------------------------------------------------- */
CREATE TABLE dw.dim_geography (
    geography_key INT          NOT NULL CONSTRAINT pk_dim_geography PRIMARY KEY,
    state_code    CHAR(2)      NOT NULL,
    state_name    NVARCHAR(40) NOT NULL,
    region        NVARCHAR(20) NOT NULL
);
INSERT INTO dw.dim_geography VALUES (-1, '??', N'Unknown', N'Unknown');
INSERT INTO dw.dim_geography (geography_key, state_code, state_name, region)
SELECT ROW_NUMBER() OVER (ORDER BY state_code), state_code, state_name, region FROM etl.ref_state;
CREATE UNIQUE INDEX ux_dim_geography_state ON dw.dim_geography (state_code);

GO

/* -------------------------------------------------------------------------------------
   Customer - slowly changing dimension type 2 on the address.
   The address decides the risk region (theft rates differ a lot between states), so when
   a customer moves a new version is created and old policies keep pointing to the address
   they were sold with. Name, CPF and birth date are corrections (type 1): every version
   is updated. valid_from is inclusive, valid_to exclusive; the first version starts in
   1900 so any older event finds it.
   ------------------------------------------------------------------------------------- */
CREATE TABLE dw.dim_customer (
    customer_key  INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_customer PRIMARY KEY,
    customer_id   INT           NOT NULL,
    full_name     NVARCHAR(120) NOT NULL,
    cpf_masked    CHAR(14)      NULL,     -- ***.456.789-** : enough to identify a record, not to misuse it
    cpf_is_valid  BIT           NOT NULL,
    birth_date    DATE          NULL,
    state_code    CHAR(2)       NOT NULL,
    city          NVARCHAR(80)  NULL,
    geography_key INT           NOT NULL,
    valid_from    DATE          NOT NULL,
    valid_to      DATE          NOT NULL,
    is_current    BIT           NOT NULL,
    dw_run_id     INT           NOT NULL
);
SET IDENTITY_INSERT dw.dim_customer ON;
INSERT INTO dw.dim_customer (customer_key, customer_id, full_name, cpf_is_valid, state_code, geography_key,
                             valid_from, valid_to, is_current, dw_run_id)
VALUES (-1, -1, N'Unknown', 0, '??', -1, '19000101', '99991231', 1, 0);
SET IDENTITY_INSERT dw.dim_customer OFF;
CREATE INDEX ix_dim_customer_lookup ON dw.dim_customer (customer_id, valid_from, valid_to) INCLUDE (geography_key, is_current);

GO

/* -------------------------------------------------------------------------------------
   Vehicle, broker, product (type 1: corrections overwrite)
   ------------------------------------------------------------------------------------- */
CREATE TABLE dw.dim_vehicle (
    vehicle_key   INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_vehicle PRIMARY KEY,
    vehicle_id    INT           NOT NULL,
    category_code VARCHAR(10)   NOT NULL,
    category_name NVARCHAR(20)  NOT NULL,
    make          NVARCHAR(40)  NULL,
    model         NVARCHAR(60)  NULL,
    model_year    SMALLINT      NULL,
    vehicle_age   VARCHAR(12)   NOT NULL,  -- age band of the model year
    fipe_value    DECIMAL(12,2) NULL,
    fipe_band     VARCHAR(20)   NOT NULL,  -- value band: the main driver of theft and collision cost
    dw_run_id     INT           NOT NULL
);
SET IDENTITY_INSERT dw.dim_vehicle ON;
INSERT INTO dw.dim_vehicle (vehicle_key, vehicle_id, category_code, category_name, vehicle_age, fipe_band, dw_run_id)
VALUES (-1, -1, 'OUTROS', N'Unknown', 'Unknown', 'Unknown', 0);
SET IDENTITY_INSERT dw.dim_vehicle OFF;
CREATE UNIQUE INDEX ux_dim_vehicle_id ON dw.dim_vehicle (vehicle_id);

CREATE TABLE dw.dim_broker (
    broker_key  INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_broker PRIMARY KEY,
    broker_id   INT           NOT NULL,
    broker_name NVARCHAR(120) NOT NULL,
    susep_code  VARCHAR(20)   NULL,
    state_code  CHAR(2)       NULL,
    is_active   BIT           NOT NULL,
    dw_run_id   INT           NOT NULL
);
SET IDENTITY_INSERT dw.dim_broker ON;
INSERT INTO dw.dim_broker (broker_key, broker_id, broker_name, is_active, dw_run_id) VALUES (-1, -1, N'Unknown', 0, 0);
SET IDENTITY_INSERT dw.dim_broker OFF;
CREATE UNIQUE INDEX ux_dim_broker_id ON dw.dim_broker (broker_id);

CREATE TABLE dw.dim_product (
    product_key  INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_product PRIMARY KEY,
    product_id   INT          NOT NULL,
    product_name NVARCHAR(60) NOT NULL,
    dw_run_id    INT          NOT NULL
);
SET IDENTITY_INSERT dw.dim_product ON;
INSERT INTO dw.dim_product (product_key, product_id, product_name, dw_run_id) VALUES (-1, -1, N'Unknown', 0);
SET IDENTITY_INSERT dw.dim_product OFF;
CREATE UNIQUE INDEX ux_dim_product_id ON dw.dim_product (product_id);

CREATE TABLE dw.dim_coverage (
    coverage_key  INT          NOT NULL CONSTRAINT pk_dim_coverage PRIMARY KEY,
    coverage_code VARCHAR(10)  NOT NULL,
    coverage_name NVARCHAR(40) NOT NULL
);
INSERT INTO dw.dim_coverage VALUES (-1, '??', N'Unknown');
INSERT INTO dw.dim_coverage (coverage_key, coverage_code, coverage_name)
SELECT ROW_NUMBER() OVER (ORDER BY coverage_code), coverage_code, coverage_name FROM etl.ref_coverage;
CREATE UNIQUE INDEX ux_dim_coverage_code ON dw.dim_coverage (coverage_code);

GO

/* -------------------------------------------------------------------------------------
   Written premium: one row per policy coverage sold.
   Dimension keys are fixed at the policy start (the customer version with the address
   the policy was sold with). policy_number is a degenerate dimension.
   ------------------------------------------------------------------------------------- */
CREATE TABLE dw.fact_written_premium (
    policy_number          INT           NOT NULL,
    coverage_key           INT           NOT NULL,
    issue_date_key         INT           NOT NULL,
    start_date_key         INT           NOT NULL,
    end_date_key           INT           NOT NULL,
    cancel_date_key        INT           NOT NULL,  -- -1 when not cancelled
    customer_key           INT           NOT NULL,
    geography_key          INT           NOT NULL,  -- customer address at the policy start
    vehicle_key            INT           NOT NULL,
    broker_key             INT           NOT NULL,
    product_key            INT           NOT NULL,
    previous_policy_number INT           NULL,
    is_renewal             BIT           NOT NULL,
    is_cancelled           BIT           NOT NULL,
    sum_insured            DECIMAL(14,2) NULL,
    written_premium        DECIMAL(12,2) NOT NULL,
    cancelled_premium      DECIMAL(12,2) NOT NULL,  -- part of the premium not earned because of the cancellation
    dw_run_id              INT           NOT NULL,
    CONSTRAINT pk_fact_written_premium PRIMARY KEY (policy_number, coverage_key)
);

GO

/* -------------------------------------------------------------------------------------
   Earned premium per closed month (periodic snapshot). The base of the loss ratio:
   premium is earned day by day while the policy is in force. Only closed months are
   stored: the numbers of a month do not move while it is still running.
   Clustered columnstore: the table grows by one row per active coverage every month and
   is read by month/category/coverage aggregations, the case columnstore was made for.
   ------------------------------------------------------------------------------------- */
CREATE TABLE dw.fact_earned_premium_monthly (
    month_key      INT           NOT NULL,  -- date key of the first day of the month
    policy_number  INT           NOT NULL,
    coverage_key   INT           NOT NULL,
    customer_key   INT           NOT NULL,
    geography_key  INT           NOT NULL,
    vehicle_key    INT           NOT NULL,
    broker_key     INT           NOT NULL,
    product_key    INT           NOT NULL,
    days_in_force  SMALLINT      NOT NULL,
    earned_premium DECIMAL(18,6) NOT NULL,  -- 6 decimals: rounded only when summed, so months add up to the premium
    exposure_years DECIMAL(12,8) NOT NULL,  -- vehicle-years of cover (days / 365): the base of claim frequency
    dw_run_id      INT           NOT NULL
);
CREATE CLUSTERED COLUMNSTORE INDEX cci_fact_earned_premium_monthly ON dw.fact_earned_premium_monthly;
CREATE INDEX ix_fact_earned_policy ON dw.fact_earned_premium_monthly (policy_number);

GO

/* -------------------------------------------------------------------------------------
   Claim (accumulating snapshot): one row per claim with its milestones (occurred,
   reported, closed) and running totals. Rewritten whenever the claim moves.
   ------------------------------------------------------------------------------------- */
CREATE TABLE dw.fact_claim (
    claim_number             INT           NOT NULL CONSTRAINT pk_fact_claim PRIMARY KEY,
    policy_number            INT           NOT NULL,
    coverage_key             INT           NOT NULL,
    occurred_date_key        INT           NOT NULL,
    reported_date_key        INT           NOT NULL,
    closed_date_key          INT           NOT NULL,  -- -1 while open
    customer_key             INT           NOT NULL,  -- customer version on the occurrence date
    geography_key            INT           NOT NULL,  -- where it happened
    vehicle_key              INT           NOT NULL,
    broker_key               INT           NOT NULL,
    product_key              INT           NOT NULL,
    cause                    VARCHAR(30)   NULL,
    status_code              CHAR(1)       NOT NULL,
    status_name              VARCHAR(20)   NOT NULL,
    is_outside_policy_period BIT           NOT NULL,  -- occurrence outside the cover: flagged for the claims team
    report_lag_days          INT           NOT NULL,  -- days between occurrence and report
    movement_count           INT           NOT NULL,
    paid_amount              DECIMAL(14,2) NOT NULL,
    reserve_amount           DECIMAL(14,2) NOT NULL,  -- reserve still open (expected future payments)
    recovered_amount         DECIMAL(14,2) NOT NULL,
    incurred_amount          DECIMAL(14,2) NOT NULL,  -- paid + open reserve - recovered
    dw_run_id                INT           NOT NULL
);
CREATE INDEX ix_fact_claim_policy ON dw.fact_claim (policy_number);

GO

/* -------------------------------------------------------------------------------------
   Claim movement (transaction): every reserve, payment and recovery, on its date.
   Incurred claims of a month = sum of incurred_change of the movements of the month.
   ------------------------------------------------------------------------------------- */
CREATE TABLE dw.fact_claim_movement (
    claim_number      INT           NOT NULL,
    sequence_number   INT           NOT NULL,
    movement_date_key INT           NOT NULL,
    coverage_key      INT           NOT NULL,
    customer_key      INT           NOT NULL,
    geography_key     INT           NOT NULL,
    vehicle_key       INT           NOT NULL,
    broker_key        INT           NOT NULL,
    product_key       INT           NOT NULL,
    movement_type     CHAR(3)       NOT NULL,
    amount            DECIMAL(14,2) NOT NULL,  -- as recorded in the legacy system
    paid_amount       DECIMAL(14,2) NOT NULL,
    reserve_change    DECIMAL(14,2) NOT NULL,
    recovered_amount  DECIMAL(14,2) NOT NULL,
    incurred_change   DECIMAL(14,2) NOT NULL,  -- effect on the claim cost (recoveries are negative)
    dw_run_id         INT           NOT NULL
);
CREATE CLUSTERED COLUMNSTORE INDEX cci_fact_claim_movement ON dw.fact_claim_movement;
CREATE INDEX ix_fact_claim_movement_claim ON dw.fact_claim_movement (claim_number);
GO

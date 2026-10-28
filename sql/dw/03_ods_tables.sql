/* =====================================================================================
   SeguroDW - Operational Data Store (ods)
   -------------------------------------------------------------------------------------
   What: one table per legacy table, with the data cleaned and typed (real dates instead
   of text, CPF with 11 digits, standard vehicle categories, valid state codes).
   It holds the current state of each record, like the legacy system, but:
   - it is integrated and trustworthy (rows that cannot be placed are in etl.rejected_row);
   - reports and the warehouse read here, not from the production system;
   - every row carries ods_run_id, the run that last changed it, so the warehouse only
     refreshes what actually changed.
   ===================================================================================== */

CREATE TABLE ods.broker (
    broker_id         INT           NOT NULL CONSTRAINT pk_ods_broker PRIMARY KEY,
    broker_name       NVARCHAR(120) NOT NULL,
    susep_code        VARCHAR(20)   NULL,
    state_code        CHAR(2)       NULL,
    is_active         BIT           NOT NULL,
    source_changed_at DATETIME      NOT NULL,
    ods_run_id        INT           NOT NULL
);

CREATE TABLE ods.product (
    product_id        INT          NOT NULL CONSTRAINT pk_ods_product PRIMARY KEY,
    product_name      NVARCHAR(60) NOT NULL,
    source_changed_at DATETIME     NOT NULL,
    ods_run_id        INT          NOT NULL
);

CREATE TABLE ods.customer (
    customer_id       INT           NOT NULL CONSTRAINT pk_ods_customer PRIMARY KEY,
    full_name         NVARCHAR(120) NOT NULL,
    cpf               CHAR(11)      NULL,
    cpf_is_valid      BIT           NOT NULL,
    birth_date        DATE          NULL,
    state_code        CHAR(2)       NULL,   -- NULL when the typed code is not a Brazilian state
    city              NVARCHAR(80)  NULL,
    source_changed_at DATETIME      NOT NULL,
    ods_run_id        INT           NOT NULL
);

CREATE TABLE ods.vehicle (
    vehicle_id        INT           NOT NULL CONSTRAINT pk_ods_vehicle PRIMARY KEY,
    customer_id       INT           NOT NULL,
    plate             VARCHAR(8)    NULL,
    fipe_code         VARCHAR(10)   NULL,
    make              NVARCHAR(40)  NULL,
    model             NVARCHAR(60)  NULL,
    model_year        SMALLINT      NULL,
    category_code     VARCHAR(10)   NOT NULL,  -- AUTO, MOTO, CAMINHAO or OUTROS
    fipe_value        DECIMAL(12,2) NULL,
    source_changed_at DATETIME      NOT NULL,
    ods_run_id        INT           NOT NULL
);

CREATE TABLE ods.policy (
    policy_number          INT      NOT NULL CONSTRAINT pk_ods_policy PRIMARY KEY,
    customer_id            INT      NOT NULL,
    vehicle_id             INT      NOT NULL,
    broker_id              INT      NOT NULL,
    product_id             INT      NOT NULL,
    issued_on              DATE     NOT NULL,
    start_date             DATE     NOT NULL,  -- inclusive
    end_date               DATE     NOT NULL,  -- exclusive
    cancelled_on           DATE     NULL,      -- exclusive: coverage stopped on this date
    previous_policy_number INT      NULL,
    source_changed_at      DATETIME NOT NULL,
    ods_run_id             INT      NOT NULL
);

CREATE TABLE ods.policy_coverage (
    policy_number     INT           NOT NULL,
    coverage_code     VARCHAR(10)   NOT NULL,
    sum_insured       DECIMAL(14,2) NULL,
    net_premium       DECIMAL(12,2) NOT NULL,
    source_changed_at DATETIME      NOT NULL,
    ods_run_id        INT           NOT NULL,
    CONSTRAINT pk_ods_policy_coverage PRIMARY KEY (policy_number, coverage_code)
);

CREATE TABLE ods.claim (
    claim_number      INT          NOT NULL CONSTRAINT pk_ods_claim PRIMARY KEY,
    policy_number     INT          NOT NULL,
    coverage_code     VARCHAR(10)  NOT NULL,
    occurred_on       DATE         NOT NULL,
    reported_at       DATETIME     NOT NULL,
    cause             VARCHAR(30)  NULL,
    state_code        CHAR(2)      NULL,
    status_code       CHAR(1)      NOT NULL,  -- A open, P paid, N denied, R vehicle recovered
    source_changed_at DATETIME     NOT NULL,
    ods_run_id        INT          NOT NULL
);
CREATE INDEX ix_ods_claim_policy ON ods.claim (policy_number);

CREATE TABLE ods.claim_movement (
    claim_number      INT           NOT NULL,
    sequence_number   INT           NOT NULL,
    movement_date     DATE          NOT NULL,
    movement_type     CHAR(3)       NOT NULL,
    amount            DECIMAL(14,2) NOT NULL,
    source_changed_at DATETIME      NOT NULL,
    ods_run_id        INT           NOT NULL,
    CONSTRAINT pk_ods_claim_movement PRIMARY KEY (claim_number, sequence_number)
);

-- Indexes on the run stamp: the warehouse asks "what changed in this run?" for every table
CREATE INDEX ix_ods_customer_run ON ods.customer (ods_run_id);
CREATE INDEX ix_ods_vehicle_run ON ods.vehicle (ods_run_id);
CREATE INDEX ix_ods_policy_run ON ods.policy (ods_run_id);
CREATE INDEX ix_ods_policy_coverage_run ON ods.policy_coverage (ods_run_id);
CREATE INDEX ix_ods_claim_run ON ods.claim (ods_run_id);
CREATE INDEX ix_ods_claim_movement_run ON ods.claim_movement (ods_run_id);

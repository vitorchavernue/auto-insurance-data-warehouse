/* =====================================================================================
   SeguroDW - schemas, ETL control tables and reference data
   -------------------------------------------------------------------------------------
   Layers of the warehouse:
     ods  - Operational Data Store: the legacy data cleaned, typed and validated,
            in its current state. One table per legacy table, English names.
     dw   - the star schema (dimensions and facts) used for analysis.
     etl  - run log, watermarks, rejected records, mapping and reference tables.
     dq   - data quality checks that every run must pass (release gate).
     mart - business views read by reports and Power BI.
   ===================================================================================== */

CREATE SCHEMA ods;
GO
CREATE SCHEMA dw;
GO
CREATE SCHEMA etl;
GO
CREATE SCHEMA dq;
GO
CREATE SCHEMA mart;
GO

/* -------------------------------------------------------------------------------------
   Run log: one row per execution of etl.usp_run.
   status: running -> passed (all critical checks passed) | failed (a critical check
   failed: data loaded but not released) | error (the run stopped and was rolled back).
   ------------------------------------------------------------------------------------- */
CREATE TABLE etl.run (
    run_id        INT IDENTITY(1,1) CONSTRAINT pk_run PRIMARY KEY,
    as_of_date    DATE           NOT NULL,  -- business date closed by the run (data up to the end of this day)
    mode          VARCHAR(12)    NOT NULL,  -- incremental | full
    status        VARCHAR(10)    NOT NULL CONSTRAINT df_run_status DEFAULT ('running'),
    started_at    DATETIME2(3)   NOT NULL CONSTRAINT df_run_started DEFAULT (SYSDATETIME()),
    finished_at   DATETIME2(3)   NULL,
    error_message NVARCHAR(4000) NULL
);

-- Rows touched by each step of a run (zero everywhere when nothing changed in the legacy system)
CREATE TABLE etl.step_log (
    run_id        INT          NOT NULL,
    step          VARCHAR(60)  NOT NULL,
    rows_affected INT          NOT NULL,
    started_at    DATETIME2(3) NOT NULL,
    finished_at   DATETIME2(3) NOT NULL,
    CONSTRAINT pk_step_log PRIMARY KEY (run_id, step)
);

/* Watermark per legacy table: the newest "changed at" already read. The next incremental
   run only reads rows changed after it (minus a 5-minute overlap for late commits). */
CREATE TABLE etl.watermark (
    source_table    SYSNAME  NOT NULL CONSTRAINT pk_watermark PRIMARY KEY,
    last_changed_at DATETIME NULL,
    updated_run_id  INT      NULL
);
INSERT INTO etl.watermark (source_table)
VALUES ('Corretor'), ('Produto'), ('Segurado'), ('Veiculo'), ('Apolice'), ('ApoliceCobertura'), ('Sinistro'), ('SinistroMovimento');

-- Other control values (e.g. the last month already closed in the earned premium fact)
CREATE TABLE etl.control (
    name       VARCHAR(40) NOT NULL CONSTRAINT pk_control PRIMARY KEY,
    date_value DATE        NULL
);
INSERT INTO etl.control (name, date_value) VALUES ('earned_closed_through', NULL);

/* Rejected records: legacy rows that cannot be placed in the warehouse, with the reason and
   the money involved, so nothing disappears silently. They are re-read on every run and
   marked as resolved when the business fixes them at the source. */
CREATE TABLE etl.rejected_row (
    rejected_id     BIGINT IDENTITY(1,1) CONSTRAINT pk_rejected_row PRIMARY KEY,
    run_id          INT            NOT NULL,
    source_table    SYSNAME        NOT NULL,
    source_key      VARCHAR(60)    NOT NULL,
    reason          VARCHAR(200)   NOT NULL,
    amount          DECIMAL(14,2)  NULL,
    payload         NVARCHAR(MAX)  NULL,  -- the legacy row as JSON, for the data owners
    rejected_at     DATETIME2(3)   NOT NULL CONSTRAINT df_rejected_at DEFAULT (SYSDATETIME()),
    resolved_run_id INT            NULL
);
-- Only one open rejection per legacy row (re-reading it does not create duplicates)
CREATE UNIQUE INDEX ux_rejected_open ON etl.rejected_row (source_table, source_key) WHERE resolved_run_id IS NULL;
GO

-- Writes one line of the step log (called at the end of every step)
CREATE OR ALTER PROCEDURE etl.usp_log_step @run_id INT, @step VARCHAR(60), @rows INT, @started DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.step_log (run_id, step, rows_affected, started_at, finished_at)
    VALUES (@run_id, @step, ISNULL(@rows, 0), @started, SYSDATETIME());
END
GO

/* -------------------------------------------------------------------------------------
   Reference data
   ------------------------------------------------------------------------------------- */

-- Official list of Brazilian states and their regions (used to validate typed state codes)
CREATE TABLE etl.ref_state (
    state_code CHAR(2)      NOT NULL CONSTRAINT pk_ref_state PRIMARY KEY,
    state_name NVARCHAR(40) NOT NULL,
    region     NVARCHAR(20) NOT NULL
);
INSERT INTO etl.ref_state (state_code, state_name, region) VALUES
('AC', N'Acre', N'North'), ('AL', N'Alagoas', N'Northeast'), ('AP', N'Amapá', N'North'),
('AM', N'Amazonas', N'North'), ('BA', N'Bahia', N'Northeast'), ('CE', N'Ceará', N'Northeast'),
('DF', N'Distrito Federal', N'Central-West'), ('ES', N'Espírito Santo', N'Southeast'),
('GO', N'Goiás', N'Central-West'), ('MA', N'Maranhão', N'Northeast'), ('MT', N'Mato Grosso', N'Central-West'),
('MS', N'Mato Grosso do Sul', N'Central-West'), ('MG', N'Minas Gerais', N'Southeast'), ('PA', N'Pará', N'North'),
('PB', N'Paraíba', N'Northeast'), ('PR', N'Paraná', N'South'), ('PE', N'Pernambuco', N'Northeast'),
('PI', N'Piauí', N'Northeast'), ('RJ', N'Rio de Janeiro', N'Southeast'), ('RN', N'Rio Grande do Norte', N'Northeast'),
('RS', N'Rio Grande do Sul', N'South'), ('RO', N'Rondônia', N'North'), ('RR', N'Roraima', N'North'),
('SC', N'Santa Catarina', N'South'), ('SP', N'São Paulo', N'Southeast'), ('SE', N'Sergipe', N'Northeast'),
('TO', N'Tocantins', N'North');

/* Vehicle category as typed in the legacy system -> standard category.
   A table rather than code, so the business can add a new spelling without a deploy. */
CREATE TABLE etl.map_vehicle_category (
    typed_value   NVARCHAR(20) NOT NULL CONSTRAINT pk_map_vehicle_category PRIMARY KEY,
    category_code VARCHAR(10)  NOT NULL
);
INSERT INTO etl.map_vehicle_category (typed_value, category_code) VALUES
(N'AUTO', 'AUTO'), (N'AUTOMOVEL', 'AUTO'),
(N'MOTO', 'MOTO'), (N'MOTOCICLETA', 'MOTO'),
(N'CAMINHAO', 'CAMINHAO'), (N'CAMINHÃO', 'CAMINHAO');

-- Coverages sold by the insurer
CREATE TABLE etl.ref_coverage (
    coverage_code VARCHAR(10)  NOT NULL CONSTRAINT pk_ref_coverage PRIMARY KEY,
    coverage_name NVARCHAR(40) NOT NULL
);
INSERT INTO etl.ref_coverage (coverage_code, coverage_name) VALUES
('ROUBO', N'Theft and robbery'), ('COLISAO', N'Collision'), ('TERCEIROS', N'Third-party liability'), ('VIDROS', N'Glass');

-- Claim movement types and how each one affects the claim cost
CREATE TABLE etl.ref_movement_type (
    movement_type CHAR(3)      NOT NULL CONSTRAINT pk_ref_movement_type PRIMARY KEY,
    movement_name NVARCHAR(40) NOT NULL
);
INSERT INTO etl.ref_movement_type (movement_type, movement_name) VALUES
('AVI', N'Opening reserve'), ('AJU', N'Reserve adjustment'), ('PAG', N'Payment'), ('SAL', N'Salvage / recovery');
GO

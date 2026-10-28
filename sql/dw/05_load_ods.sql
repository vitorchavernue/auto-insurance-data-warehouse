/* =====================================================================================
   SeguroDW - loading the Operational Data Store from the legacy system
   -------------------------------------------------------------------------------------
   Every procedure follows the same four steps:
   1. Read     - only the legacy rows changed since the last run (watermark with a
                 5-minute overlap for rows committed late), plus rows rejected before,
                 which are retried until the business fixes them. A full run reads all.
   2. Clean    - fix types and formats, map codes, decide if the row can be loaded.
   3. Upsert   - MERGE into the ODS. A row is only touched when a value really changed
                 and the legacy change is not older than what the ODS already has, so
                 running twice changes nothing. Touched rows get this run's id.
   4. Record   - rejected rows (with reason and money involved), resolved rejections,
                 the new watermark and the step log.
   The legacy database is read with plain SELECTs; nothing is ever written there.
   ===================================================================================== */

/* -------------------------------------------------------------------------------------
   Watermark helpers
   ------------------------------------------------------------------------------------- */

-- Where to start reading a legacy table (NULL = read everything)
CREATE OR ALTER FUNCTION etl.fn_read_since (@source_table SYSNAME, @full BIT)
RETURNS TABLE
AS
RETURN
SELECT CASE WHEN @full = 1 THEN NULL ELSE DATEADD(MINUTE, -5, w.last_changed_at) END AS since
FROM etl.watermark AS w
WHERE w.source_table = @source_table;
GO

-- Moves the watermark forward to the newest change read (never backwards)
CREATE OR ALTER PROCEDURE etl.usp_move_watermark @source_table SYSNAME, @newest DATETIME, @run_id INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE etl.watermark
    SET last_changed_at = CASE WHEN last_changed_at IS NULL OR @newest > last_changed_at THEN @newest ELSE last_changed_at END,
        updated_run_id = @run_id
    WHERE source_table = @source_table AND @newest IS NOT NULL;
END
GO

/* -------------------------------------------------------------------------------------
   Brokers and products (small reference tables)
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_load_ods_broker @run_id INT, @full BIT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3) = SYSDATETIME(), @rows INT;
    DECLARE @since DATETIME = (SELECT since FROM etl.fn_read_since('Corretor', @full));

    SELECT CdCorretor, NmCorretor, NrSusep, SgUf, FlAtivo, DtAlteracao
    INTO #src
    FROM SeguroLegado.dbo.Corretor
    WHERE @since IS NULL OR DtAlteracao > @since;

    MERGE ods.broker AS t
    USING (
        SELECT CdCorretor AS broker_id,
               LTRIM(RTRIM(NmCorretor)) AS broker_name,
               NULLIF(LTRIM(RTRIM(NrSusep)), '') AS susep_code,
               st.state_code,
               CAST(CASE WHEN FlAtivo = 'S' THEN 1 ELSE 0 END AS BIT) AS is_active,
               DtAlteracao AS source_changed_at
        FROM #src
        LEFT JOIN etl.ref_state AS st ON st.state_code = UPPER(LTRIM(RTRIM(SgUf)))
    ) AS s
    ON t.broker_id = s.broker_id
    WHEN MATCHED AND s.source_changed_at >= t.source_changed_at
         AND EXISTS (SELECT s.broker_name, s.susep_code, s.state_code, s.is_active
                     EXCEPT SELECT t.broker_name, t.susep_code, t.state_code, t.is_active)
        THEN UPDATE SET broker_name = s.broker_name, susep_code = s.susep_code, state_code = s.state_code,
                        is_active = s.is_active, source_changed_at = s.source_changed_at, ods_run_id = @run_id
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (broker_id, broker_name, susep_code, state_code, is_active, source_changed_at, ods_run_id)
             VALUES (s.broker_id, s.broker_name, s.susep_code, s.state_code, s.is_active, s.source_changed_at, @run_id);
    SET @rows = @@ROWCOUNT;

    DECLARE @newest DATETIME = (SELECT MAX(DtAlteracao) FROM #src);
    EXEC etl.usp_move_watermark 'Corretor', @newest, @run_id;
    EXEC etl.usp_log_step @run_id, 'ods.broker', @rows, @started;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_load_ods_product @run_id INT, @full BIT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3) = SYSDATETIME(), @rows INT;
    DECLARE @since DATETIME = (SELECT since FROM etl.fn_read_since('Produto', @full));

    SELECT CdProduto, DsProduto, DtAlteracao
    INTO #src
    FROM SeguroLegado.dbo.Produto
    WHERE @since IS NULL OR DtAlteracao > @since;

    MERGE ods.product AS t
    USING (SELECT CdProduto AS product_id, LTRIM(RTRIM(DsProduto)) AS product_name, DtAlteracao AS source_changed_at FROM #src) AS s
    ON t.product_id = s.product_id
    WHEN MATCHED AND s.source_changed_at >= t.source_changed_at AND s.product_name <> t.product_name
        THEN UPDATE SET product_name = s.product_name, source_changed_at = s.source_changed_at, ods_run_id = @run_id
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (product_id, product_name, source_changed_at, ods_run_id)
             VALUES (s.product_id, s.product_name, s.source_changed_at, @run_id);
    SET @rows = @@ROWCOUNT;

    DECLARE @newest DATETIME = (SELECT MAX(DtAlteracao) FROM #src);
    EXEC etl.usp_move_watermark 'Produto', @newest, @run_id;
    EXEC etl.usp_log_step @run_id, 'ods.product', @rows, @started;
END
GO

/* -------------------------------------------------------------------------------------
   Customers: CPF repaired and validated, birth date parsed, state code checked.
   Invalid CPFs are flagged, not rejected: the customer has real policies and premium.
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_load_ods_customer @run_id INT, @full BIT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3) = SYSDATETIME(), @rows INT;
    DECLARE @since DATETIME = (SELECT since FROM etl.fn_read_since('Segurado', @full));

    -- 1. Read what changed
    SELECT CdSegurado, NmSegurado, NrCpf, DtNascimento, SgUf, NmCidade, DtAlteracao
    INTO #src
    FROM SeguroLegado.dbo.Segurado
    WHERE @since IS NULL OR DtAlteracao > @since;

    -- 2. Clean
    SELECT s.CdSegurado AS customer_id,
           LTRIM(RTRIM(s.NmSegurado)) AS full_name,
           c.cpf,
           c.cpf_is_valid,
           b.birth_date,
           st.state_code,
           NULLIF(LTRIM(RTRIM(s.NmCidade)), '') AS city,
           s.DtAlteracao AS source_changed_at
    INTO #clean
    FROM #src AS s
    CROSS APPLY etl.fn_parse_cpf(s.NrCpf) AS c
    CROSS APPLY etl.fn_parse_birth_date(s.DtNascimento, CAST(s.DtAlteracao AS DATE)) AS b
    LEFT JOIN etl.ref_state AS st ON st.state_code = UPPER(LTRIM(RTRIM(s.SgUf)));

    -- 3. Upsert
    MERGE ods.customer AS t
    USING #clean AS s
    ON t.customer_id = s.customer_id
    WHEN MATCHED AND s.source_changed_at >= t.source_changed_at
         AND EXISTS (SELECT s.full_name, s.cpf, s.cpf_is_valid, s.birth_date, s.state_code, s.city
                     EXCEPT SELECT t.full_name, t.cpf, t.cpf_is_valid, t.birth_date, t.state_code, t.city)
        THEN UPDATE SET full_name = s.full_name, cpf = s.cpf, cpf_is_valid = s.cpf_is_valid, birth_date = s.birth_date,
                        state_code = s.state_code, city = s.city, source_changed_at = s.source_changed_at, ods_run_id = @run_id
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (customer_id, full_name, cpf, cpf_is_valid, birth_date, state_code, city, source_changed_at, ods_run_id)
             VALUES (s.customer_id, s.full_name, s.cpf, s.cpf_is_valid, s.birth_date, s.state_code, s.city, s.source_changed_at, @run_id);
    SET @rows = @@ROWCOUNT;

    -- 4. Record
    DECLARE @newest DATETIME = (SELECT MAX(DtAlteracao) FROM #src);
    EXEC etl.usp_move_watermark 'Segurado', @newest, @run_id;
    EXEC etl.usp_log_step @run_id, 'ods.customer', @rows, @started;
END
GO

/* -------------------------------------------------------------------------------------
   Vehicles: hand-typed category mapped to the standard list (unknown spellings become
   OUTROS and show up in the data quality report instead of breaking the load).
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_load_ods_vehicle @run_id INT, @full BIT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3) = SYSDATETIME(), @rows INT;
    DECLARE @since DATETIME = (SELECT since FROM etl.fn_read_since('Veiculo', @full));

    SELECT CdVeiculo, CdSegurado, NrPlaca, CdFipe, NmMarca, NmModelo, NrAnoModelo, DsCategoria, VlFipe, DtAlteracao
    INTO #src
    FROM SeguroLegado.dbo.Veiculo
    WHERE @since IS NULL OR DtAlteracao > @since;

    MERGE ods.vehicle AS t
    USING (
        SELECT v.CdVeiculo AS vehicle_id,
               v.CdSegurado AS customer_id,
               UPPER(REPLACE(LTRIM(RTRIM(v.NrPlaca)), '-', '')) AS plate,
               NULLIF(LTRIM(RTRIM(v.CdFipe)), '') AS fipe_code,
               LTRIM(RTRIM(v.NmMarca)) AS make,
               LTRIM(RTRIM(v.NmModelo)) AS model,
               v.NrAnoModelo AS model_year,
               ISNULL(m.category_code, 'OUTROS') AS category_code,
               v.VlFipe AS fipe_value,
               v.DtAlteracao AS source_changed_at
        FROM #src AS v
        LEFT JOIN etl.map_vehicle_category AS m ON m.typed_value = UPPER(LTRIM(RTRIM(v.DsCategoria)))
    ) AS s
    ON t.vehicle_id = s.vehicle_id
    WHEN MATCHED AND s.source_changed_at >= t.source_changed_at
         AND EXISTS (SELECT s.customer_id, s.plate, s.fipe_code, s.make, s.model, s.model_year, s.category_code, s.fipe_value
                     EXCEPT SELECT t.customer_id, t.plate, t.fipe_code, t.make, t.model, t.model_year, t.category_code, t.fipe_value)
        THEN UPDATE SET customer_id = s.customer_id, plate = s.plate, fipe_code = s.fipe_code, make = s.make, model = s.model,
                        model_year = s.model_year, category_code = s.category_code, fipe_value = s.fipe_value,
                        source_changed_at = s.source_changed_at, ods_run_id = @run_id
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (vehicle_id, customer_id, plate, fipe_code, make, model, model_year, category_code, fipe_value, source_changed_at, ods_run_id)
             VALUES (s.vehicle_id, s.customer_id, s.plate, s.fipe_code, s.make, s.model, s.model_year, s.category_code, s.fipe_value,
                     s.source_changed_at, @run_id);
    SET @rows = @@ROWCOUNT;

    DECLARE @newest DATETIME = (SELECT MAX(DtAlteracao) FROM #src);
    EXEC etl.usp_move_watermark 'Veiculo', @newest, @run_id;
    EXEC etl.usp_log_step @run_id, 'ods.vehicle', @rows, @started;
END
GO

/* -------------------------------------------------------------------------------------
   Policies: dates become real dates; cancellations recorded late are picked up because
   the legacy "changed at" moves when the cancellation is typed.
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_load_ods_policy @run_id INT, @full BIT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3) = SYSDATETIME(), @rows INT;
    DECLARE @since DATETIME = (SELECT since FROM etl.fn_read_since('Apolice', @full));

    SELECT NrApolice, CdSegurado, CdVeiculo, CdCorretor, CdProduto, DtEmissao, DtInicioVigencia, DtFimVigencia,
           DtCancelamento, NrApoliceAnterior, DtAlteracao
    INTO #src
    FROM SeguroLegado.dbo.Apolice
    WHERE @since IS NULL OR DtAlteracao > @since;

    MERGE ods.policy AS t
    USING (
        SELECT NrApolice AS policy_number, CdSegurado AS customer_id, CdVeiculo AS vehicle_id, CdCorretor AS broker_id,
               CdProduto AS product_id, CAST(DtEmissao AS DATE) AS issued_on, CAST(DtInicioVigencia AS DATE) AS start_date,
               CAST(DtFimVigencia AS DATE) AS end_date, CAST(DtCancelamento AS DATE) AS cancelled_on,
               NrApoliceAnterior AS previous_policy_number, DtAlteracao AS source_changed_at
        FROM #src
    ) AS s
    ON t.policy_number = s.policy_number
    WHEN MATCHED AND s.source_changed_at >= t.source_changed_at
         AND EXISTS (SELECT s.customer_id, s.vehicle_id, s.broker_id, s.product_id, s.issued_on, s.start_date, s.end_date,
                            s.cancelled_on, s.previous_policy_number
                     EXCEPT SELECT t.customer_id, t.vehicle_id, t.broker_id, t.product_id, t.issued_on, t.start_date, t.end_date,
                            t.cancelled_on, t.previous_policy_number)
        THEN UPDATE SET customer_id = s.customer_id, vehicle_id = s.vehicle_id, broker_id = s.broker_id, product_id = s.product_id,
                        issued_on = s.issued_on, start_date = s.start_date, end_date = s.end_date, cancelled_on = s.cancelled_on,
                        previous_policy_number = s.previous_policy_number, source_changed_at = s.source_changed_at, ods_run_id = @run_id
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (policy_number, customer_id, vehicle_id, broker_id, product_id, issued_on, start_date, end_date, cancelled_on,
                     previous_policy_number, source_changed_at, ods_run_id)
             VALUES (s.policy_number, s.customer_id, s.vehicle_id, s.broker_id, s.product_id, s.issued_on, s.start_date, s.end_date,
                     s.cancelled_on, s.previous_policy_number, s.source_changed_at, @run_id);
    SET @rows = @@ROWCOUNT;

    DECLARE @newest DATETIME = (SELECT MAX(DtAlteracao) FROM #src);
    EXEC etl.usp_move_watermark 'Apolice', @newest, @run_id;
    EXEC etl.usp_log_step @run_id, 'ods.policy', @rows, @started;
END
GO

/* -------------------------------------------------------------------------------------
   Policy coverages. Rejected when:
   - the policy is not in the ODS (it would be premium without a policy);
   - the premium is zero or negative (typing error: it would distort the loss ratio);
   - the coverage code is not one the insurer sells.
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_load_ods_policy_coverage @run_id INT, @full BIT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3) = SYSDATETIME(), @rows INT;
    DECLARE @since DATETIME = (SELECT since FROM etl.fn_read_since('ApoliceCobertura', @full));

    -- 1. Changed rows + rows rejected before (retried until fixed)
    SELECT c.NrApolice, c.CdCobertura, c.VlImportanciaSegurada, c.VlPremioLiquido, c.DtAlteracao
    INTO #src
    FROM SeguroLegado.dbo.ApoliceCobertura AS c
    WHERE @since IS NULL OR c.DtAlteracao > @since
       OR EXISTS (SELECT 1 FROM etl.rejected_row AS r
                  WHERE r.source_table = 'ApoliceCobertura' AND r.resolved_run_id IS NULL
                    AND r.source_key = CONCAT(c.NrApolice, '|', c.CdCobertura));

    -- 2. Clean and decide
    SELECT s.NrApolice AS policy_number,
           UPPER(LTRIM(RTRIM(s.CdCobertura))) AS coverage_code,
           s.VlImportanciaSegurada AS sum_insured,
           s.VlPremioLiquido AS net_premium,
           s.DtAlteracao AS source_changed_at,
           CONCAT(s.NrApolice, '|', s.CdCobertura) AS source_key,
           CASE
               WHEN p.policy_number IS NULL THEN 'policy does not exist in the legacy system or was not loaded'
               WHEN s.VlPremioLiquido IS NULL OR s.VlPremioLiquido <= 0 THEN 'premium zero or negative'
               WHEN rc.coverage_code IS NULL THEN 'coverage code not sold by the insurer'
           END AS reject_reason,
           (SELECT s.NrApolice, s.CdCobertura, s.VlImportanciaSegurada, s.VlPremioLiquido FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS payload
    INTO #clean
    FROM #src AS s
    LEFT JOIN ods.policy AS p ON p.policy_number = s.NrApolice
    LEFT JOIN etl.ref_coverage AS rc ON rc.coverage_code = UPPER(LTRIM(RTRIM(s.CdCobertura)));

    -- 3. Upsert the valid rows
    MERGE ods.policy_coverage AS t
    USING (SELECT * FROM #clean WHERE reject_reason IS NULL) AS s
    ON t.policy_number = s.policy_number AND t.coverage_code = s.coverage_code
    WHEN MATCHED AND s.source_changed_at >= t.source_changed_at
         AND EXISTS (SELECT s.sum_insured, s.net_premium EXCEPT SELECT t.sum_insured, t.net_premium)
        THEN UPDATE SET sum_insured = s.sum_insured, net_premium = s.net_premium, source_changed_at = s.source_changed_at, ods_run_id = @run_id
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (policy_number, coverage_code, sum_insured, net_premium, source_changed_at, ods_run_id)
             VALUES (s.policy_number, s.coverage_code, s.sum_insured, s.net_premium, s.source_changed_at, @run_id);
    SET @rows = @@ROWCOUNT;

    -- 4. Rejections: record new ones (once), close the ones that now load
    INSERT INTO etl.rejected_row (run_id, source_table, source_key, reason, amount, payload)
    SELECT @run_id, 'ApoliceCobertura', c.source_key, c.reject_reason, c.net_premium, c.payload
    FROM #clean AS c
    WHERE c.reject_reason IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM etl.rejected_row AS r
                      WHERE r.source_table = 'ApoliceCobertura' AND r.source_key = c.source_key AND r.resolved_run_id IS NULL);

    UPDATE r SET resolved_run_id = @run_id
    FROM etl.rejected_row AS r
    JOIN #clean AS c ON c.source_key = r.source_key AND c.reject_reason IS NULL
    WHERE r.source_table = 'ApoliceCobertura' AND r.resolved_run_id IS NULL;

    DECLARE @newest DATETIME = (SELECT MAX(DtAlteracao) FROM #src);
    EXEC etl.usp_move_watermark 'ApoliceCobertura', @newest, @run_id;
    EXEC etl.usp_log_step @run_id, 'ods.policy_coverage', @rows, @started;
END
GO

/* -------------------------------------------------------------------------------------
   Claims. Rejected when the policy does not exist (a claim typed with a wrong policy
   number cannot be priced against any premium). Claims that happened outside the policy
   period are loaded and flagged later in the warehouse: the money was really reserved
   or paid, so it must stay in the numbers.
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_load_ods_claim @run_id INT, @full BIT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3) = SYSDATETIME(), @rows INT;
    DECLARE @since DATETIME = (SELECT since FROM etl.fn_read_since('Sinistro', @full));

    SELECT s.NrSinistro, s.NrApolice, s.CdCobertura, s.DtOcorrencia, s.DtAviso, s.DsCausa, s.SgUfOcorrencia, s.CdSituacao, s.DtAlteracao
    INTO #src
    FROM SeguroLegado.dbo.Sinistro AS s
    WHERE @since IS NULL OR s.DtAlteracao > @since
       OR EXISTS (SELECT 1 FROM etl.rejected_row AS r
                  WHERE r.source_table = 'Sinistro' AND r.resolved_run_id IS NULL AND r.source_key = CAST(s.NrSinistro AS VARCHAR(60)));

    SELECT s.NrSinistro AS claim_number,
           s.NrApolice AS policy_number,
           UPPER(LTRIM(RTRIM(s.CdCobertura))) AS coverage_code,
           CAST(s.DtOcorrencia AS DATE) AS occurred_on,
           s.DtAviso AS reported_at,
           NULLIF(UPPER(LTRIM(RTRIM(s.DsCausa))), '') AS cause,
           st.state_code,
           s.CdSituacao AS status_code,
           s.DtAlteracao AS source_changed_at,
           CAST(s.NrSinistro AS VARCHAR(60)) AS source_key,
           CASE
               WHEN p.policy_number IS NULL THEN 'policy does not exist in the legacy system or was not loaded'
               WHEN s.CdSituacao NOT IN ('A', 'P', 'N', 'R') THEN 'unknown claim status'
           END AS reject_reason,
           (SELECT s.NrSinistro, s.NrApolice, s.CdCobertura, s.DtOcorrencia, s.DtAviso, s.CdSituacao FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS payload
    INTO #clean
    FROM #src AS s
    LEFT JOIN ods.policy AS p ON p.policy_number = s.NrApolice
    LEFT JOIN etl.ref_state AS st ON st.state_code = UPPER(LTRIM(RTRIM(s.SgUfOcorrencia)));

    MERGE ods.claim AS t
    USING (SELECT * FROM #clean WHERE reject_reason IS NULL) AS s
    ON t.claim_number = s.claim_number
    WHEN MATCHED AND s.source_changed_at >= t.source_changed_at
         AND EXISTS (SELECT s.policy_number, s.coverage_code, s.occurred_on, s.reported_at, s.cause, s.state_code, s.status_code
                     EXCEPT SELECT t.policy_number, t.coverage_code, t.occurred_on, t.reported_at, t.cause, t.state_code, t.status_code)
        THEN UPDATE SET policy_number = s.policy_number, coverage_code = s.coverage_code, occurred_on = s.occurred_on,
                        reported_at = s.reported_at, cause = s.cause, state_code = s.state_code, status_code = s.status_code,
                        source_changed_at = s.source_changed_at, ods_run_id = @run_id
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (claim_number, policy_number, coverage_code, occurred_on, reported_at, cause, state_code, status_code,
                     source_changed_at, ods_run_id)
             VALUES (s.claim_number, s.policy_number, s.coverage_code, s.occurred_on, s.reported_at, s.cause, s.state_code,
                     s.status_code, s.source_changed_at, @run_id);
    SET @rows = @@ROWCOUNT;

    INSERT INTO etl.rejected_row (run_id, source_table, source_key, reason, payload)
    SELECT @run_id, 'Sinistro', c.source_key, c.reject_reason, c.payload
    FROM #clean AS c
    WHERE c.reject_reason IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM etl.rejected_row AS r
                      WHERE r.source_table = 'Sinistro' AND r.source_key = c.source_key AND r.resolved_run_id IS NULL);

    UPDATE r SET resolved_run_id = @run_id
    FROM etl.rejected_row AS r
    JOIN #clean AS c ON c.source_key = r.source_key AND c.reject_reason IS NULL
    WHERE r.source_table = 'Sinistro' AND r.resolved_run_id IS NULL;

    DECLARE @newest DATETIME = (SELECT MAX(DtAlteracao) FROM #src);
    EXEC etl.usp_move_watermark 'Sinistro', @newest, @run_id;
    EXEC etl.usp_log_step @run_id, 'ods.claim', @rows, @started;
END
GO

/* -------------------------------------------------------------------------------------
   Claim movements. Rejected when the claim is not in the ODS (it does not exist or was
   rejected itself): the money goes to the rejected list for the claims team. When a
   claim is fixed, its movements are retried and loaded on the same run (claims load first).
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_load_ods_claim_movement @run_id INT, @full BIT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3) = SYSDATETIME(), @rows INT;
    DECLARE @since DATETIME = (SELECT since FROM etl.fn_read_since('SinistroMovimento', @full));

    SELECT m.NrSinistro, m.NrSequencia, m.DtMovimento, m.TpMovimento, m.VlMovimento, m.DtAlteracao
    INTO #src
    FROM SeguroLegado.dbo.SinistroMovimento AS m
    WHERE @since IS NULL OR m.DtAlteracao > @since
       OR EXISTS (SELECT 1 FROM etl.rejected_row AS r
                  WHERE r.source_table = 'SinistroMovimento' AND r.resolved_run_id IS NULL
                    AND r.source_key = CONCAT(m.NrSinistro, '|', m.NrSequencia));

    SELECT s.NrSinistro AS claim_number,
           s.NrSequencia AS sequence_number,
           CAST(s.DtMovimento AS DATE) AS movement_date,
           s.TpMovimento AS movement_type,
           s.VlMovimento AS amount,
           s.DtAlteracao AS source_changed_at,
           CONCAT(s.NrSinistro, '|', s.NrSequencia) AS source_key,
           CASE
               WHEN c.claim_number IS NULL THEN 'claim does not exist in the legacy system or was rejected'
               WHEN mt.movement_type IS NULL THEN 'unknown movement type'
           END AS reject_reason,
           (SELECT s.NrSinistro, s.NrSequencia, s.DtMovimento, s.TpMovimento, s.VlMovimento FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS payload
    INTO #clean
    FROM #src AS s
    LEFT JOIN ods.claim AS c ON c.claim_number = s.NrSinistro
    LEFT JOIN etl.ref_movement_type AS mt ON mt.movement_type = s.TpMovimento;

    MERGE ods.claim_movement AS t
    USING (SELECT * FROM #clean WHERE reject_reason IS NULL) AS s
    ON t.claim_number = s.claim_number AND t.sequence_number = s.sequence_number
    WHEN MATCHED AND s.source_changed_at >= t.source_changed_at
         AND EXISTS (SELECT s.movement_date, s.movement_type, s.amount EXCEPT SELECT t.movement_date, t.movement_type, t.amount)
        THEN UPDATE SET movement_date = s.movement_date, movement_type = s.movement_type, amount = s.amount,
                        source_changed_at = s.source_changed_at, ods_run_id = @run_id
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (claim_number, sequence_number, movement_date, movement_type, amount, source_changed_at, ods_run_id)
             VALUES (s.claim_number, s.sequence_number, s.movement_date, s.movement_type, s.amount, s.source_changed_at, @run_id);
    SET @rows = @@ROWCOUNT;

    INSERT INTO etl.rejected_row (run_id, source_table, source_key, reason, amount, payload)
    SELECT @run_id, 'SinistroMovimento', c.source_key, c.reject_reason, c.amount, c.payload
    FROM #clean AS c
    WHERE c.reject_reason IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM etl.rejected_row AS r
                      WHERE r.source_table = 'SinistroMovimento' AND r.source_key = c.source_key AND r.resolved_run_id IS NULL);

    UPDATE r SET resolved_run_id = @run_id
    FROM etl.rejected_row AS r
    JOIN #clean AS c ON c.source_key = r.source_key AND c.reject_reason IS NULL
    WHERE r.source_table = 'SinistroMovimento' AND r.resolved_run_id IS NULL;

    DECLARE @newest DATETIME = (SELECT MAX(DtAlteracao) FROM #src);
    EXEC etl.usp_move_watermark 'SinistroMovimento', @newest, @run_id;
    EXEC etl.usp_log_step @run_id, 'ods.claim_movement', @rows, @started;
END
GO

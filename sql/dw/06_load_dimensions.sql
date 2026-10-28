/* =====================================================================================
   SeguroDW - loading the dimensions from the ODS
   -------------------------------------------------------------------------------------
   Only ODS rows changed in this run (ods_run_id = @run_id) are processed; a full run
   processes every row. Dimension keys never change once created, so facts loaded
   earlier keep pointing to the right row.
   ===================================================================================== */

/* -------------------------------------------------------------------------------------
   Customer - SCD type 2 on the address (state, city), type 1 on name, CPF and birth date
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_load_dim_customer @run_id INT, @full BIT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3) = SYSDATETIME(), @rows INT = 0;

    -- Customers changed in this run, with the values the dimension stores
    SELECT c.customer_id,
           c.full_name,
           CASE WHEN c.cpf IS NULL THEN NULL ELSE CONCAT('***.', SUBSTRING(c.cpf, 4, 3), '.', SUBSTRING(c.cpf, 7, 3), '-**') END AS cpf_masked,
           c.cpf_is_valid,
           c.birth_date,
           ISNULL(c.state_code, '??') AS state_code,
           c.city,
           ISNULL(g.geography_key, -1) AS geography_key,
           CAST(c.source_changed_at AS DATE) AS changed_on
    INTO #chg
    FROM ods.customer AS c
    LEFT JOIN dw.dim_geography AS g ON g.state_code = c.state_code
    WHERE @full = 1 OR c.ods_run_id = @run_id;

    -- 1. Corrections (type 1): applied to every version of the customer
    UPDATE d
    SET full_name = c.full_name, cpf_masked = c.cpf_masked, cpf_is_valid = c.cpf_is_valid, birth_date = c.birth_date, dw_run_id = @run_id
    FROM dw.dim_customer AS d
    JOIN #chg AS c ON c.customer_id = d.customer_id
    WHERE EXISTS (SELECT d.full_name, d.cpf_masked, d.cpf_is_valid, d.birth_date
                  EXCEPT SELECT c.full_name, c.cpf_masked, c.cpf_is_valid, c.birth_date);
    SET @rows += @@ROWCOUNT;

    -- 2. New address on the same day the current version started: overwrite it (no one-day versions)
    UPDATE d
    SET state_code = c.state_code, city = c.city, geography_key = c.geography_key, dw_run_id = @run_id
    FROM dw.dim_customer AS d
    JOIN #chg AS c ON c.customer_id = d.customer_id
    WHERE d.is_current = 1 AND d.valid_from >= c.changed_on
      AND EXISTS (SELECT d.state_code, d.city EXCEPT SELECT c.state_code, c.city);
    SET @rows += @@ROWCOUNT;

    -- 3. New address on a later day: close the current version the day the change happened ...
    UPDATE d
    SET valid_to = c.changed_on, is_current = 0, dw_run_id = @run_id
    FROM dw.dim_customer AS d
    JOIN #chg AS c ON c.customer_id = d.customer_id
    WHERE d.is_current = 1 AND d.valid_from < c.changed_on
      AND EXISTS (SELECT d.state_code, d.city EXCEPT SELECT c.state_code, c.city);
    SET @rows += @@ROWCOUNT;

    -- 4. ... and open the new version. New customers get their first version, valid since 1900.
    INSERT INTO dw.dim_customer (customer_id, full_name, cpf_masked, cpf_is_valid, birth_date, state_code, city, geography_key,
                                 valid_from, valid_to, is_current, dw_run_id)
    SELECT c.customer_id, c.full_name, c.cpf_masked, c.cpf_is_valid, c.birth_date, c.state_code, c.city, c.geography_key,
           CASE WHEN EXISTS (SELECT 1 FROM dw.dim_customer AS d WHERE d.customer_id = c.customer_id) THEN c.changed_on ELSE '19000101' END,
           '99991231', 1, @run_id
    FROM #chg AS c
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_customer AS d WHERE d.customer_id = c.customer_id AND d.is_current = 1);
    SET @rows += @@ROWCOUNT;

    EXEC etl.usp_log_step @run_id, 'dw.dim_customer', @rows, @started;
END
GO

/* -------------------------------------------------------------------------------------
   Vehicle, broker, product - type 1 (the latest value is the truth)
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_load_dim_vehicle @run_id INT, @full BIT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3) = SYSDATETIME(), @rows INT;

    MERGE dw.dim_vehicle AS t
    USING (
        SELECT v.vehicle_id,
               v.category_code,
               CASE v.category_code WHEN 'AUTO' THEN N'Car' WHEN 'MOTO' THEN N'Motorcycle' WHEN 'CAMINHAO' THEN N'Truck' ELSE N'Other' END
                   AS category_name,
               v.make,
               v.model,
               v.model_year,
               -- Age of the model in the year the warehouse was built; older vehicles are cheaper but harder to repair
               CASE WHEN v.model_year IS NULL THEN 'Unknown'
                    WHEN v.model_year >= 2023 THEN '0-3 years'
                    WHEN v.model_year >= 2019 THEN '4-7 years'
                    WHEN v.model_year >= 2014 THEN '8-12 years'
                    ELSE '13+ years' END AS vehicle_age,
               v.fipe_value,
               -- Value bands used by underwriting
               CASE WHEN v.fipe_value IS NULL THEN 'Unknown'
                    WHEN v.fipe_value < 30000 THEN '1. Up to R$ 30k'
                    WHEN v.fipe_value < 80000 THEN '2. R$ 30k-80k'
                    WHEN v.fipe_value < 150000 THEN '3. R$ 80k-150k'
                    WHEN v.fipe_value < 400000 THEN '4. R$ 150k-400k'
                    ELSE '5. Over R$ 400k' END AS fipe_band
        FROM ods.vehicle AS v
        WHERE @full = 1 OR v.ods_run_id = @run_id
    ) AS s
    ON t.vehicle_id = s.vehicle_id
    WHEN MATCHED AND EXISTS (SELECT s.category_code, s.make, s.model, s.model_year, s.fipe_value
                             EXCEPT SELECT t.category_code, t.make, t.model, t.model_year, t.fipe_value)
        THEN UPDATE SET category_code = s.category_code, category_name = s.category_name, make = s.make, model = s.model,
                        model_year = s.model_year, vehicle_age = s.vehicle_age, fipe_value = s.fipe_value, fipe_band = s.fipe_band,
                        dw_run_id = @run_id
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (vehicle_id, category_code, category_name, make, model, model_year, vehicle_age, fipe_value, fipe_band, dw_run_id)
             VALUES (s.vehicle_id, s.category_code, s.category_name, s.make, s.model, s.model_year, s.vehicle_age, s.fipe_value,
                     s.fipe_band, @run_id);
    SET @rows = @@ROWCOUNT;

    EXEC etl.usp_log_step @run_id, 'dw.dim_vehicle', @rows, @started;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_load_dim_broker @run_id INT, @full BIT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3) = SYSDATETIME(), @rows INT;

    MERGE dw.dim_broker AS t
    USING (SELECT broker_id, broker_name, susep_code, state_code, is_active FROM ods.broker WHERE @full = 1 OR ods_run_id = @run_id) AS s
    ON t.broker_id = s.broker_id
    WHEN MATCHED AND EXISTS (SELECT s.broker_name, s.susep_code, s.state_code, s.is_active
                             EXCEPT SELECT t.broker_name, t.susep_code, t.state_code, t.is_active)
        THEN UPDATE SET broker_name = s.broker_name, susep_code = s.susep_code, state_code = s.state_code,
                        is_active = s.is_active, dw_run_id = @run_id
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (broker_id, broker_name, susep_code, state_code, is_active, dw_run_id)
             VALUES (s.broker_id, s.broker_name, s.susep_code, s.state_code, s.is_active, @run_id);
    SET @rows = @@ROWCOUNT;

    EXEC etl.usp_log_step @run_id, 'dw.dim_broker', @rows, @started;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_load_dim_product @run_id INT, @full BIT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started DATETIME2(3) = SYSDATETIME(), @rows INT;

    MERGE dw.dim_product AS t
    USING (SELECT product_id, product_name FROM ods.product WHERE @full = 1 OR ods_run_id = @run_id) AS s
    ON t.product_id = s.product_id
    WHEN MATCHED AND s.product_name <> t.product_name
        THEN UPDATE SET product_name = s.product_name, dw_run_id = @run_id
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (product_id, product_name, dw_run_id) VALUES (s.product_id, s.product_name, @run_id);
    SET @rows = @@ROWCOUNT;

    EXEC etl.usp_log_step @run_id, 'dw.dim_product', @rows, @started;
END
GO

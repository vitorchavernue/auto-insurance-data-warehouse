/* =====================================================================================
   SeguroDW - the nightly run (orchestrator)
   -------------------------------------------------------------------------------------
   One call does everything, in dependency order:
     ODS (legacy -> cleaned tables) -> dimensions -> facts -> data quality checks.

   All of it runs in a single transaction: a run either lands completely or not at all.
   If anything fails, everything is rolled back (watermarks included), so the next run
   simply picks up the same changes again; nobody has to clean up half-loaded tables.

   Result:
     passed - every critical check passed, the data can be used
     failed - data loaded, a critical check failed: reports must not use it (alert)
     error  - the run stopped and was rolled back (the message is in etl.run)

   Usage:
     EXEC etl.usp_run;                                    -- nightly: closes yesterday
     EXEC etl.usp_run @as_of_date = '2026-09-30';         -- a specific business date
     EXEC etl.usp_run @as_of_date = '2026-09-30', @mode = 'full';  -- re-read everything and rebuild the facts
   ===================================================================================== */

CREATE OR ALTER PROCEDURE etl.usp_run
    @as_of_date DATE = NULL,
    @mode VARCHAR(12) = 'incremental'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;  -- any error dooms the transaction, so nothing is half-committed

    IF @as_of_date IS NULL
        SET @as_of_date = DATEADD(DAY, -1, CAST(SYSDATETIME() AS DATE));  -- the nightly job closes the day before
    IF @mode NOT IN ('incremental', 'full')
        THROW 50001, 'mode must be incremental or full', 1;

    DECLARE @full BIT = CASE WHEN @mode = 'full' THEN 1 ELSE 0 END;

    -- The run row is written outside the transaction: it survives a rollback and tells what happened
    INSERT INTO etl.run (as_of_date, mode) VALUES (@as_of_date, @mode);
    DECLARE @run_id INT = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. Operational Data Store (parents before children: rejections depend on it)
        EXEC etl.usp_load_ods_broker @run_id, @full;
        EXEC etl.usp_load_ods_product @run_id, @full;
        EXEC etl.usp_load_ods_customer @run_id, @full;
        EXEC etl.usp_load_ods_vehicle @run_id, @full;
        EXEC etl.usp_load_ods_policy @run_id, @full;
        EXEC etl.usp_load_ods_policy_coverage @run_id, @full;
        EXEC etl.usp_load_ods_claim @run_id, @full;
        EXEC etl.usp_load_ods_claim_movement @run_id, @full;

        -- 2. Dimensions (before the facts that look them up)
        EXEC etl.usp_load_dim_customer @run_id, @full;
        EXEC etl.usp_load_dim_vehicle @run_id, @full;
        EXEC etl.usp_load_dim_broker @run_id, @full;
        EXEC etl.usp_load_dim_product @run_id, @full;

        -- 3. Facts
        EXEC etl.usp_load_facts @run_id, @full, @as_of_date;

        -- 4. Release gate
        EXEC dq.usp_run_checks @run_id;

        DECLARE @failed INT = (SELECT COUNT(*) FROM dq.check_result WHERE run_id = @run_id AND severity = 'critical' AND passed = 0);
        UPDATE etl.run
        SET status = CASE WHEN @failed = 0 THEN 'passed' ELSE 'failed' END, finished_at = SYSDATETIME()
        WHERE run_id = @run_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        UPDATE etl.run
        SET status = 'error', finished_at = SYSDATETIME(),
            error_message = CONCAT(ERROR_PROCEDURE(), ' (line ', ERROR_LINE(), '): ', ERROR_MESSAGE())
        WHERE run_id = @run_id;
    END CATCH

    SELECT run_id, as_of_date, mode, status, error_message FROM etl.run WHERE run_id = @run_id;
END
GO

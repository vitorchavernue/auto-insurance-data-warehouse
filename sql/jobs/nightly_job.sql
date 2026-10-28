/* =====================================================================================
   SQL Server Agent job: nightly load of SeguroDW
   -------------------------------------------------------------------------------------
   What: runs etl.usp_run every night at 02:30, after the legacy system's own batch.
   The step fails (and the operators are notified through the Agent alert of the
   environment) when the run ends as "failed" or "error", because a report built on
   numbers that did not pass the checks is worse than a report that is one day late.

   Run in msdb. Safe to run again: the job is recreated.
   ===================================================================================== */

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SeguroDW - nightly load')
    EXEC msdb.dbo.sp_delete_job @job_name = N'SeguroDW - nightly load';

EXEC msdb.dbo.sp_add_job
    @job_name = N'SeguroDW - nightly load',
    @description = N'Legacy -> ODS -> star schema -> data quality gate. Fails when the gate does not pass.',
    @enabled = 1;

EXEC msdb.dbo.sp_add_jobstep
    @job_name = N'SeguroDW - nightly load',
    @step_name = N'Run and check the gate',
    @subsystem = N'TSQL',
    @database_name = N'SeguroDW',
    @retry_attempts = 1,          -- one retry: a timeout on the legacy server at night is usually transient
    @retry_interval = 15,         -- minutes
    @command = N'
EXEC etl.usp_run;
-- The run just made is the newest one in the log
DECLARE @status VARCHAR(10), @message NVARCHAR(2048);
SELECT TOP (1) @status = status, @message = CONCAT(''Run '', run_id, '' ended as '', status, ''. '', error_message)
FROM etl.run ORDER BY run_id DESC;
IF @status <> ''passed''
    THROW 50002, @message, 1;   -- the job step fails, the operators are alerted';

EXEC msdb.dbo.sp_add_jobschedule
    @job_name = N'SeguroDW - nightly load',
    @name = N'Every night at 02:30',
    @freq_type = 4,               -- daily
    @freq_interval = 1,
    @active_start_time = 023000;

EXEC msdb.dbo.sp_add_jobserver @job_name = N'SeguroDW - nightly load', @server_name = N'(local)';

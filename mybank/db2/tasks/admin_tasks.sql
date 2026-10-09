-- MyBank plc: jobs scheduled inside Db2 by the Administrative Task Scheduler (ATS).
-- Statement terminator: @
--
-- Needs DB2_ATS_ENABLE=YES in the instance registry and the SYSTOOLSPACE tablespace
-- (see db2/tasks/README.md). Tasks can be registered without either; they just never run.
-- Schedules are UNIX cron format, evaluated in the Db2 server's time zone.
-- Status: SELECT * FROM SYSTOOLS.ADMIN_TASK_STATUS  (one row per task invocation).

-- Re-runnable: drop any previous registration first (ignore "task not found")
BEGIN
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
    CALL SYSPROC.ADMIN_TASK_REMOVE('MYBANK_PURGE_AUDIT_LOG', NULL);
    CALL SYSPROC.ADMIN_TASK_REMOVE('MYBANK_REFRESH_REPORTING_MQTS', NULL);
    CALL SYSPROC.ADMIN_TASK_REMOVE('MYBANK_RUNSTATS', NULL);
END@

-- Hourly, on the hour
CALL SYSPROC.ADMIN_TASK_ADD(
    'MYBANK_PURGE_AUDIT_LOG',
    NULL, NULL, NULL,
    '0 * * * *',
    'BATCH', 'PURGE_AUDIT_LOG',
    NULL, NULL,
    'Purge OPS.AUDIT_LOG / OPS.ERROR_LOG beyond retention')@

-- Every 15 minutes
CALL SYSPROC.ADMIN_TASK_ADD(
    'MYBANK_REFRESH_REPORTING_MQTS',
    NULL, NULL, NULL,
    '0,15,30,45 * * * *',
    'BATCH', 'REFRESH_REPORTING_MQTS',
    NULL, NULL,
    'REFRESH TABLE RPT.MQT_DAILY_LIQUIDITY, RPT.MQT_MERCHANT_SPEND')@

-- Every 30 minutes, offset so it does not collide with the MQT refresh
CALL SYSPROC.ADMIN_TASK_ADD(
    'MYBANK_RUNSTATS',
    NULL, NULL, NULL,
    '5,35 * * * *',
    'BATCH', 'RUNSTATS',
    NULL, NULL,
    'RUNSTATS on high-churn tables via ADMIN_CMD')@

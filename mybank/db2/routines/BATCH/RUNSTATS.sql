-- Db2 admin task (SYSPROC.ADMIN_TASK_ADD, every 30 minutes; see db2/tasks/admin_tasks.sql):
-- refreshes optimizer statistics on the high-churn tables via SYSPROC.ADMIN_CMD('RUNSTATS ...').
-- No parameters (ATS). A table that fails (e.g. lock timeout) is logged and skipped.
CREATE OR REPLACE PROCEDURE BATCH.RUNSTATS ()
    LANGUAGE SQL
    SPECIFIC BATCH_RUNSTATS
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE CHAR(5);
    DECLARE V_SQLCODE  INTEGER;
    DECLARE V_MSG      VARCHAR(1000);
    DECLARE V_RUN_ID   BIGINT;
    DECLARE V_ROWS     INTEGER DEFAULT 0;
    DECLARE V_FAILED   INTEGER DEFAULT 0;
    DECLARE V_CMD      VARCHAR(500);
    DECLARE V_ROW_STATE CHAR(5);
    DECLARE V_ROW_CODE INTEGER;
    DECLARE V_ROW_MSG  VARCHAR(1000);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.END_JOB_RUN(V_RUN_ID, 'F', V_ROWS, V_MSG);
        CALL UTIL.LOG_ERROR('BATCH.RUNSTATS', V_SQLSTATE, V_SQLCODE, V_MSG, NULL);
        RESIGNAL;
    END;

    CALL UTIL.START_JOB_RUN('RUNSTATS', V_RUN_ID);

    FOR T AS C_TABLES CURSOR WITH HOLD FOR
        SELECT TABLE_NAME
          FROM (VALUES (1,  'TXN.POSTED_TXN'),
                       (2,  'GL.GL_ENTRY'),
                       (3,  'CARD.AUTHORISATION'),
                       (4,  'ACCT.ACCOUNT'),
                       (5,  'ACCT.ACCOUNT_HOLD'),
                       (6,  'ACCT.DAILY_BALANCE'),
                       (7,  'ACCT.INTEREST_ACCRUAL'),
                       (8,  'TXN.PENDING_TXN'),
                       (9,  'PAY.PAYMENT'),
                       (10, 'OPS.NOTIFICATION_OUTBOX'),
                       (11, 'OPS.AUDIT_LOG')
               ) AS X (SEQ, TABLE_NAME)
         ORDER BY SEQ
    DO
        SET V_CMD = 'RUNSTATS ON TABLE ' || T.TABLE_NAME
                    || ' WITH DISTRIBUTION AND DETAILED INDEXES ALL';
        SET V_ROW_STATE = '00000';
        STATS_BLOCK:
        BEGIN
            DECLARE EXIT HANDLER FOR SQLEXCEPTION
            BEGIN
                GET DIAGNOSTICS EXCEPTION 1 V_ROW_MSG = MESSAGE_TEXT;
                VALUES (SQLSTATE, SQLCODE) INTO V_ROW_STATE, V_ROW_CODE;
            END;
            CALL SYSPROC.ADMIN_CMD(V_CMD);
        END STATS_BLOCK;

        IF V_ROW_STATE = '00000' THEN
            SET V_ROWS = V_ROWS + 1;
        ELSE
            CALL UTIL.LOG_ERROR('BATCH.RUNSTATS', V_ROW_STATE, V_ROW_CODE, V_ROW_MSG, T.TABLE_NAME);
            SET V_FAILED = V_FAILED + 1;
        END IF;
        COMMIT;
    END FOR;

    CALL UTIL.END_JOB_RUN(V_RUN_ID, 'S', V_ROWS,
         RTRIM(CHAR(V_ROWS)) || ' tables analysed, ' || RTRIM(CHAR(V_FAILED)) || ' failed');
END@

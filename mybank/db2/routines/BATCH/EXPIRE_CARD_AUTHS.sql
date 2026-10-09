-- Intraday (every minute): expires active holds past EXPIRES_TS (status 'E', which releases
-- the ring-fenced funds via TRG_HOLD_RELEASED) and marks card authorisations whose hold
-- has expired as 'X'. Set-based; safe to run as often as you like.
CREATE OR REPLACE PROCEDURE BATCH.EXPIRE_CARD_AUTHS (OUT P_ROWS_PROCESSED INTEGER)
    LANGUAGE SQL
    SPECIFIC BATCH_EXPIRE_CARD_AUTHS
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE CHAR(5);
    DECLARE V_SQLCODE  INTEGER;
    DECLARE V_MSG      VARCHAR(1000);
    DECLARE V_RUN_ID   BIGINT;
    DECLARE V_ROWS     INTEGER DEFAULT 0;
    DECLARE V_HOLDS    INTEGER DEFAULT 0;
    DECLARE V_AUTHS    INTEGER DEFAULT 0;
    DECLARE V_NOW      TIMESTAMP;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.END_JOB_RUN(V_RUN_ID, 'F', V_ROWS, V_MSG);
        CALL UTIL.LOG_ERROR('BATCH.EXPIRE_CARD_AUTHS', V_SQLSTATE, V_SQLCODE, V_MSG, NULL);
        RESIGNAL;
    END;

    CALL UTIL.START_JOB_RUN('EXPIRE_CARD_AUTHS', V_RUN_ID);

    SET V_NOW = CURRENT TIMESTAMP;

    -- Holds first (same order as CARD.AUTHORISE takes its locks: hold, then auth)
    UPDATE ACCT.ACCOUNT_HOLD
       SET STATUS = 'E',
           RELEASED_TS = V_NOW
     WHERE STATUS = 'A'
       AND EXPIRES_TS < V_NOW;
    GET DIAGNOSTICS V_HOLDS = ROW_COUNT;

    -- Any approved auth whose hold has gone: also picks up stragglers from earlier runs
    UPDATE CARD.AUTHORISATION A
       SET A.STATUS = 'X'
     WHERE A.STATUS = 'A'
       AND A.HOLD_ID IS NOT NULL
       AND EXISTS (SELECT 1
                     FROM ACCT.ACCOUNT_HOLD H
                    WHERE H.HOLD_ID = A.HOLD_ID
                      AND H.STATUS = 'E');
    GET DIAGNOSTICS V_AUTHS = ROW_COUNT;

    COMMIT;

    SET V_ROWS = V_HOLDS + V_AUTHS;
    SET P_ROWS_PROCESSED = V_ROWS;
    CALL UTIL.END_JOB_RUN(V_RUN_ID, 'S', V_ROWS,
         RTRIM(CHAR(V_HOLDS)) || ' holds expired, ' || RTRIM(CHAR(V_AUTHS)) || ' auths expired');
END@

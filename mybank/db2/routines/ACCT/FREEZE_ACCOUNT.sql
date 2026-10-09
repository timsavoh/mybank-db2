-- Freezes (P_ACTION 'F') or unfreezes ('U') an account. Frozen accounts take credits
-- but no debits. Called by the app (ops, fraud) and by RISK.RESOLVE_ALERT.
-- Raises 75002 not found, 75003 closed, 75008 bad action / missing reason, 75009 already
-- in the requested state.
CREATE OR REPLACE PROCEDURE ACCT.FREEZE_ACCOUNT (
    IN P_ACCOUNT_ID BIGINT,
    IN P_ACTION     CHAR(1),
    IN P_REASON     VARCHAR(60)
)
    LANGUAGE SQL
    SPECIFIC ACCT_FREEZE_ACCOUNT
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE  CHAR(5);
    DECLARE V_SQLCODE   INTEGER;
    DECLARE V_MSG       VARCHAR(1000);
    DECLARE V_STATUS    CHAR(1);
    DECLARE V_CUSTOMER_ID BIGINT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.LOG_ERROR('ACCT.FREEZE_ACCOUNT', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'ACCOUNT_ID=' || COALESCE(RTRIM(CHAR(P_ACCOUNT_ID)), 'NULL') ||
                            ' ACTION=' || COALESCE(P_ACTION, 'NULL'));
        RESIGNAL;
    END;

    IF P_ACTION IS NULL OR P_ACTION NOT IN ('F', 'U') THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Action must be F (freeze) or U (unfreeze)';
    END IF;

    SELECT STATUS, PRIMARY_CUSTOMER_ID
      INTO V_STATUS, V_CUSTOMER_ID
      FROM ACCT.ACCOUNT
     WHERE ACCOUNT_ID = P_ACCOUNT_ID
      WITH RS USE AND KEEP UPDATE LOCKS;

    IF V_STATUS IS NULL THEN
        SIGNAL SQLSTATE '75002' SET MESSAGE_TEXT = 'Account not found';
    ELSEIF V_STATUS = 'C' THEN
        SIGNAL SQLSTATE '75003' SET MESSAGE_TEXT = 'Account is closed';
    END IF;

    IF P_ACTION = 'F' THEN
        IF V_STATUS = 'F' THEN
            SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Account is already frozen';
        END IF;
        IF COALESCE(RTRIM(P_REASON), '') = '' THEN
            SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'A reason is required to freeze an account';
        END IF;

        UPDATE ACCT.ACCOUNT
           SET STATUS = 'F',
               FREEZE_REASON = P_REASON
         WHERE ACCOUNT_ID = P_ACCOUNT_ID;
    ELSE
        IF V_STATUS <> 'F' THEN
            SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Account is not frozen';
        END IF;

        UPDATE ACCT.ACCOUNT
           SET STATUS = 'A',
               FREEZE_REASON = NULL
         WHERE ACCOUNT_ID = P_ACCOUNT_ID;
    END IF;

    CALL UTIL.WRITE_AUDIT('ACCT.ACCOUNT', RTRIM(CHAR(P_ACCOUNT_ID)), 'U',
                          CASE P_ACTION WHEN 'F' THEN 'Frozen: ' ELSE 'Unfrozen: ' END ||
                          COALESCE(P_REASON, '-'));

    CALL UTIL.ENQUEUE_NOTIFICATION(V_CUSTOMER_ID,
                                   CASE P_ACTION WHEN 'F' THEN 'ACCOUNT_FROZEN' ELSE 'ACCOUNT_UNFROZEN' END,
                                   '{"accountId":' || RTRIM(CHAR(P_ACCOUNT_ID)) || '}');
END@

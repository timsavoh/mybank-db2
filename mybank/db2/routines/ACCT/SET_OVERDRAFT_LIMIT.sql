-- Changes the arranged overdraft limit (the audit trigger records old -> new).
-- Called by the app (lending decisions, customer requests). The customer notification is
-- best-effort: a failure there is logged and does not undo the limit change.
-- Raises 75002/75003 account, 75006 above product maximum, 75008 negative limit,
-- 75009 product has no overdraft / new limit below current overdrawn balance.
CREATE OR REPLACE PROCEDURE ACCT.SET_OVERDRAFT_LIMIT (
    IN  P_ACCOUNT_ID BIGINT,
    IN  P_NEW_LIMIT  DECIMAL(15,2),
    IN  P_REASON     VARCHAR(100),
    OUT P_OLD_LIMIT  DECIMAL(15,2)
)
    LANGUAGE SQL
    SPECIFIC ACCT_SET_OVERDRAFT_LIMIT
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE   CHAR(5);
    DECLARE V_SQLCODE    INTEGER;
    DECLARE V_MSG        VARCHAR(1000);
    DECLARE V_STATUS     CHAR(1);
    DECLARE V_BALANCE    DECIMAL(15,2);
    DECLARE V_OD_ALLOWED CHAR(1);
    DECLARE V_DEFAULT_OD DECIMAL(15,2);
    DECLARE V_MAX_LIMIT  DECIMAL(15,2);
    DECLARE V_CUSTOMER_ID BIGINT;
    DECLARE V_NOTIFY_FAILED SMALLINT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.LOG_ERROR('ACCT.SET_OVERDRAFT_LIMIT', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'ACCOUNT_ID=' || COALESCE(RTRIM(CHAR(P_ACCOUNT_ID)), 'NULL') ||
                            ' LIMIT=' || COALESCE(VARCHAR(P_NEW_LIMIT), 'NULL'));
        RESIGNAL;
    END;

    IF P_NEW_LIMIT IS NULL OR P_NEW_LIMIT < 0 THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Overdraft limit must be zero or more';
    END IF;

    SELECT A.STATUS, A.LEDGER_BALANCE, A.OVERDRAFT_LIMIT, A.PRIMARY_CUSTOMER_ID,
           P.OVERDRAFT_ALLOWED, P.DEFAULT_OD_LIMIT
      INTO V_STATUS, V_BALANCE, P_OLD_LIMIT, V_CUSTOMER_ID, V_OD_ALLOWED, V_DEFAULT_OD
      FROM ACCT.ACCOUNT A
      JOIN REF.PRODUCT P ON P.PRODUCT_CODE = A.PRODUCT_CODE
     WHERE A.ACCOUNT_ID = P_ACCOUNT_ID
      WITH RS USE AND KEEP UPDATE LOCKS;

    IF V_STATUS IS NULL THEN
        SIGNAL SQLSTATE '75002' SET MESSAGE_TEXT = 'Account not found';
    END IF;
    IF V_STATUS IN ('C', 'F') THEN
        SIGNAL SQLSTATE '75003' SET MESSAGE_TEXT = 'Account is closed or frozen';
    END IF;
    IF P_NEW_LIMIT > 0 AND V_OD_ALLOWED <> 'Y' THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Product does not allow an overdraft';
    END IF;

    -- Credit policy: up to 10x the product default, capped at 25,000
    SET V_MAX_LIMIT = CASE WHEN V_DEFAULT_OD * 10 > 25000 THEN 25000 ELSE V_DEFAULT_OD * 10 END;
    IF P_NEW_LIMIT > V_MAX_LIMIT THEN
        SIGNAL SQLSTATE '75006' SET MESSAGE_TEXT = 'Requested limit exceeds the product maximum';
    END IF;
    IF V_BALANCE < 0 AND -V_BALANCE > P_NEW_LIMIT THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'New limit is below the current overdrawn balance';
    END IF;

    IF P_NEW_LIMIT = P_OLD_LIMIT THEN
        RETURN;
    END IF;

    UPDATE ACCT.ACCOUNT
       SET OVERDRAFT_LIMIT = P_NEW_LIMIT
     WHERE ACCOUNT_ID = P_ACCOUNT_ID;

    IF P_REASON IS NOT NULL THEN
        CALL UTIL.WRITE_AUDIT('ACCT.ACCOUNT', RTRIM(CHAR(P_ACCOUNT_ID)), 'U',
                              'Overdraft limit change reason: ' || P_REASON);
    END IF;

    -- Best effort: the limit change stands even if the notification can't be queued
    NOTIFY: BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
            VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
            SET V_NOTIFY_FAILED = 1;
        END;

        CALL UTIL.ENQUEUE_NOTIFICATION(V_CUSTOMER_ID, 'OVERDRAFT_CHANGED',
                                       '{"accountId":' || RTRIM(CHAR(P_ACCOUNT_ID)) ||
                                       ',"oldLimit":' || VARCHAR(P_OLD_LIMIT) ||
                                       ',"newLimit":' || VARCHAR(P_NEW_LIMIT) || '}');
    END NOTIFY;

    IF V_NOTIFY_FAILED = 1 THEN
        CALL UTIL.LOG_ERROR('ACCT.SET_OVERDRAFT_LIMIT', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'Notification not queued for ACCOUNT_ID=' || RTRIM(CHAR(P_ACCOUNT_ID)));
    END IF;
END@

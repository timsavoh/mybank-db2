-- Analyst decision on a fraud alert. P_OUTCOME 'GENUINE' or 'FRAUD'.
--   GENUINE: held payments on the account since the alert are released to the payment queue.
--   FRAUD:   held payments rejected and their holds released, account frozen; card alerts
--            block the card instead of freezing the account.
-- Called by the app (ops console). Raises 75008 bad outcome / alert not found, 75009 closed.
CREATE OR REPLACE PROCEDURE RISK.RESOLVE_ALERT (
    IN  P_ALERT_ID       BIGINT,
    IN  P_OUTCOME        VARCHAR(7),
    IN  P_NOTES          VARCHAR(150),
    OUT P_PAYMENTS_ACTED INTEGER
)
    LANGUAGE SQL
    SPECIFIC RISK_RESOLVE_ALERT
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE   CHAR(5);
    DECLARE V_SQLCODE    INTEGER;
    DECLARE V_MSG        VARCHAR(1000);
    DECLARE V_OUTCOME    VARCHAR(7);
    DECLARE V_STATUS     CHAR(1);
    DECLARE V_ACCOUNT_ID BIGINT;
    DECLARE V_CARD_ID    BIGINT;
    DECLARE V_ALERT_DATE DATE;
    DECLARE V_ACCT_STATUS CHAR(1);
    DECLARE V_CUSTOMER_ID BIGINT;
    DECLARE V_REASON     VARCHAR(60);
    DECLARE V_ROWS       INTEGER DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.LOG_ERROR('RISK.RESOLVE_ALERT', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'ALERT_ID=' || COALESCE(RTRIM(CHAR(P_ALERT_ID)), 'NULL') ||
                            ' OUTCOME=' || COALESCE(P_OUTCOME, 'NULL'));
        RESIGNAL;
    END;

    SET P_PAYMENTS_ACTED = 0;
    SET V_OUTCOME = UPPER(RTRIM(P_OUTCOME));

    IF V_OUTCOME IS NULL OR V_OUTCOME NOT IN ('GENUINE', 'FRAUD') THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Outcome must be GENUINE or FRAUD';
    END IF;

    SELECT STATUS, ACCOUNT_ID, CARD_ID, BUSINESS_DATE
      INTO V_STATUS, V_ACCOUNT_ID, V_CARD_ID, V_ALERT_DATE
      FROM RISK.FRAUD_ALERT
     WHERE ALERT_ID = P_ALERT_ID
      WITH RS USE AND KEEP UPDATE LOCKS;

    IF V_STATUS IS NULL THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Alert not found';
    END IF;
    IF V_STATUS <> 'O' THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Alert is already resolved';
    END IF;

    SELECT STATUS, PRIMARY_CUSTOMER_ID INTO V_ACCT_STATUS, V_CUSTOMER_ID
      FROM ACCT.ACCOUNT
     WHERE ACCOUNT_ID = V_ACCOUNT_ID;

    IF V_OUTCOME = 'GENUINE' THEN
        -- Queue the held payments for the intraday payment processor. The funds hold
        -- (SOURCE_REF 'PAY:<id>') stays until the queue posts and settles it.
        FOR R AS C_HELD CURSOR FOR
            SELECT PAYMENT_ID, DIRECTION, SCHEME, AMOUNT, REFERENCE, COUNTERPARTY_NAME
              FROM PAY.PAYMENT
             WHERE ACCOUNT_ID = V_ACCOUNT_ID
               AND STATUS = 'H'
               AND BUSINESS_DATE >= V_ALERT_DATE
               FOR UPDATE OF STATUS
        DO
            UPDATE PAY.PAYMENT
               SET STATUS = 'P'
             WHERE CURRENT OF C_HELD;

            INSERT INTO TXN.PENDING_TXN
                (ACCOUNT_ID, TXN_TYPE, AMOUNT, DESCRIPTION, REFERENCE, SOURCE_TABLE, SOURCE_ID, VALUE_DATE)
            VALUES
                (V_ACCOUNT_ID,
                 CASE WHEN R.DIRECTION = 'I' THEN 'FPI' ELSE 'FPO' END,
                 CASE WHEN R.DIRECTION = 'I' THEN R.AMOUNT ELSE -R.AMOUNT END,
                 CASE WHEN R.DIRECTION = 'I' THEN 'From ' ELSE 'To ' END || R.COUNTERPARTY_NAME,
                 R.REFERENCE, 'PAY.PAYMENT', R.PAYMENT_ID, UTIL.POSTING_DATE());

            SET P_PAYMENTS_ACTED = P_PAYMENTS_ACTED + 1;
        END FOR;

    ELSE
        SET V_REASON = 'Confirmed fraud, alert ' || RTRIM(CHAR(P_ALERT_ID));

        FOR R AS C_FRAUD CURSOR FOR
            SELECT PAYMENT_ID
              FROM PAY.PAYMENT
             WHERE ACCOUNT_ID = V_ACCOUNT_ID
               AND STATUS = 'H'
               AND BUSINESS_DATE >= V_ALERT_DATE
               FOR UPDATE OF STATUS, FAIL_REASON, COMPLETED_TS
        DO
            UPDATE PAY.PAYMENT
               SET STATUS = 'R',
                   FAIL_REASON = 'Rejected: ' || V_REASON,
                   COMPLETED_TS = CURRENT TIMESTAMP
             WHERE CURRENT OF C_FRAUD;

            UPDATE ACCT.ACCOUNT_HOLD
               SET STATUS = 'R',
                   RELEASED_TS = CURRENT TIMESTAMP
             WHERE ACCOUNT_ID = V_ACCOUNT_ID
               AND SOURCE_REF = 'PAY:' || RTRIM(CHAR(R.PAYMENT_ID))
               AND STATUS = 'A';

            SET P_PAYMENTS_ACTED = P_PAYMENTS_ACTED + 1;
        END FOR;

        IF V_CARD_ID IS NOT NULL THEN
            UPDATE CARD.CARD
               SET STATUS = 'B',
                   BLOCKED_REASON = 'FRAUD ALERT ' || RTRIM(CHAR(P_ALERT_ID))
             WHERE CARD_ID = V_CARD_ID
               AND STATUS = 'A';
            GET DIAGNOSTICS V_ROWS = ROW_COUNT;
        END IF;

        -- Payment fraud, or anything not confined to a card: stop the account
        IF (P_PAYMENTS_ACTED > 0 OR V_CARD_ID IS NULL) AND V_ACCT_STATUS IN ('A', 'D') THEN
            CALL ACCT.FREEZE_ACCOUNT(V_ACCOUNT_ID, 'F', V_REASON);
        END IF;

        CALL UTIL.ENQUEUE_NOTIFICATION(V_CUSTOMER_ID, 'FRAUD_CONFIRMED',
                                       '{"accountId":' || RTRIM(CHAR(V_ACCOUNT_ID)) ||
                                       ',"cardBlocked":' || CASE WHEN V_ROWS > 0 THEN 'true' ELSE 'false' END ||
                                       ',"paymentsStopped":' || RTRIM(CHAR(P_PAYMENTS_ACTED)) || '}');
    END IF;

    UPDATE RISK.FRAUD_ALERT
       SET STATUS = 'C',
           RESOLVED_TS = CURRENT TIMESTAMP,
           RESOLVED_BY = UTIL.GV_OPERATOR,
           RESOLUTION = V_OUTCOME || COALESCE(': ' || P_NOTES, '') ||
                        CASE WHEN P_PAYMENTS_ACTED > 0
                             THEN ' [' || RTRIM(CHAR(P_PAYMENTS_ACTED)) || ' payment(s)]'
                             ELSE '' END
     WHERE ALERT_ID = P_ALERT_ID;

    CALL UTIL.WRITE_AUDIT('RISK.FRAUD_ALERT', RTRIM(CHAR(P_ALERT_ID)), 'U',
                          'Resolved ' || V_OUTCOME || ' account ' || RTRIM(CHAR(V_ACCOUNT_ID)) ||
                          ' payments ' || RTRIM(CHAR(P_PAYMENTS_ACTED)) ||
                          COALESCE(' card ' || RTRIM(CHAR(V_CARD_ID)), ''));
END@

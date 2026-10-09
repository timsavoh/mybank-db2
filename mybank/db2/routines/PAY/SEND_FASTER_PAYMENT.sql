-- Outbound payment to a saved payee (P_PAYEE_ID) or ad-hoc sort code / account / name.
-- FPS posts immediately (status C); BACS (P_SCHEME 'BAC') is queued in TXN.PENDING_TXN (status P);
-- high-risk payments are held for review (status H). A repeated idempotency key returns the original.
-- Raises 75001, 75002, 75003, 75006 limits, 75008, 75009, 75011 modulus check, 75012 payee not found.
CREATE OR REPLACE PROCEDURE PAY.SEND_FASTER_PAYMENT (
    IN  P_ACCOUNT_ID      BIGINT,
    IN  P_AMOUNT          DECIMAL(15,2),
    IN  P_PAYEE_ID        BIGINT,
    IN  P_SORT_CODE       VARCHAR(8),
    IN  P_ACCOUNT_NO      CHAR(8),
    IN  P_NAME            VARCHAR(60),
    IN  P_REFERENCE       VARCHAR(18),
    IN  P_IDEMPOTENCY_KEY VARCHAR(64),
    OUT P_PAYMENT_ID      BIGINT,
    OUT P_STATUS          CHAR(1),
    IN  P_SCHEME          CHAR(3) DEFAULT 'FPS'
)
    LANGUAGE SQL
    SPECIFIC PAY_SEND_FASTER_PAYMENT
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE CHAR(5);
    DECLARE V_SQLCODE  INTEGER;
    DECLARE V_MSG      VARCHAR(1000);

    -- Limits agreed with Payments Ops, CR-2291 (2017). Not table driven.
    DECLARE V_PAYMENT_LIMIT DECIMAL(15,2) DEFAULT 25000.00;
    DECLARE V_DAILY_LIMIT   DECIMAL(15,2) DEFAULT 50000.00;

    DECLARE V_SCHEME        CHAR(3);
    DECLARE V_DATE          DATE;
    DECLARE V_CUSTOMER_ID   BIGINT;
    DECLARE V_PRODUCT_TYPE  CHAR(3);
    DECLARE V_CP_NAME       VARCHAR(60);
    DECLARE V_CP_SORT       CHAR(6);
    DECLARE V_CP_ACCT       CHAR(8);
    DECLARE V_PAYEE_CREATED DATE;
    DECLARE V_SENT_TODAY    DECIMAL(15,2);
    DECLARE V_SCORE         SMALLINT DEFAULT 0;
    DECLARE V_DETAIL        VARCHAR(500);
    DECLARE V_STATUS        CHAR(1);
    DECLARE V_DUPLICATE     SMALLINT DEFAULT 0;
    DECLARE V_TXN_ID        BIGINT;
    DECLARE V_BALANCE       DECIMAL(15,2);
    DECLARE V_ALERT_ID      BIGINT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.LOG_ERROR('PAY.SEND_FASTER_PAYMENT', V_SQLSTATE, V_SQLCODE, V_MSG,
             'ACCOUNT=' || COALESCE(RTRIM(CHAR(P_ACCOUNT_ID)), 'NULL') ||
             ' AMOUNT=' || COALESCE(VARCHAR(P_AMOUNT), 'NULL') ||
             ' PAYEE=' || COALESCE(RTRIM(CHAR(P_PAYEE_ID)), 'NULL') ||
             ' KEY=' || COALESCE(P_IDEMPOTENCY_KEY, 'NULL'));
        RESIGNAL;
    END;

    SET P_PAYMENT_ID = NULL;
    SET P_STATUS = NULL;

    -- Client retry: hand back the original payment, whatever happened to it
    IF P_IDEMPOTENCY_KEY IS NOT NULL THEN
        SELECT PAYMENT_ID, STATUS INTO P_PAYMENT_ID, P_STATUS
          FROM PAY.PAYMENT
         WHERE IDEMPOTENCY_KEY = P_IDEMPOTENCY_KEY;
        IF P_PAYMENT_ID IS NOT NULL THEN
            RETURN;
        END IF;
    END IF;

    SET V_SCHEME = COALESCE(P_SCHEME, 'FPS');

    IF P_AMOUNT IS NULL OR P_AMOUNT <= 0 THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Payment amount must be greater than zero';
    END IF;
    IF V_SCHEME = 'CHP' THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'CHAPS payments must be arranged in branch';
    END IF;
    IF V_SCHEME NOT IN ('FPS', 'BAC') THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Unknown payment scheme';
    END IF;
    IF P_AMOUNT > V_PAYMENT_LIMIT THEN
        SIGNAL SQLSTATE '75006' SET MESSAGE_TEXT = 'Payment exceeds the single payment limit of 25,000';
    END IF;

    CALL UTIL.CHECK_ACCOUNT_STATUS(P_ACCOUNT_ID, 'Y');

    -- Update lock on the account serialises the daily limit check across concurrent payments
    SELECT A.PRIMARY_CUSTOMER_ID, P.PRODUCT_TYPE
      INTO V_CUSTOMER_ID, V_PRODUCT_TYPE
      FROM ACCT.ACCOUNT A
      JOIN REF.PRODUCT P ON P.PRODUCT_CODE = A.PRODUCT_CODE
     WHERE A.ACCOUNT_ID = P_ACCOUNT_ID
      WITH RS USE AND KEEP UPDATE LOCKS;

    IF V_PRODUCT_TYPE = 'LON' THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Payments cannot be made from a loan account';
    END IF;

    IF P_PAYEE_ID IS NOT NULL THEN
        SELECT Y.NAME, Y.SORT_CODE, Y.ACCOUNT_NO, Y.CREATED_DATE
          INTO V_CP_NAME, V_CP_SORT, V_CP_ACCT, V_PAYEE_CREATED
          FROM PAY.PAYEE Y
         WHERE Y.PAYEE_ID = P_PAYEE_ID
           AND Y.ACTIVE = 'Y'
           AND (Y.CUSTOMER_ID = V_CUSTOMER_ID
                OR EXISTS (SELECT 1 FROM ACCT.ACCOUNT_HOLDER H
                            WHERE H.ACCOUNT_ID = P_ACCOUNT_ID
                              AND H.CUSTOMER_ID = Y.CUSTOMER_ID))
          WITH UR;
        IF V_CP_NAME IS NULL THEN
            SIGNAL SQLSTATE '75012' SET MESSAGE_TEXT = 'Payee not found';
        END IF;
    ELSE
        IF P_SORT_CODE IS NULL OR P_ACCOUNT_NO IS NULL OR P_NAME IS NULL THEN
            SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Payee id or sort code, account number and name required';
        END IF;
        SET V_CP_SORT = LPAD(REPLACE(REPLACE(RTRIM(LTRIM(P_SORT_CODE)), '-', ''), ' ', ''), 6, '0');
        SET V_CP_ACCT = P_ACCOUNT_NO;
        SET V_CP_NAME = UPPER(RTRIM(P_NAME));
        -- Ad-hoc payment to someone already saved still counts as a known payee
        SELECT MIN(Y.CREATED_DATE) INTO V_PAYEE_CREATED
          FROM PAY.PAYEE Y
         WHERE Y.CUSTOMER_ID = V_CUSTOMER_ID
           AND Y.SORT_CODE = V_CP_SORT
           AND Y.ACCOUNT_NO = V_CP_ACCT
           AND Y.ACTIVE = 'Y'
          WITH UR;
    END IF;

    IF UTIL.MODULUS_CHECK(V_CP_SORT, V_CP_ACCT) = 0 THEN
        SIGNAL SQLSTATE '75011' SET MESSAGE_TEXT = 'Sort code / account number failed validation';
    END IF;

    SET V_DATE = UTIL.POSTING_DATE();

    SELECT COALESCE(SUM(AMOUNT), 0) INTO V_SENT_TODAY
      FROM PAY.PAYMENT
     WHERE ACCOUNT_ID = P_ACCOUNT_ID
       AND BUSINESS_DATE = V_DATE
       AND DIRECTION = 'O'
       AND STATUS IN ('P', 'C', 'H');

    IF V_SENT_TODAY + P_AMOUNT > V_DAILY_LIMIT THEN
        SIGNAL SQLSTATE '75006' SET MESSAGE_TEXT = 'Payment exceeds the daily limit of 50,000';
    END IF;

    IF UTIL.AVAILABLE_BALANCE(P_ACCOUNT_ID) < P_AMOUNT THEN
        SIGNAL SQLSTATE '75001' SET MESSAGE_TEXT = 'Insufficient funds';
    END IF;

    -- Inline fraud screen. BATCH.RUN_FRAUD_RULES rule 4 catches the same pattern after the event.
    IF P_AMOUNT > 10000 THEN
        SET V_SCORE = 80;
        SET V_DETAIL = 'Large payment ' || VARCHAR(P_AMOUNT) || ' to ' || V_CP_SORT || '/' || V_CP_ACCT;
    ELSEIF P_AMOUNT > 2000
       AND (V_PAYEE_CREATED IS NULL OR DAYS(V_DATE) - DAYS(V_PAYEE_CREATED) <= 3) THEN
        SET V_SCORE = 70;
        SET V_DETAIL = 'New payee ' || V_CP_SORT || '/' || V_CP_ACCT || ' amount ' || VARCHAR(P_AMOUNT);
    END IF;

    SET V_STATUS = CASE WHEN V_SCORE >= 70 THEN 'H'
                        WHEN V_SCHEME = 'BAC' THEN 'P'
                        ELSE 'C' END;

    BEGIN
        -- Two concurrent requests with the same key: the loser returns the winner's payment
        DECLARE CONTINUE HANDLER FOR SQLSTATE '23505' SET V_DUPLICATE = 1;

        SELECT PAYMENT_ID INTO P_PAYMENT_ID
          FROM FINAL TABLE (INSERT INTO PAY.PAYMENT
                                (DIRECTION, SCHEME, ACCOUNT_ID, AMOUNT, COUNTERPARTY_NAME,
                                 COUNTERPARTY_SORT, COUNTERPARTY_ACCT, REFERENCE, STATUS,
                                 IDEMPOTENCY_KEY, SCHEME_REF, BUSINESS_DATE, COMPLETED_TS)
                            VALUES ('O', V_SCHEME, P_ACCOUNT_ID, P_AMOUNT, V_CP_NAME,
                                    V_CP_SORT, V_CP_ACCT, P_REFERENCE, V_STATUS,
                                    P_IDEMPOTENCY_KEY,
                                    CASE WHEN V_STATUS = 'C'
                                         THEN 'MYB' || VARCHAR_FORMAT(CURRENT TIMESTAMP, 'YYYYMMDDHH24MISSFF6')
                                    END,
                                    V_DATE,
                                    CASE WHEN V_STATUS = 'C' THEN CURRENT TIMESTAMP END));
    END;

    IF V_DUPLICATE = 1 THEN
        SELECT PAYMENT_ID, STATUS INTO P_PAYMENT_ID, P_STATUS
          FROM PAY.PAYMENT
         WHERE IDEMPOTENCY_KEY = P_IDEMPOTENCY_KEY;
        RETURN;
    END IF;

    SET P_STATUS = V_STATUS;

    IF V_STATUS = 'H' THEN
        -- Ring-fence the funds until the fraud team releases or rejects the payment
        INSERT INTO ACCT.ACCOUNT_HOLD (ACCOUNT_ID, AMOUNT, REASON, SOURCE_REF, EXPIRES_TS)
        VALUES (P_ACCOUNT_ID, P_AMOUNT, 'PAY_FRAUD_REVIEW', 'PAY:' || RTRIM(CHAR(P_PAYMENT_ID)),
                CURRENT TIMESTAMP + 7 DAYS);
        CALL UTIL.RAISE_FRAUD_ALERT(P_ACCOUNT_ID, NULL, NULL, V_SCORE,
             'Payment ' || RTRIM(CHAR(P_PAYMENT_ID)) || ' held: ' || V_DETAIL, V_ALERT_ID);
        CALL UTIL.ENQUEUE_NOTIFICATION(V_CUSTOMER_ID, 'PAYMENT_HELD',
             '{"payment":' || RTRIM(CHAR(P_PAYMENT_ID)) || ',"amount":' || VARCHAR(P_AMOUNT) || '}');
    ELSEIF V_STATUS = 'P' THEN
        -- BACS three-day cycle: debit lands two business days after submission
        INSERT INTO TXN.PENDING_TXN
            (ACCOUNT_ID, TXN_TYPE, AMOUNT, DESCRIPTION, REFERENCE, SOURCE_TABLE, SOURCE_ID, VALUE_DATE)
        VALUES (P_ACCOUNT_ID, 'FPO', -P_AMOUNT, 'BACS to ' || V_CP_NAME, P_REFERENCE,
                'PAY.PAYMENT', P_PAYMENT_ID, UTIL.NEXT_BUSINESS_DAY(UTIL.NEXT_BUSINESS_DAY(V_DATE)));
    ELSE
        CALL UTIL.POST_LEDGER_ENTRY(P_ACCOUNT_ID, -P_AMOUNT, 'FPO', 'FPS to ' || V_CP_NAME,
             P_REFERENCE, '1510', NULL, NULL, 'N', V_CP_NAME, V_CP_SORT, V_CP_ACCT, NULL, NULL,
             V_TXN_ID, V_BALANCE);
        CALL UTIL.ENQUEUE_NOTIFICATION(V_CUSTOMER_ID, 'PAYMENT_SENT',
             '{"payment":' || RTRIM(CHAR(P_PAYMENT_ID)) || ',"amount":' || VARCHAR(P_AMOUNT) ||
             ',"payee":"' || V_CP_NAME || '"}');
    END IF;
END@

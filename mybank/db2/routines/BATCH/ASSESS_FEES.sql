-- EOD: (1) over-limit fee ODOVERLM, once per business day, for accounts below -OVERDRAFT_LIMIT,
-- capped at 5 charges a calendar month; (2) product MONTHLY_FEE on the account's monthly
-- anniversary (DAY of OPENED_DATE, capped at month end; weekend anniversaries charged next business day).
CREATE OR REPLACE PROCEDURE BATCH.ASSESS_FEES (OUT P_ROWS_PROCESSED INTEGER)
    LANGUAGE SQL
    SPECIFIC BATCH_ASSESS_FEES
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE CHAR(5);
    DECLARE V_SQLCODE  INTEGER;
    DECLARE V_MSG      VARCHAR(1000);
    DECLARE V_RUN_ID   BIGINT;
    DECLARE V_ROWS     INTEGER DEFAULT 0;
    DECLARE V_OVERLIMIT INTEGER DEFAULT 0;
    DECLARE V_CAPPED    INTEGER DEFAULT 0;
    DECLARE V_MONTHLY   INTEGER DEFAULT 0;
    DECLARE V_FAILED    INTEGER DEFAULT 0;
    DECLARE V_TOTAL     DECIMAL(17,2) DEFAULT 0;
    DECLARE V_TODAY     DATE;
    DECLARE V_PREV_BDATE DATE;
    DECLARE V_MONTH_START DATE;
    DECLARE V_PREV_MONTH_START DATE;
    DECLARE V_FEE       DECIMAL(9,2);
    DECLARE V_TXN_ID    BIGINT;
    DECLARE V_BALANCE   DECIMAL(15,2);
    DECLARE V_ROW_STATE CHAR(5);
    DECLARE V_ROW_CODE  INTEGER;
    DECLARE V_ROW_MSG   VARCHAR(1000);
    -- Unarranged overdraft charges capped per month (CCA review, 2019)
    DECLARE V_OVERLIMIT_CAP INTEGER DEFAULT 5;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.END_JOB_RUN(V_RUN_ID, 'F', V_ROWS, V_MSG);
        CALL UTIL.LOG_ERROR('BATCH.ASSESS_FEES', V_SQLSTATE, V_SQLCODE, V_MSG, NULL);
        RESIGNAL;
    END;

    CALL UTIL.START_JOB_RUN('ASSESS_FEES', V_RUN_ID);

    SELECT BUSINESS_DATE, COALESCE(PREV_BUSINESS_DATE, BUSINESS_DATE - 1 DAY)
      INTO V_TODAY, V_PREV_BDATE
      FROM REF.BANK_CONTROL
     WHERE CONTROL_ID = 1;

    SET V_MONTH_START = V_TODAY - (DAY(V_TODAY) - 1) DAYS;
    SET V_PREV_MONTH_START = ADD_MONTHS(V_MONTH_START, -1);

    ------------------------------------------------------------------
    -- 1. Over-limit handling fee
    ------------------------------------------------------------------
    OL_LOOP:
    FOR OL AS C_OVERLIMIT CURSOR WITH HOLD FOR
        WITH CHARGED_MTD (ACCOUNT_ID, LAST_CHARGED, RN, CHARGES_MTD) AS (
            SELECT T.ACCOUNT_ID,
                   T.BUSINESS_DATE,
                   ROW_NUMBER() OVER (PARTITION BY T.ACCOUNT_ID ORDER BY T.BUSINESS_DATE DESC, T.TXN_ID DESC),
                   COUNT(*) OVER (PARTITION BY T.ACCOUNT_ID)
              FROM TXN.POSTED_TXN T
             WHERE T.BUSINESS_DATE BETWEEN V_MONTH_START AND V_TODAY
               AND T.TXN_TYPE = 'FEE'
               AND T.REFERENCE = 'ODOVERLM'
        )
        SELECT A.ACCOUNT_ID, A.PRIMARY_CUSTOMER_ID, A.LEDGER_BALANCE, A.OVERDRAFT_LIMIT,
               COALESCE(C.CHARGES_MTD, 0) AS CHARGES_MTD, C.LAST_CHARGED
          FROM ACCT.ACCOUNT A
          JOIN REF.PRODUCT P
            ON P.PRODUCT_CODE = A.PRODUCT_CODE
          LEFT OUTER JOIN CHARGED_MTD C
            ON C.ACCOUNT_ID = A.ACCOUNT_ID
           AND C.RN = 1
         WHERE A.STATUS IN ('A', 'D')
           AND P.PRODUCT_TYPE <> 'LON'
           AND A.LEDGER_BALANCE < -A.OVERDRAFT_LIMIT
         ORDER BY A.ACCOUNT_ID
    DO
        IF COALESCE(OL.LAST_CHARGED, V_MONTH_START - 1 DAY) >= V_TODAY THEN
            -- already charged today (re-run): nothing to do
            ITERATE OL_LOOP;
        ELSEIF OL.CHARGES_MTD >= V_OVERLIMIT_CAP THEN
            SET V_CAPPED = V_CAPPED + 1;
        ELSE
            SET V_FEE = UTIL.CALC_FEE('ODOVERLM', -(OL.LEDGER_BALANCE + OL.OVERDRAFT_LIMIT));
            SET V_ROW_STATE = '00000';
            SAVEPOINT SP_FEE ON ROLLBACK RETAIN CURSORS;
            OL_BLOCK:
            BEGIN
                DECLARE EXIT HANDLER FOR SQLEXCEPTION
                BEGIN
                    GET DIAGNOSTICS EXCEPTION 1 V_ROW_MSG = MESSAGE_TEXT;
                    VALUES (SQLSTATE, SQLCODE) INTO V_ROW_STATE, V_ROW_CODE;
                END;
                IF V_FEE > 0 THEN
                    CALL UTIL.POST_LEDGER_ENTRY(OL.ACCOUNT_ID, -V_FEE, 'FEE', 'Over-limit handling fee',
                                                'ODOVERLM', '4100', NULL, V_TODAY, 'Y',
                                                NULL, NULL, NULL, NULL, NULL, V_TXN_ID, V_BALANCE);
                    CALL UTIL.ENQUEUE_NOTIFICATION(OL.PRIMARY_CUSTOMER_ID, 'OVERLIMIT_FEE',
                         '{"account":' || RTRIM(CHAR(OL.ACCOUNT_ID)) || ',"balance":' || VARCHAR(OL.LEDGER_BALANCE)
                         || ',"limit":' || VARCHAR(OL.OVERDRAFT_LIMIT) || ',"fee":' || VARCHAR(V_FEE) || '}');
                END IF;
            END OL_BLOCK;
            IF V_ROW_STATE = '00000' THEN
                RELEASE SAVEPOINT SP_FEE;
                SET V_OVERLIMIT = V_OVERLIMIT + 1;
                SET V_TOTAL = V_TOTAL + V_FEE;
            ELSE
                ROLLBACK TO SAVEPOINT SP_FEE;
                CALL UTIL.LOG_ERROR('BATCH.ASSESS_FEES', V_ROW_STATE, V_ROW_CODE, V_ROW_MSG,
                                    'ODOVERLM ACCOUNT_ID=' || RTRIM(CHAR(OL.ACCOUNT_ID)));
                SET V_FAILED = V_FAILED + 1;
            END IF;
            IF MOD(V_OVERLIMIT + V_FAILED, 500) = 0 THEN
                COMMIT;
            END IF;
        END IF;
    END FOR OL_LOOP;
    COMMIT;

    ------------------------------------------------------------------
    -- 2. Monthly account fee. Anniversaries of this month and last month are both
    --    considered so that one falling on a weekend/holiday (or on the 31st of a
    --    short month) is picked up on the next business day.
    ------------------------------------------------------------------
    FOR MF AS C_MONTHLY CURSOR WITH HOLD FOR
        SELECT X.ACCOUNT_ID, X.MONTHLY_FEE, X.FEE_CODE, X.ANNIV_DATE
          FROM (SELECT A.ACCOUNT_ID,
                       A.OPENED_DATE,
                       P.MONTHLY_FEE,
                       COALESCE(F.FEE_CODE, 'MONTHFEE') AS FEE_CODE,
                       M.MONTH_START + (MIN(DAY(A.OPENED_DATE), DAY(LAST_DAY(M.MONTH_START))) - 1) DAYS AS ANNIV_DATE
                  FROM ACCT.ACCOUNT A
                  JOIN REF.PRODUCT P
                    ON P.PRODUCT_CODE = A.PRODUCT_CODE
                  LEFT OUTER JOIN REF.FEE_SCHEDULE F
                    ON F.PRODUCT_CODE = A.PRODUCT_CODE
                   AND F.FEE_CODE LIKE 'MFEE%',
                       (VALUES V_PREV_MONTH_START, V_MONTH_START) AS M (MONTH_START)
                 WHERE A.STATUS IN ('A', 'D')
                   AND P.MONTHLY_FEE > 0) X
         WHERE X.ANNIV_DATE > V_PREV_BDATE
           AND X.ANNIV_DATE <= V_TODAY
           AND X.ANNIV_DATE > X.OPENED_DATE
           AND NOT EXISTS (SELECT 1
                             FROM TXN.POSTED_TXN T
                            WHERE T.ACCOUNT_ID = X.ACCOUNT_ID
                              AND T.BUSINESS_DATE >= X.ANNIV_DATE
                              AND T.TXN_TYPE = 'FEE'
                              AND T.REFERENCE = X.FEE_CODE)
         ORDER BY X.ACCOUNT_ID
    DO
        SET V_ROW_STATE = '00000';
        SAVEPOINT SP_FEE ON ROLLBACK RETAIN CURSORS;
        MF_BLOCK:
        BEGIN
            DECLARE EXIT HANDLER FOR SQLEXCEPTION
            BEGIN
                GET DIAGNOSTICS EXCEPTION 1 V_ROW_MSG = MESSAGE_TEXT;
                VALUES (SQLSTATE, SQLCODE) INTO V_ROW_STATE, V_ROW_CODE;
            END;
            CALL UTIL.POST_LEDGER_ENTRY(MF.ACCOUNT_ID, -MF.MONTHLY_FEE, 'FEE',
                                        'Monthly account fee ' || VARCHAR_FORMAT(MF.ANNIV_DATE, 'Mon YYYY'),
                                        MF.FEE_CODE, '4100', NULL, V_TODAY, 'Y',
                                        NULL, NULL, NULL, NULL, NULL, V_TXN_ID, V_BALANCE);
        END MF_BLOCK;
        IF V_ROW_STATE = '00000' THEN
            RELEASE SAVEPOINT SP_FEE;
            SET V_MONTHLY = V_MONTHLY + 1;
            SET V_TOTAL = V_TOTAL + MF.MONTHLY_FEE;
        ELSE
            ROLLBACK TO SAVEPOINT SP_FEE;
            CALL UTIL.LOG_ERROR('BATCH.ASSESS_FEES', V_ROW_STATE, V_ROW_CODE, V_ROW_MSG,
                                'MONTHLY ACCOUNT_ID=' || RTRIM(CHAR(MF.ACCOUNT_ID)));
            SET V_FAILED = V_FAILED + 1;
        END IF;
        IF MOD(V_MONTHLY, 500) = 0 THEN
            COMMIT;
        END IF;
    END FOR;
    COMMIT;

    SET V_ROWS = V_OVERLIMIT + V_MONTHLY;
    SET P_ROWS_PROCESSED = V_ROWS;
    CALL UTIL.END_JOB_RUN(V_RUN_ID, 'S', V_ROWS,
         RTRIM(CHAR(V_OVERLIMIT)) || ' over-limit fees (' || RTRIM(CHAR(V_CAPPED)) || ' capped), '
         || RTRIM(CHAR(V_MONTHLY)) || ' monthly fees, total ' || VARCHAR(V_TOTAL) || ', '
         || RTRIM(CHAR(V_FAILED)) || ' failed');
END@

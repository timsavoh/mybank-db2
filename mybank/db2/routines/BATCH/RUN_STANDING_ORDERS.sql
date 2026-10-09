-- EOD: pays standing orders due on or before today (SO debit, contra 1510). Unpaid for lack of
-- funds: UNPAIDSO fee + customer notification; suspended ('S') after 3 consecutive failures.
-- Next due date moves on by frequency and rolls forward off weekends/holidays. Re-run safe.
CREATE OR REPLACE PROCEDURE BATCH.RUN_STANDING_ORDERS (OUT P_ROWS_PROCESSED INTEGER)
    LANGUAGE SQL
    SPECIFIC BATCH_RUN_STANDING_ORDERS
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE CHAR(5);
    DECLARE V_SQLCODE  INTEGER;
    DECLARE V_MSG      VARCHAR(1000);
    DECLARE V_RUN_ID   BIGINT;
    DECLARE V_ROWS     INTEGER DEFAULT 0;
    DECLARE V_PAID     INTEGER DEFAULT 0;
    DECLARE V_UNPAID   INTEGER DEFAULT 0;
    DECLARE V_OTHER    INTEGER DEFAULT 0;
    DECLARE V_ENDED    INTEGER DEFAULT 0;
    DECLARE V_EOF      SMALLINT DEFAULT 0;
    DECLARE V_TODAY    DATE;
    DECLARE V_MAX_FAILS SMALLINT DEFAULT 3;

    DECLARE V_SO_ID        BIGINT;
    DECLARE V_ACCOUNT_ID   BIGINT;
    DECLARE V_AMOUNT       DECIMAL(15,2);
    DECLARE V_FREQUENCY    CHAR(1);
    DECLARE V_DUE          DATE;
    DECLARE V_END_DATE     DATE;
    DECLARE V_FAIL_COUNT   SMALLINT;
    DECLARE V_PAYEE_NAME   VARCHAR(60);
    DECLARE V_PAYEE_SORT   CHAR(6);
    DECLARE V_PAYEE_ACCT   CHAR(8);
    DECLARE V_PAYEE_REF    VARCHAR(18);
    DECLARE V_CUSTOMER_ID  BIGINT;
    DECLARE V_ACCT_STATUS  CHAR(1);
    DECLARE V_NOMINAL      DATE;
    DECLARE V_NEXT         DATE;
    DECLARE V_NEW_STATUS   CHAR(1);
    DECLARE V_FEE          DECIMAL(9,2);
    DECLARE V_TXN_ID       BIGINT;
    DECLARE V_BALANCE      DECIMAL(15,2);
    DECLARE V_ROW_STATE    CHAR(5);
    DECLARE V_ROW_CODE     INTEGER;
    DECLARE V_ROW_MSG      VARCHAR(1000);

    DECLARE C_DUE CURSOR WITH HOLD FOR
        SELECT S.SO_ID, S.ACCOUNT_ID, S.AMOUNT, S.FREQUENCY, S.NEXT_DUE_DATE, S.END_DATE, S.FAIL_COUNT,
               Y.NAME, Y.SORT_CODE, Y.ACCOUNT_NO, Y.REFERENCE,
               A.PRIMARY_CUSTOMER_ID, A.STATUS
          FROM PAY.STANDING_ORDER S
          JOIN PAY.PAYEE Y
            ON Y.PAYEE_ID = S.PAYEE_ID
          JOIN ACCT.ACCOUNT A
            ON A.ACCOUNT_ID = S.ACCOUNT_ID
         WHERE S.STATUS = 'A'
           AND S.NEXT_DUE_DATE <= V_TODAY
         ORDER BY S.ACCOUNT_ID, S.SO_ID
          WITH CS;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET V_EOF = 1;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.END_JOB_RUN(V_RUN_ID, 'F', V_ROWS, V_MSG);
        CALL UTIL.LOG_ERROR('BATCH.RUN_STANDING_ORDERS', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'SO_ID=' || COALESCE(RTRIM(CHAR(V_SO_ID)), '-'));
        RESIGNAL;
    END;

    CALL UTIL.START_JOB_RUN('RUN_STANDING_ORDERS', V_RUN_ID);
    SET V_TODAY = UTIL.CURRENT_BUSINESS_DATE();

    OPEN C_DUE;
    SO_LOOP:
    LOOP
        SET V_EOF = 0;
        FETCH C_DUE INTO V_SO_ID, V_ACCOUNT_ID, V_AMOUNT, V_FREQUENCY, V_DUE, V_END_DATE, V_FAIL_COUNT,
                         V_PAYEE_NAME, V_PAYEE_SORT, V_PAYEE_ACCT, V_PAYEE_REF,
                         V_CUSTOMER_ID, V_ACCT_STATUS;
        IF V_EOF = 1 THEN
            LEAVE SO_LOOP;
        END IF;
        SET V_ROWS = V_ROWS + 1;

        IF V_END_DATE IS NOT NULL AND V_DUE > V_END_DATE THEN
            UPDATE PAY.STANDING_ORDER SET STATUS = 'E' WHERE SO_ID = V_SO_ID AND STATUS = 'A';
            SET V_ENDED = V_ENDED + 1;
            ITERATE SO_LOOP;
        END IF;

        SET V_ROW_STATE = '00000';
        SET V_NEW_STATUS = 'A';
        SAVEPOINT SP_SO ON ROLLBACK RETAIN CURSORS;

        PAY_BLOCK:
        BEGIN
            DECLARE EXIT HANDLER FOR SQLEXCEPTION
            BEGIN
                GET DIAGNOSTICS EXCEPTION 1 V_ROW_MSG = MESSAGE_TEXT;
                VALUES (SQLSTATE, SQLCODE) INTO V_ROW_STATE, V_ROW_CODE;
            END;

            CALL UTIL.POST_LEDGER_ENTRY(V_ACCOUNT_ID, -V_AMOUNT, 'SO', 'SO ' || V_PAYEE_NAME,
                                        COALESCE(V_PAYEE_REF, 'SO' || RTRIM(CHAR(V_SO_ID))),
                                        '1510', NULL, V_TODAY, 'N',
                                        V_PAYEE_NAME, V_PAYEE_SORT, V_PAYEE_ACCT, NULL, NULL,
                                        V_TXN_ID, V_BALANCE);
        END PAY_BLOCK;

        IF V_ROW_STATE = '00000' THEN
            RELEASE SAVEPOINT SP_SO;
            SET V_FAIL_COUNT = 0;
            SET V_PAID = V_PAID + 1;
        ELSE
            ROLLBACK TO SAVEPOINT SP_SO;
            SET V_FAIL_COUNT = V_FAIL_COUNT + 1;
            IF V_FAIL_COUNT >= V_MAX_FAILS THEN
                SET V_NEW_STATUS = 'S';
            END IF;

            IF V_ROW_STATE = '75001' THEN
                SET V_FEE = UTIL.CALC_FEE('UNPAIDSO', V_AMOUNT);
                IF V_FEE > 0 THEN
                    CALL UTIL.POST_LEDGER_ENTRY(V_ACCOUNT_ID, -V_FEE, 'FEE', 'Unpaid standing order fee',
                                                'UNPAIDSO', '4100', NULL, V_TODAY, 'Y',
                                                NULL, NULL, NULL, NULL, NULL,
                                                V_TXN_ID, V_BALANCE);
                END IF;
                CALL UTIL.ENQUEUE_NOTIFICATION(V_CUSTOMER_ID, 'SO_UNPAID',
                     '{"standingOrder":' || RTRIM(CHAR(V_SO_ID)) || ',"amount":' || VARCHAR(V_AMOUNT)
                     || ',"payee":"' || REPLACE(V_PAYEE_NAME, '"', '') || '","fee":' || VARCHAR(V_FEE)
                     || ',"suspended":' || CASE V_NEW_STATUS WHEN 'S' THEN 'true' ELSE 'false' END || '}');
                SET V_UNPAID = V_UNPAID + 1;
            ELSEIF V_ROW_STATE = '75003' AND V_ACCT_STATUS = 'C' THEN
                -- Paying account closed: the order dies with it
                SET V_NEW_STATUS = 'C';
                SET V_OTHER = V_OTHER + 1;
            ELSE
                CALL UTIL.LOG_ERROR('BATCH.RUN_STANDING_ORDERS', V_ROW_STATE, V_ROW_CODE, V_ROW_MSG,
                                    'SO_ID=' || RTRIM(CHAR(V_SO_ID)));
                SET V_OTHER = V_OTHER + 1;
            END IF;
        END IF;

        -- Move on a period (skipping any missed ones) from the stored due date, then roll forward.
        -- NB the stored date is the rolled one, so a weekend roll sticks (known since 2014).
        SET V_NOMINAL = V_DUE;
        REPEAT
            SET V_NOMINAL = CASE V_FREQUENCY
                                WHEN 'W' THEN V_NOMINAL + 7 DAYS
                                WHEN 'M' THEN ADD_MONTHS(V_NOMINAL, 1)
                                WHEN 'Q' THEN ADD_MONTHS(V_NOMINAL, 3)
                                ELSE ADD_MONTHS(V_NOMINAL, 12)
                            END;
            SET V_NEXT = UTIL.NEXT_BUSINESS_DAY(V_NOMINAL - 1 DAY);
        UNTIL V_NEXT > V_TODAY
        END REPEAT;

        IF V_NEW_STATUS = 'A' AND V_END_DATE IS NOT NULL AND V_NEXT > V_END_DATE THEN
            SET V_NEW_STATUS = 'E';
            SET V_ENDED = V_ENDED + 1;
        END IF;

        UPDATE PAY.STANDING_ORDER
           SET NEXT_DUE_DATE = V_NEXT,
               LAST_RUN_DATE = V_TODAY,
               FAIL_COUNT    = V_FAIL_COUNT,
               STATUS        = V_NEW_STATUS
         WHERE SO_ID = V_SO_ID
           AND STATUS = 'A';

        IF MOD(V_ROWS, 200) = 0 THEN
            COMMIT;
        END IF;
    END LOOP SO_LOOP;
    CLOSE C_DUE;

    COMMIT;

    SET P_ROWS_PROCESSED = V_ROWS;
    CALL UTIL.END_JOB_RUN(V_RUN_ID, 'S', V_ROWS,
         RTRIM(CHAR(V_PAID)) || ' paid, ' || RTRIM(CHAR(V_UNPAID)) || ' unpaid, '
         || RTRIM(CHAR(V_OTHER)) || ' other failures, ' || RTRIM(CHAR(V_ENDED)) || ' ended');
END@

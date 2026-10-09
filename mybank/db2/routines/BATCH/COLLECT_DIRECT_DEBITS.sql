-- EOD: collects direct debits due on or before today (DD debit, contra 1530) and records a
-- PAY.DD_COLLECTION row. Unpaid (75001): status 'U', UNPAIDDD fee, notification. Paying account
-- closed: mandate cancelled (ADDACS). Next date = next COLLECTION_DAY, rolled to a business day.
CREATE OR REPLACE PROCEDURE BATCH.COLLECT_DIRECT_DEBITS (OUT P_ROWS_PROCESSED INTEGER)
    LANGUAGE SQL
    SPECIFIC BATCH_COLLECT_DIRECT_DEBITS
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
    DECLARE V_EOF      SMALLINT DEFAULT 0;
    DECLARE V_TODAY    DATE;

    DECLARE V_MANDATE_ID   BIGINT;
    DECLARE V_ACCOUNT_ID   BIGINT;
    DECLARE V_ORIG_NAME    VARCHAR(60);
    DECLARE V_MANDATE_REF  VARCHAR(18);
    DECLARE V_AMOUNT       DECIMAL(15,2);
    DECLARE V_COLL_DAY     SMALLINT;
    DECLARE V_DUE          DATE;
    DECLARE V_CUSTOMER_ID  BIGINT;
    DECLARE V_ACCT_STATUS  CHAR(1);
    DECLARE V_NOMINAL      DATE;
    DECLARE V_CANDIDATE    DATE;
    DECLARE V_NEXT         DATE;
    DECLARE V_RETURN       VARCHAR(40);
    DECLARE V_FEE          DECIMAL(9,2);
    DECLARE V_TXN_ID       BIGINT;
    DECLARE V_FEE_TXN_ID   BIGINT;
    DECLARE V_BALANCE      DECIMAL(15,2);
    DECLARE V_ROW_STATE    CHAR(5);
    DECLARE V_ROW_CODE     INTEGER;
    DECLARE V_ROW_MSG      VARCHAR(1000);

    DECLARE C_DUE CURSOR WITH HOLD FOR
        SELECT M.MANDATE_ID, M.ACCOUNT_ID, M.ORIGINATOR_NAME, M.MANDATE_REF, M.REGULAR_AMOUNT,
               M.COLLECTION_DAY, M.NEXT_COLLECTION_DATE, A.PRIMARY_CUSTOMER_ID, A.STATUS
          FROM PAY.DD_MANDATE M
          JOIN ACCT.ACCOUNT A
            ON A.ACCOUNT_ID = M.ACCOUNT_ID
         WHERE M.STATUS = 'A'
           AND M.NEXT_COLLECTION_DATE <= V_TODAY
         ORDER BY M.ACCOUNT_ID, M.MANDATE_ID
          WITH CS;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET V_EOF = 1;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.END_JOB_RUN(V_RUN_ID, 'F', V_ROWS, V_MSG);
        CALL UTIL.LOG_ERROR('BATCH.COLLECT_DIRECT_DEBITS', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'MANDATE_ID=' || COALESCE(RTRIM(CHAR(V_MANDATE_ID)), '-'));
        RESIGNAL;
    END;

    CALL UTIL.START_JOB_RUN('COLLECT_DIRECT_DEBITS', V_RUN_ID);
    SET V_TODAY = UTIL.CURRENT_BUSINESS_DATE();

    OPEN C_DUE;
    DD_LOOP:
    LOOP
        SET V_EOF = 0;
        FETCH C_DUE INTO V_MANDATE_ID, V_ACCOUNT_ID, V_ORIG_NAME, V_MANDATE_REF, V_AMOUNT,
                         V_COLL_DAY, V_DUE, V_CUSTOMER_ID, V_ACCT_STATUS;
        IF V_EOF = 1 THEN
            LEAVE DD_LOOP;
        END IF;
        SET V_ROWS = V_ROWS + 1;

        SET V_ROW_STATE = '00000';
        SET V_TXN_ID = NULL;
        SET V_RETURN = NULL;
        SAVEPOINT SP_DD ON ROLLBACK RETAIN CURSORS;

        COLLECT_BLOCK:
        BEGIN
            DECLARE EXIT HANDLER FOR SQLEXCEPTION
            BEGIN
                GET DIAGNOSTICS EXCEPTION 1 V_ROW_MSG = MESSAGE_TEXT;
                VALUES (SQLSTATE, SQLCODE) INTO V_ROW_STATE, V_ROW_CODE;
            END;

            CALL UTIL.POST_LEDGER_ENTRY(V_ACCOUNT_ID, -V_AMOUNT, 'DD', 'DD ' || V_ORIG_NAME,
                                        V_MANDATE_REF, '1530', NULL, V_TODAY, 'N',
                                        V_ORIG_NAME, NULL, NULL, NULL, NULL,
                                        V_TXN_ID, V_BALANCE);
        END COLLECT_BLOCK;

        IF V_ROW_STATE = '00000' THEN
            RELEASE SAVEPOINT SP_DD;
            SET V_PAID = V_PAID + 1;
        ELSE
            ROLLBACK TO SAVEPOINT SP_DD;
            SET V_TXN_ID = NULL;
            SET V_UNPAID = V_UNPAID + 1;

            IF V_ROW_STATE = '75001' THEN
                SET V_RETURN = 'REFER TO PAYER';
                SET V_FEE = UTIL.CALC_FEE('UNPAIDDD', V_AMOUNT);
                IF V_FEE > 0 THEN
                    CALL UTIL.POST_LEDGER_ENTRY(V_ACCOUNT_ID, -V_FEE, 'FEE', 'Unpaid direct debit fee',
                                                'UNPAIDDD', '4100', NULL, V_TODAY, 'Y',
                                                NULL, NULL, NULL, NULL, NULL,
                                                V_FEE_TXN_ID, V_BALANCE);
                END IF;
                CALL UTIL.ENQUEUE_NOTIFICATION(V_CUSTOMER_ID, 'DD_UNPAID',
                     '{"mandate":"' || RTRIM(V_MANDATE_REF) || '","originator":"' || REPLACE(V_ORIG_NAME, '"', '')
                     || '","amount":' || VARCHAR(V_AMOUNT) || ',"fee":' || VARCHAR(V_FEE) || '}');
            ELSEIF V_ROW_STATE = '75003' AND V_ACCT_STATUS = 'C' THEN
                SET V_RETURN = 'ACCOUNT CLOSED';
                UPDATE PAY.DD_MANDATE
                   SET STATUS = 'C',
                       CANCELLED_DATE = V_TODAY
                 WHERE MANDATE_ID = V_MANDATE_ID;
            ELSEIF V_ROW_STATE = '75003' THEN
                SET V_RETURN = 'ACCOUNT NOT AVAILABLE';
            ELSE
                SET V_RETURN = 'PROCESSING ERROR';
                CALL UTIL.LOG_ERROR('BATCH.COLLECT_DIRECT_DEBITS', V_ROW_STATE, V_ROW_CODE, V_ROW_MSG,
                                    'MANDATE_ID=' || RTRIM(CHAR(V_MANDATE_ID)));
            END IF;
        END IF;

        INSERT INTO PAY.DD_COLLECTION (MANDATE_ID, AMOUNT, DUE_DATE, STATUS, PROCESSED_DATE, TXN_ID, RETURN_REASON)
        VALUES (V_MANDATE_ID, V_AMOUNT, V_DUE, CASE WHEN V_TXN_ID IS NULL THEN 'U' ELSE 'C' END,
                V_TODAY, V_TXN_ID, V_RETURN);

        -- Next collection: the mandate's collection day in the following month (anchored on
        -- COLLECTION_DAY so weekend roll-forwards do not drift), rolled to a business day.
        SET V_NOMINAL = V_DUE;
        REPEAT
            SET V_CANDIDATE = DATE(VARCHAR_FORMAT(V_NOMINAL, 'YYYY-MM-') || LPAD(RTRIM(CHAR(V_COLL_DAY)), 2, '0'));
            IF V_CANDIDATE <= V_NOMINAL THEN
                SET V_CANDIDATE = ADD_MONTHS(V_CANDIDATE, 1);
            END IF;
            SET V_NOMINAL = V_CANDIDATE;
            SET V_NEXT = UTIL.NEXT_BUSINESS_DAY(V_NOMINAL - 1 DAY);
        UNTIL V_NEXT > V_TODAY
        END REPEAT;

        UPDATE PAY.DD_MANDATE
           SET NEXT_COLLECTION_DATE = V_NEXT
         WHERE MANDATE_ID = V_MANDATE_ID;

        IF MOD(V_ROWS, 200) = 0 THEN
            COMMIT;
        END IF;
    END LOOP DD_LOOP;
    CLOSE C_DUE;

    COMMIT;

    SET P_ROWS_PROCESSED = V_ROWS;
    CALL UTIL.END_JOB_RUN(V_RUN_ID, 'S', V_ROWS,
         RTRIM(CHAR(V_PAID)) || ' collected, ' || RTRIM(CHAR(V_UNPAID)) || ' returned unpaid');
END@

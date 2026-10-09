-- Intraday (every minute): posts queued TXN.PENDING_TXN rows (STATUS 'P') whose VALUE_DATE has
-- arrived, via UTIL.POST_LEDGER_ENTRY at the online posting date. One bad row (e.g. 75001) marks
-- that row 'F' - and rejects its PAY.PAYMENT, releasing the 'PAY:<payment id>' hold - then carries on.
CREATE OR REPLACE PROCEDURE BATCH.PROCESS_PAYMENT_QUEUE (OUT P_ROWS_PROCESSED INTEGER)
    LANGUAGE SQL
    SPECIFIC BATCH_PROCESS_PAYMENT_QUEUE
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE CHAR(5);
    DECLARE V_SQLCODE  INTEGER;
    DECLARE V_MSG      VARCHAR(1000);
    DECLARE V_RUN_ID   BIGINT;
    DECLARE V_ROWS     INTEGER DEFAULT 0;
    DECLARE V_POSTED   INTEGER DEFAULT 0;
    DECLARE V_FAILED   INTEGER DEFAULT 0;
    DECLARE V_EOF      SMALLINT DEFAULT 0;
    DECLARE V_COUNT    INTEGER;
    DECLARE V_POSTING_DATE DATE;
    DECLARE V_COMMIT_EVERY INTEGER DEFAULT 100;

    -- Current row
    DECLARE V_PENDING_ID   BIGINT;
    DECLARE V_ACCOUNT_ID   BIGINT;
    DECLARE V_TXN_TYPE     CHAR(4);
    DECLARE V_AMOUNT       DECIMAL(15,2);
    DECLARE V_DESCRIPTION  VARCHAR(100);
    DECLARE V_REFERENCE    VARCHAR(40);
    DECLARE V_SOURCE_TABLE VARCHAR(30);
    DECLARE V_SOURCE_ID    BIGINT;
    DECLARE V_PAY_STATUS   CHAR(1);
    DECLARE V_SCHEME       CHAR(3);
    DECLARE V_CP_NAME      VARCHAR(60);
    DECLARE V_CP_SORT      CHAR(6);
    DECLARE V_CP_ACCT      CHAR(8);
    DECLARE V_CONTRA_GL    CHAR(4);
    DECLARE V_OVERDRAW     CHAR(1);
    DECLARE V_HOLD_REF     VARCHAR(40);
    DECLARE V_TXN_ID       BIGINT;
    DECLARE V_BALANCE      DECIMAL(15,2);
    DECLARE V_ROW_STATE    CHAR(5);
    DECLARE V_ROW_CODE     INTEGER;
    DECLARE V_ROW_MSG      VARCHAR(1000);
    DECLARE V_FAIL_REASON  VARCHAR(100);

    DECLARE C_QUEUE CURSOR WITH HOLD FOR
        SELECT Q.PENDING_ID, Q.ACCOUNT_ID, Q.TXN_TYPE, Q.AMOUNT, Q.DESCRIPTION, Q.REFERENCE,
               Q.SOURCE_TABLE, Q.SOURCE_ID,
               P.STATUS, P.SCHEME, P.COUNTERPARTY_NAME, P.COUNTERPARTY_SORT, P.COUNTERPARTY_ACCT
          FROM TXN.PENDING_TXN Q
          LEFT OUTER JOIN PAY.PAYMENT P
            ON Q.SOURCE_TABLE = 'PAY.PAYMENT'
           AND P.PAYMENT_ID = Q.SOURCE_ID
         WHERE Q.STATUS = 'P'
           AND Q.VALUE_DATE <= V_POSTING_DATE
         ORDER BY Q.PENDING_ID
         FETCH FIRST 5000 ROWS ONLY          -- per-run cap; the rest go next minute
          WITH CS;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET V_EOF = 1;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.END_JOB_RUN(V_RUN_ID, 'F', V_ROWS, V_MSG);
        CALL UTIL.LOG_ERROR('BATCH.PROCESS_PAYMENT_QUEUE', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'PENDING_ID=' || COALESCE(RTRIM(CHAR(V_PENDING_ID)), '-'));
        RESIGNAL;
    END;

    CALL UTIL.START_JOB_RUN('PROCESS_PAYMENT_QUEUE', V_RUN_ID);

    -- Queue items post at the online posting date (next business day once EOD cut-off has run)
    SET V_POSTING_DATE = UTIL.POSTING_DATE();

    OPEN C_QUEUE;
    FETCH_LOOP:
    LOOP
        -- reset: a zero-row UPDATE below also raises NOT FOUND
        SET V_EOF = 0;
        FETCH C_QUEUE INTO V_PENDING_ID, V_ACCOUNT_ID, V_TXN_TYPE, V_AMOUNT, V_DESCRIPTION,
                           V_REFERENCE, V_SOURCE_TABLE, V_SOURCE_ID, V_PAY_STATUS, V_SCHEME,
                           V_CP_NAME, V_CP_SORT, V_CP_ACCT;
        IF V_EOF = 1 THEN
            LEAVE FETCH_LOOP;
        END IF;

        -- Payments held for review wait; payments already finished elsewhere are closed off
        IF V_PAY_STATUS = 'H' THEN
            ITERATE FETCH_LOOP;
        END IF;
        IF V_PAY_STATUS IN ('C', 'R') THEN
            UPDATE TXN.PENDING_TXN
               SET STATUS = 'F',
                   FAIL_REASON = 'Payment already ' || CASE V_PAY_STATUS WHEN 'C' THEN 'completed' ELSE 'rejected' END
             WHERE PENDING_ID = V_PENDING_ID
               AND STATUS = 'P';
            SET V_FAILED = V_FAILED + 1;
            ITERATE FETCH_LOOP;
        END IF;

        SET V_CONTRA_GL = CASE V_TXN_TYPE
                              WHEN 'FPO'  THEN CASE V_SCHEME WHEN 'CHP' THEN '1540' WHEN 'BAC' THEN '1530' ELSE '1510' END
                              WHEN 'FPI'  THEN CASE V_SCHEME WHEN 'CHP' THEN '1540' WHEN 'BAC' THEN '1530' ELSE '1510' END
                              WHEN 'SO'   THEN '1510'
                              WHEN 'CARD' THEN '1520'
                              WHEN 'DD'   THEN '1530'
                              WHEN 'CASH' THEN '1100'
                              WHEN 'XFR'  THEN '1900'
                              WHEN 'LOAN' THEN '1900'
                              WHEN 'FEE'  THEN '4100'
                              WHEN 'ADJ'  THEN '5200'
                              ELSE NULL
                          END;
        SET V_OVERDRAW = CASE WHEN V_TXN_TYPE IN ('FEE', 'ADJ') THEN 'Y' ELSE 'N' END;
        SET V_HOLD_REF = 'PAY:' || RTRIM(CHAR(V_SOURCE_ID));
        SET V_ROW_STATE = '00000';
        SET V_ROW_MSG = NULL;

        SAVEPOINT SP_QUEUE_ROW ON ROLLBACK RETAIN CURSORS;

        ROW_BLOCK:
        BEGIN
            -- Per-row handler: record the failure and fall out of the block, the loop carries on
            DECLARE EXIT HANDLER FOR SQLEXCEPTION
            BEGIN
                GET DIAGNOSTICS EXCEPTION 1 V_ROW_MSG = MESSAGE_TEXT;
                VALUES (SQLSTATE, SQLCODE) INTO V_ROW_STATE, V_ROW_CODE;
            END;

            -- Claim the row; another worker may have got there first
            UPDATE TXN.PENDING_TXN
               SET STATUS = 'D'
             WHERE PENDING_ID = V_PENDING_ID
               AND STATUS = 'P';
            GET DIAGNOSTICS V_COUNT = ROW_COUNT;
            IF V_COUNT = 0 THEN
                LEAVE ROW_BLOCK;
            END IF;

            IF V_CONTRA_GL IS NULL THEN
                SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'No contra GL for transaction type';
            END IF;

            -- The payment's own hold must go before the debit, or it counts against itself
            IF V_SOURCE_TABLE = 'PAY.PAYMENT' THEN
                UPDATE ACCT.ACCOUNT_HOLD
                   SET STATUS = 'R',
                       RELEASED_TS = CURRENT TIMESTAMP
                 WHERE ACCOUNT_ID = V_ACCOUNT_ID
                   AND STATUS = 'A'
                   AND SOURCE_REF = V_HOLD_REF;
            END IF;

            CALL UTIL.POST_LEDGER_ENTRY(V_ACCOUNT_ID, V_AMOUNT, V_TXN_TYPE, V_DESCRIPTION, V_REFERENCE,
                                        V_CONTRA_GL, NULL, V_POSTING_DATE, V_OVERDRAW,
                                        V_CP_NAME, V_CP_SORT, V_CP_ACCT, NULL, NULL,
                                        V_TXN_ID, V_BALANCE);

            IF V_SOURCE_TABLE = 'PAY.PAYMENT' THEN
                UPDATE PAY.PAYMENT
                   SET STATUS = 'C',
                       COMPLETED_TS = CURRENT TIMESTAMP
                 WHERE PAYMENT_ID = V_SOURCE_ID
                   AND STATUS = 'P';
            END IF;

            SET V_POSTED = V_POSTED + 1;
        END ROW_BLOCK;

        IF V_ROW_STATE <> '00000' THEN
            ROLLBACK TO SAVEPOINT SP_QUEUE_ROW;

            SET V_FAIL_REASON = CASE V_ROW_STATE
                                    WHEN '75001' THEN 'Insufficient funds'
                                    WHEN '75002' THEN 'Account not found'
                                    WHEN '75003' THEN 'Account closed or frozen'
                                    WHEN '75008' THEN 'Invalid amount or transaction type'
                                    ELSE SUBSTR(V_ROW_STATE || ' ' || COALESCE(V_ROW_MSG, ''), 1, 100)
                                END;

            UPDATE TXN.PENDING_TXN
               SET STATUS = 'F',
                   FAIL_REASON = V_FAIL_REASON
             WHERE PENDING_ID = V_PENDING_ID
               AND STATUS = 'P';

            IF V_SOURCE_TABLE = 'PAY.PAYMENT' THEN
                -- TRG_PAYMENT_REJECTED tells the customer
                UPDATE PAY.PAYMENT
                   SET STATUS = 'R',
                       FAIL_REASON = V_FAIL_REASON,
                       COMPLETED_TS = CURRENT TIMESTAMP
                 WHERE PAYMENT_ID = V_SOURCE_ID
                   AND STATUS = 'P';

                UPDATE ACCT.ACCOUNT_HOLD
                   SET STATUS = 'R',
                       RELEASED_TS = CURRENT TIMESTAMP
                 WHERE ACCOUNT_ID = V_ACCOUNT_ID
                   AND STATUS = 'A'
                   AND SOURCE_REF = V_HOLD_REF;
            END IF;

            -- Business rejections are routine; anything else is worth a look
            IF SUBSTR(V_ROW_STATE, 1, 3) <> '750' THEN
                CALL UTIL.LOG_ERROR('BATCH.PROCESS_PAYMENT_QUEUE', V_ROW_STATE, V_ROW_CODE, V_ROW_MSG,
                                    'PENDING_ID=' || RTRIM(CHAR(V_PENDING_ID)));
            END IF;
            SET V_FAILED = V_FAILED + 1;
        ELSE
            RELEASE SAVEPOINT SP_QUEUE_ROW;
        END IF;

        SET V_ROWS = V_ROWS + 1;
        IF MOD(V_ROWS, V_COMMIT_EVERY) = 0 THEN
            COMMIT;
        END IF;
    END LOOP FETCH_LOOP;
    CLOSE C_QUEUE;

    COMMIT;

    SET P_ROWS_PROCESSED = V_ROWS;
    CALL UTIL.END_JOB_RUN(V_RUN_ID, 'S', V_ROWS,
         RTRIM(CHAR(V_POSTED)) || ' posted, ' || RTRIM(CHAR(V_FAILED)) || ' failed, value date '
         || CHAR(V_POSTING_DATE, ISO));
END@

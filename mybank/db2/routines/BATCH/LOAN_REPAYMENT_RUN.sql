-- Month-end: collects loan instalments due on or before today (schedule status 'D', plus 'M'
-- instalments missed earlier) from the repayment account. Accounting per collected instalment:
--   interest  : accrued (POST_GL_PAIR 1220/4220) and immediately collected as an INT debit on the
--               repayment account contra 1220, so 1220 nets to zero. Interest on missed instalments
--               is held in suspense (not recognised) until it is actually collected.
--   principal : LOAN debit on the repayment account and LOAN credit on the loan account, both
--               contra 1900, so the suspense account nets to zero.
-- No funds: instalment 'M', ARREARS_AMOUNT/MISSED_PAYMENTS up, loan 'D' (default) after 3 misses.
CREATE OR REPLACE PROCEDURE BATCH.LOAN_REPAYMENT_RUN (OUT P_ROWS_PROCESSED INTEGER)
    LANGUAGE SQL
    SPECIFIC BATCH_LOAN_REPAYMENT_RUN
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
    DECLARE V_MISSED   INTEGER DEFAULT 0;
    DECLARE V_COLLECTED DECIMAL(17,2) DEFAULT 0;
    DECLARE V_EOF      SMALLINT DEFAULT 0;
    DECLARE V_TODAY    DATE;
    DECLARE V_DEFAULT_AFTER SMALLINT DEFAULT 3;

    DECLARE V_LOAN_ID       BIGINT;
    DECLARE V_INSTALMENT_NO SMALLINT;
    DECLARE V_DUE_DATE      DATE;
    DECLARE V_PAYMENT       DECIMAL(15,2);
    DECLARE V_INTEREST      DECIMAL(15,2);
    DECLARE V_PRINCIPAL     DECIMAL(15,2);
    DECLARE V_SCHED_STATUS  CHAR(1);
    DECLARE V_LOAN_ACCOUNT  BIGINT;
    DECLARE V_REPAY_ACCOUNT BIGINT;
    DECLARE V_CUSTOMER_ID   BIGINT;
    DECLARE V_REFERENCE     VARCHAR(40);
    DECLARE V_CORR          BIGINT;
    DECLARE V_TXN_ID        BIGINT;
    DECLARE V_REPAY_TXN_ID  BIGINT;
    DECLARE V_BALANCE       DECIMAL(15,2);
    DECLARE V_ROW_STATE     CHAR(5);
    DECLARE V_ROW_CODE      INTEGER;
    DECLARE V_ROW_MSG       VARCHAR(1000);

    DECLARE C_DUE CURSOR WITH HOLD FOR
        SELECT S.LOAN_ID, S.INSTALMENT_NO, S.DUE_DATE, S.PAYMENT, S.INTEREST, S.PRINCIPAL, S.STATUS,
               L.LOAN_ACCOUNT_ID, L.REPAYMENT_ACCOUNT_ID, L.CUSTOMER_ID
          FROM LOAN.REPAYMENT_SCHEDULE S
          JOIN LOAN.LOAN L
            ON L.LOAN_ID = S.LOAN_ID
         WHERE S.STATUS IN ('D', 'M')
           AND S.DUE_DATE <= V_TODAY
           AND L.STATUS IN ('A', 'D')
         ORDER BY S.LOAN_ID, S.INSTALMENT_NO
          WITH CS;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET V_EOF = 1;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.END_JOB_RUN(V_RUN_ID, 'F', V_ROWS, V_MSG);
        CALL UTIL.LOG_ERROR('BATCH.LOAN_REPAYMENT_RUN', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'LOAN_ID=' || COALESCE(RTRIM(CHAR(V_LOAN_ID)), '-') || ' INSTALMENT='
                            || COALESCE(RTRIM(CHAR(V_INSTALMENT_NO)), '-'));
        RESIGNAL;
    END;

    CALL UTIL.START_JOB_RUN('LOAN_REPAYMENT_RUN', V_RUN_ID);
    SET V_TODAY = UTIL.CURRENT_BUSINESS_DATE();

    OPEN C_DUE;
    LOAN_LOOP:
    LOOP
        SET V_EOF = 0;
        FETCH C_DUE INTO V_LOAN_ID, V_INSTALMENT_NO, V_DUE_DATE, V_PAYMENT, V_INTEREST, V_PRINCIPAL,
                         V_SCHED_STATUS, V_LOAN_ACCOUNT, V_REPAY_ACCOUNT, V_CUSTOMER_ID;
        IF V_EOF = 1 THEN
            LEAVE LOAN_LOOP;
        END IF;
        SET V_ROWS = V_ROWS + 1;

        SET V_REFERENCE = 'LOAN ' || RTRIM(CHAR(V_LOAN_ID)) || '/' || RTRIM(CHAR(V_INSTALMENT_NO));
        SET V_CORR = NEXT VALUE FOR TXN.SEQ_CORRELATION;

        SET V_ROW_STATE = '00000';
        SET V_REPAY_TXN_ID = NULL;
        SAVEPOINT SP_LOAN ON ROLLBACK RETAIN CURSORS;

        COLLECT_BLOCK:
        BEGIN
            DECLARE EXIT HANDLER FOR SQLEXCEPTION
            BEGIN
                GET DIAGNOSTICS EXCEPTION 1 V_ROW_MSG = MESSAGE_TEXT;
                VALUES (SQLSTATE, SQLCODE) INTO V_ROW_STATE, V_ROW_CODE;
            END;

            IF V_INTEREST > 0 THEN
                CALL UTIL.POST_GL_PAIR('1220', '4220', V_INTEREST, V_TODAY, V_CORR, NULL,
                                       'Loan interest accrued ' || V_REFERENCE);
                CALL UTIL.POST_LEDGER_ENTRY(V_REPAY_ACCOUNT, -V_INTEREST, 'INT', 'Loan interest ' || V_REFERENCE,
                                            V_REFERENCE, '1220', V_CORR, V_TODAY, 'N',
                                            NULL, NULL, NULL, NULL, NULL, V_REPAY_TXN_ID, V_BALANCE);
            END IF;

            IF V_PRINCIPAL > 0 THEN
                CALL UTIL.POST_LEDGER_ENTRY(V_REPAY_ACCOUNT, -V_PRINCIPAL, 'LOAN', 'Loan repayment ' || V_REFERENCE,
                                            V_REFERENCE, '1900', V_CORR, V_TODAY, 'N',
                                            NULL, NULL, NULL, NULL, NULL, V_REPAY_TXN_ID, V_BALANCE);
                CALL UTIL.POST_LEDGER_ENTRY(V_LOAN_ACCOUNT, V_PRINCIPAL, 'LOAN', 'Repayment received ' || V_REFERENCE,
                                            V_REFERENCE, '1900', V_CORR, V_TODAY, 'Y',
                                            NULL, NULL, NULL, NULL, NULL, V_TXN_ID, V_BALANCE);
            END IF;
        END COLLECT_BLOCK;

        IF V_ROW_STATE = '00000' THEN
            RELEASE SAVEPOINT SP_LOAN;

            UPDATE LOAN.REPAYMENT_SCHEDULE
               SET STATUS = 'P'
             WHERE LOAN_ID = V_LOAN_ID
               AND INSTALMENT_NO = V_INSTALMENT_NO;

            INSERT INTO LOAN.REPAYMENT (LOAN_ID, AMOUNT, PAID_DATE, REPAYMENT_TYPE, TXN_ID)
            VALUES (V_LOAN_ID, V_INTEREST + V_PRINCIPAL, V_TODAY, 'S', V_REPAY_TXN_ID);

            UPDATE LOAN.LOAN
               SET OUTSTANDING_PRINCIPAL = OUTSTANDING_PRINCIPAL - V_PRINCIPAL,
                   ARREARS_AMOUNT = CASE WHEN V_SCHED_STATUS = 'M'
                                         THEN CASE WHEN ARREARS_AMOUNT > V_PAYMENT
                                                   THEN ARREARS_AMOUNT - V_PAYMENT ELSE 0 END
                                         ELSE ARREARS_AMOUNT END
             WHERE LOAN_ID = V_LOAN_ID;

            SET V_PAID = V_PAID + 1;
            SET V_COLLECTED = V_COLLECTED + V_INTEREST + V_PRINCIPAL;
        ELSE
            ROLLBACK TO SAVEPOINT SP_LOAN;

            IF V_ROW_STATE <> '75001' THEN
                CALL UTIL.LOG_ERROR('BATCH.LOAN_REPAYMENT_RUN', V_ROW_STATE, V_ROW_CODE, V_ROW_MSG,
                                    V_REFERENCE);
            END IF;

            -- A retried arrears instalment was already counted as missed
            IF V_SCHED_STATUS = 'D' THEN
                UPDATE LOAN.REPAYMENT_SCHEDULE
                   SET STATUS = 'M'
                 WHERE LOAN_ID = V_LOAN_ID
                   AND INSTALMENT_NO = V_INSTALMENT_NO;

                UPDATE LOAN.LOAN
                   SET ARREARS_AMOUNT  = ARREARS_AMOUNT + V_PAYMENT,
                       MISSED_PAYMENTS = MISSED_PAYMENTS + 1,
                       STATUS = CASE WHEN MISSED_PAYMENTS + 1 >= V_DEFAULT_AFTER THEN 'D' ELSE STATUS END
                 WHERE LOAN_ID = V_LOAN_ID;

                CALL UTIL.ENQUEUE_NOTIFICATION(V_CUSTOMER_ID, 'LOAN_PAYMENT_MISSED',
                     '{"loan":' || RTRIM(CHAR(V_LOAN_ID)) || ',"instalment":' || RTRIM(CHAR(V_INSTALMENT_NO))
                     || ',"amount":' || VARCHAR(V_PAYMENT) || ',"dueDate":"' || CHAR(V_DUE_DATE, ISO) || '"}');
                SET V_MISSED = V_MISSED + 1;
            END IF;
        END IF;

        IF MOD(V_ROWS, 200) = 0 THEN
            COMMIT;
        END IF;
    END LOOP LOAN_LOOP;
    CLOSE C_DUE;

    -- Next due date and paid-off status for every loan that has had something fall due
    UPDATE LOAN.LOAN L
       SET NEXT_DUE_DATE = (SELECT MIN(S.DUE_DATE)
                              FROM LOAN.REPAYMENT_SCHEDULE S
                             WHERE S.LOAN_ID = L.LOAN_ID
                               AND S.STATUS = 'D'),
           STATUS = CASE WHEN (SELECT COUNT(*)
                                            FROM LOAN.REPAYMENT_SCHEDULE S
                                           WHERE S.LOAN_ID = L.LOAN_ID
                                             AND S.STATUS IN ('D', 'M')) = 0
                          AND L.OUTSTANDING_PRINCIPAL <= 0
                         THEN 'P' ELSE L.STATUS END
     WHERE L.STATUS IN ('A', 'D')
       AND EXISTS (SELECT 1
                     FROM LOAN.REPAYMENT_SCHEDULE S
                    WHERE S.LOAN_ID = L.LOAN_ID
                      AND S.DUE_DATE <= V_TODAY);

    COMMIT;

    SET P_ROWS_PROCESSED = V_ROWS;
    CALL UTIL.END_JOB_RUN(V_RUN_ID, 'S', V_ROWS,
         RTRIM(CHAR(V_PAID)) || ' instalments collected (' || VARCHAR(V_COLLECTED) || '), '
         || RTRIM(CHAR(V_MISSED)) || ' newly missed');
END@

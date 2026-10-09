-- Closes an account: capitalises accrued interest, sweeps any remaining balance to
-- P_SWEEP_TO_ACCOUNT_ID, cancels standing orders, DD mandates and cards. Called by the app
-- and by CUST.CLOSE_CUSTOMER. Raises 75002/75003 account, 75009 holds/payments/loan in
-- flight, 75014 balance not zero and no sweep account (or the sweep failed).
CREATE OR REPLACE PROCEDURE ACCT.CLOSE_ACCOUNT (
    IN  P_ACCOUNT_ID          BIGINT,
    IN  P_SWEEP_TO_ACCOUNT_ID BIGINT,
    IN  P_REASON              VARCHAR(60),
    OUT P_SWEPT_AMOUNT        DECIMAL(15,2)
)
    LANGUAGE SQL
    SPECIFIC ACCT_CLOSE_ACCOUNT
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE    CHAR(5);
    DECLARE V_SQLCODE     INTEGER;
    DECLARE V_MSG         VARCHAR(1000);
    DECLARE V_TEXT        VARCHAR(70);
    DECLARE V_STATUS      CHAR(1);
    DECLARE V_BALANCE     DECIMAL(15,2);
    DECLARE V_HOLDS       DECIMAL(15,2);
    DECLARE V_ACCRUED     DECIMAL(15,6);
    DECLARE V_INTEREST    DECIMAL(15,2);
    DECLARE V_SORT_CODE   CHAR(6);
    DECLARE V_ACCOUNT_NO  CHAR(8);
    DECLARE V_ACCOUNT_NAME VARCHAR(60);
    DECLARE V_CUSTOMER_ID BIGINT;
    DECLARE V_TGT_STATUS  CHAR(1);
    DECLARE V_TGT_SORT    CHAR(6);
    DECLARE V_TGT_NO      CHAR(8);
    DECLARE V_TGT_NAME    VARCHAR(60);
    DECLARE V_COUNT       INTEGER DEFAULT 0;
    DECLARE V_CORR        BIGINT;
    DECLARE V_TXN_ID      BIGINT;
    DECLARE V_BAL_AFTER   DECIMAL(15,2);
    DECLARE V_SWEEP_STATE CHAR(5) DEFAULT '00000';
    DECLARE V_CLOSE_DATE  DATE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.LOG_ERROR('ACCT.CLOSE_ACCOUNT', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'ACCOUNT_ID=' || COALESCE(RTRIM(CHAR(P_ACCOUNT_ID)), 'NULL') ||
                            ' SWEEP_TO=' || COALESCE(RTRIM(CHAR(P_SWEEP_TO_ACCOUNT_ID)), 'NULL'));
        RESIGNAL;
    END;

    SET P_SWEPT_AMOUNT = 0;

    SELECT STATUS, LEDGER_BALANCE, HOLD_AMOUNT, ACCRUED_INTEREST, SORT_CODE, ACCOUNT_NO,
           ACCOUNT_NAME, PRIMARY_CUSTOMER_ID
      INTO V_STATUS, V_BALANCE, V_HOLDS, V_ACCRUED, V_SORT_CODE, V_ACCOUNT_NO,
           V_ACCOUNT_NAME, V_CUSTOMER_ID
      FROM ACCT.ACCOUNT
     WHERE ACCOUNT_ID = P_ACCOUNT_ID
      WITH RS USE AND KEEP UPDATE LOCKS;

    IF V_STATUS IS NULL THEN
        SET V_TEXT = 'Account ' || RTRIM(CHAR(P_ACCOUNT_ID)) || ' not found';
        SIGNAL SQLSTATE '75002' SET MESSAGE_TEXT = V_TEXT;
    END IF;
    IF V_STATUS = 'C' THEN
        SIGNAL SQLSTATE '75003' SET MESSAGE_TEXT = 'Account is already closed';
    END IF;
    IF V_STATUS = 'F' THEN
        SIGNAL SQLSTATE '75003' SET MESSAGE_TEXT = 'Account is frozen';
    END IF;

    -- Nothing may be in flight
    IF V_HOLDS > 0 THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Account has active holds';
    END IF;

    SELECT COUNT(*) INTO V_COUNT
      FROM PAY.PAYMENT
     WHERE ACCOUNT_ID = P_ACCOUNT_ID
       AND STATUS IN ('P', 'H');
    IF V_COUNT = 0 THEN
        SELECT COUNT(*) INTO V_COUNT
          FROM TXN.PENDING_TXN
         WHERE ACCOUNT_ID = P_ACCOUNT_ID
           AND STATUS = 'P';
    END IF;
    IF V_COUNT > 0 THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Account has payments in flight';
    END IF;

    SELECT COUNT(*) INTO V_COUNT
      FROM LOAN.LOAN
     WHERE (LOAN_ACCOUNT_ID = P_ACCOUNT_ID OR REPAYMENT_ACCOUNT_ID = P_ACCOUNT_ID)
       AND STATUS = 'A';
    IF V_COUNT > 0 THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Account is linked to an active loan';
    END IF;

    -- Sweep target, checked before anything is posted
    SET V_INTEREST = ROUND(V_ACCRUED, 2);
    IF V_BALANCE + V_INTEREST <> 0 THEN
        IF P_SWEEP_TO_ACCOUNT_ID IS NULL THEN
            SIGNAL SQLSTATE '75014' SET MESSAGE_TEXT = 'Balance not zero and no sweep account given';
        END IF;
        IF P_SWEEP_TO_ACCOUNT_ID = P_ACCOUNT_ID THEN
            SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Cannot sweep an account to itself';
        END IF;

        SELECT STATUS, SORT_CODE, ACCOUNT_NO, ACCOUNT_NAME
          INTO V_TGT_STATUS, V_TGT_SORT, V_TGT_NO, V_TGT_NAME
          FROM ACCT.ACCOUNT
         WHERE ACCOUNT_ID = P_SWEEP_TO_ACCOUNT_ID
          WITH CS;
        IF V_TGT_STATUS IS NULL THEN
            SIGNAL SQLSTATE '75002' SET MESSAGE_TEXT = 'Sweep account not found';
        END IF;
    END IF;

    -- Capitalise interest accrued since the last month-end (credit +, overdraft -)
    IF V_INTEREST > 0 THEN
        CALL UTIL.POST_LEDGER_ENTRY(P_ACCOUNT_ID, V_INTEREST, 'INT', 'Credit interest on closure',
                                    NULL, '2210', NULL, NULL, 'Y',
                                    NULL, NULL, NULL, NULL, NULL, V_TXN_ID, V_BALANCE);
    ELSEIF V_INTEREST < 0 THEN
        CALL UTIL.POST_LEDGER_ENTRY(P_ACCOUNT_ID, V_INTEREST, 'INT', 'Overdraft interest on closure',
                                    NULL, '1210', NULL, NULL, 'Y',
                                    NULL, NULL, NULL, NULL, NULL, V_TXN_ID, V_BALANCE);
    END IF;

    -- Sweep. Both legs or neither: roll back to the savepoint if either leg fails
    IF V_BALANCE <> 0 THEN
        SET V_CORR = NEXT VALUE FOR TXN.SEQ_CORRELATION;

        SAVEPOINT SP_CLOSE_SWEEP ON ROLLBACK RETAIN CURSORS;

        SWEEP: BEGIN
            DECLARE EXIT HANDLER FOR SQLEXCEPTION
            BEGIN
                VALUES (SQLSTATE) INTO V_SWEEP_STATE;
                ROLLBACK TO SAVEPOINT SP_CLOSE_SWEEP;
            END;

            IF V_BALANCE > 0 THEN
                -- Credit balance: move it out to the target
                CALL UTIL.POST_LEDGER_ENTRY(P_ACCOUNT_ID, -V_BALANCE, 'XFR', 'Closing balance transfer',
                                            'CLOSE ' || V_ACCOUNT_NO, '1900', V_CORR, NULL, 'Y',
                                            V_TGT_NAME, V_TGT_SORT, V_TGT_NO, NULL, NULL,
                                            V_TXN_ID, V_BAL_AFTER);
                CALL UTIL.POST_LEDGER_ENTRY(P_SWEEP_TO_ACCOUNT_ID, V_BALANCE, 'XFR', 'Closing balance transfer',
                                            'CLOSE ' || V_ACCOUNT_NO, '1900', V_CORR, NULL, 'N',
                                            V_ACCOUNT_NAME, V_SORT_CODE, V_ACCOUNT_NO, NULL, NULL,
                                            V_TXN_ID, V_BAL_AFTER);
            ELSE
                -- Overdrawn: the target clears the debt, subject to its own available balance
                CALL UTIL.POST_LEDGER_ENTRY(P_SWEEP_TO_ACCOUNT_ID, V_BALANCE, 'XFR', 'Clear overdrawn balance',
                                            'CLOSE ' || V_ACCOUNT_NO, '1900', V_CORR, NULL, 'N',
                                            V_ACCOUNT_NAME, V_SORT_CODE, V_ACCOUNT_NO, NULL, NULL,
                                            V_TXN_ID, V_BAL_AFTER);
                CALL UTIL.POST_LEDGER_ENTRY(P_ACCOUNT_ID, -V_BALANCE, 'XFR', 'Clear overdrawn balance',
                                            'CLOSE ' || V_ACCOUNT_NO, '1900', V_CORR, NULL, 'N',
                                            V_TGT_NAME, V_TGT_SORT, V_TGT_NO, NULL, NULL,
                                            V_TXN_ID, V_BAL_AFTER);
            END IF;
            SET P_SWEPT_AMOUNT = V_BALANCE;
        END SWEEP;

        IF V_SWEEP_STATE <> '00000' THEN
            SET V_TEXT = 'Balance sweep failed with SQLSTATE ' || V_SWEEP_STATE;
            SIGNAL SQLSTATE '75014' SET MESSAGE_TEXT = V_TEXT;
        END IF;

        RELEASE SAVEPOINT SP_CLOSE_SWEEP;
    END IF;

    -- Belt and braces: nothing may be left on the account
    SELECT LEDGER_BALANCE INTO V_BALANCE FROM ACCT.ACCOUNT WHERE ACCOUNT_ID = P_ACCOUNT_ID;
    IF V_BALANCE <> 0 THEN
        SIGNAL SQLSTATE '75014' SET MESSAGE_TEXT = 'Account balance not zero';
    END IF;

    SET V_CLOSE_DATE = UTIL.POSTING_DATE();

    UPDATE PAY.STANDING_ORDER
       SET STATUS = 'C'
     WHERE ACCOUNT_ID = P_ACCOUNT_ID
       AND STATUS IN ('A', 'S');

    UPDATE PAY.DD_MANDATE
       SET STATUS = 'C',
           CANCELLED_DATE = V_CLOSE_DATE
     WHERE ACCOUNT_ID = P_ACCOUNT_ID
       AND STATUS = 'A';

    UPDATE CARD.CARD
       SET STATUS = 'B',
           BLOCKED_REASON = 'ACCOUNT CLOSED'
     WHERE ACCOUNT_ID = P_ACCOUNT_ID
       AND STATUS = 'A';

    UPDATE ACCT.ACCOUNT
       SET STATUS = 'C',
           CLOSED_DATE = V_CLOSE_DATE,
           OVERDRAFT_LIMIT = 0,
           ACCRUED_INTEREST = 0,
           LAST_ACCRUAL_DATE = V_CLOSE_DATE,
           FREEZE_REASON = NULL
     WHERE ACCOUNT_ID = P_ACCOUNT_ID;

    CALL UTIL.WRITE_AUDIT('ACCT.ACCOUNT', RTRIM(CHAR(P_ACCOUNT_ID)), 'U',
                          'Closed: ' || COALESCE(P_REASON, 'customer request') ||
                          '. Swept ' || VARCHAR(P_SWEPT_AMOUNT) ||
                          COALESCE(' to ' || RTRIM(CHAR(P_SWEEP_TO_ACCOUNT_ID)), '') ||
                          ', interest ' || VARCHAR(V_INTEREST));

    CALL UTIL.ENQUEUE_NOTIFICATION(V_CUSTOMER_ID, 'ACCOUNT_CLOSED',
                                   '{"sortCode":"' || UTIL.FORMAT_SORT_CODE(V_SORT_CODE) ||
                                   '","accountNo":"' || V_ACCOUNT_NO || '"}');
END@

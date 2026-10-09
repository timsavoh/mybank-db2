-- The core posting routine. Every movement of money on a customer account goes
-- through here: it moves the balance, writes the posted transaction and posts a
-- balanced GL pair between the product's control GL and the contra GL.
--
-- Sign convention: P_AMOUNT > 0 credits the customer, < 0 debits them.
-- GL: debits positive, credits negative. A customer credit is a credit to the
-- control GL (a liability for deposits) and a debit to the contra GL.
--
-- Raises 75001 insufficient funds, 75002 not found, 75003 not active, 75008 bad amount.
CREATE OR REPLACE PROCEDURE UTIL.POST_LEDGER_ENTRY (
    IN  P_ACCOUNT_ID     BIGINT,
    IN  P_AMOUNT         DECIMAL(15,2),
    IN  P_TXN_TYPE       CHAR(4),
    IN  P_DESCRIPTION    VARCHAR(100),
    IN  P_REFERENCE      VARCHAR(40),
    IN  P_CONTRA_GL      CHAR(4),
    IN  P_CORRELATION_ID BIGINT,
    IN  P_BUSINESS_DATE  DATE,
    IN  P_ALLOW_OVERDRAW CHAR(1),
    IN  P_COUNTERPARTY   VARCHAR(60),
    IN  P_CP_SORT        CHAR(6),
    IN  P_CP_ACCT        CHAR(8),
    IN  P_MERCHANT_ID    INTEGER,
    IN  P_MCC            CHAR(4),
    OUT P_TXN_ID         BIGINT,
    OUT P_BALANCE_AFTER  DECIMAL(15,2)
)
    LANGUAGE SQL
    SPECIFIC UTIL_POST_LEDGER_ENTRY
    MODIFIES SQL DATA
BEGIN
    DECLARE V_STATUS     CHAR(1);
    DECLARE V_AVAILABLE  DECIMAL(15,2);
    DECLARE V_CONTROL_GL CHAR(4);
    DECLARE V_DATE       DATE;
    DECLARE V_CORR       BIGINT;
    DECLARE V_MSG        VARCHAR(70);

    IF P_AMOUNT IS NULL OR P_AMOUNT = 0 THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Posting amount must be non-zero';
    END IF;

    SELECT A.STATUS, A.LEDGER_BALANCE - A.HOLD_AMOUNT + A.OVERDRAFT_LIMIT, P.CONTROL_GL_CODE
      INTO V_STATUS, V_AVAILABLE, V_CONTROL_GL
      FROM ACCT.ACCOUNT A
      JOIN REF.PRODUCT P ON P.PRODUCT_CODE = A.PRODUCT_CODE
     WHERE A.ACCOUNT_ID = P_ACCOUNT_ID
      WITH RS USE AND KEEP UPDATE LOCKS;

    IF V_STATUS IS NULL THEN
        SET V_MSG = 'Account ' || RTRIM(CHAR(P_ACCOUNT_ID)) || ' not found';
        SIGNAL SQLSTATE '75002' SET MESSAGE_TEXT = V_MSG;
    END IF;

    IF V_STATUS = 'C' OR (V_STATUS = 'F' AND P_AMOUNT < 0) THEN
        SIGNAL SQLSTATE '75003' SET MESSAGE_TEXT = 'Account not available for posting';
    END IF;

    IF P_AMOUNT < 0 AND COALESCE(P_ALLOW_OVERDRAW, 'N') = 'N' AND V_AVAILABLE + P_AMOUNT < 0 THEN
        SIGNAL SQLSTATE '75001' SET MESSAGE_TEXT = 'Insufficient funds';
    END IF;

    SET V_DATE = COALESCE(P_BUSINESS_DATE, UTIL.POSTING_DATE());
    SET V_CORR = COALESCE(P_CORRELATION_ID, NEXT VALUE FOR TXN.SEQ_CORRELATION);

    SELECT LEDGER_BALANCE
      INTO P_BALANCE_AFTER
      FROM FINAL TABLE (UPDATE ACCT.ACCOUNT
                           SET LEDGER_BALANCE = LEDGER_BALANCE + P_AMOUNT
                         WHERE ACCOUNT_ID = P_ACCOUNT_ID);

    SELECT TXN_ID
      INTO P_TXN_ID
      FROM FINAL TABLE (INSERT INTO TXN.POSTED_TXN
                            (ACCOUNT_ID, BUSINESS_DATE, TXN_TYPE, AMOUNT, BALANCE_AFTER,
                             DESCRIPTION, REFERENCE, COUNTERPARTY_NAME, COUNTERPARTY_SORT,
                             COUNTERPARTY_ACCT, MERCHANT_ID, MCC, CORRELATION_ID, CHANNEL)
                        VALUES
                            (P_ACCOUNT_ID, V_DATE, P_TXN_TYPE, P_AMOUNT, P_BALANCE_AFTER,
                             P_DESCRIPTION, P_REFERENCE, P_COUNTERPARTY, P_CP_SORT,
                             P_CP_ACCT, P_MERCHANT_ID, P_MCC, V_CORR, UTIL.GV_CHANNEL));

    CALL UTIL.POST_GL_PAIR(P_CONTRA_GL, V_CONTROL_GL, P_AMOUNT, V_DATE, V_CORR, P_TXN_ID, P_DESCRIPTION);
END@

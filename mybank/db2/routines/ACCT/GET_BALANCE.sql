-- Ledger and available balance for one account. Dirty read on purpose: balance
-- enquiries must never wait on posting locks. Called by the app (every screen).
-- Raises 75002 account not found.
CREATE OR REPLACE PROCEDURE ACCT.GET_BALANCE (
    IN  P_ACCOUNT_ID        BIGINT,
    OUT P_LEDGER_BALANCE    DECIMAL(15,2),
    OUT P_AVAILABLE_BALANCE DECIMAL(15,2),
    OUT P_HOLD_AMOUNT       DECIMAL(15,2),
    OUT P_OVERDRAFT_LIMIT   DECIMAL(15,2),
    OUT P_STATUS            CHAR(1),
    OUT P_AS_OF             TIMESTAMP
)
    LANGUAGE SQL
    SPECIFIC ACCT_GET_BALANCE
    READS SQL DATA
BEGIN
    DECLARE V_TEXT VARCHAR(70);

    SELECT LEDGER_BALANCE,
           UTIL.AVAILABLE_BALANCE(ACCOUNT_ID),
           HOLD_AMOUNT,
           OVERDRAFT_LIMIT,
           STATUS,
           CURRENT TIMESTAMP
      INTO P_LEDGER_BALANCE, P_AVAILABLE_BALANCE, P_HOLD_AMOUNT, P_OVERDRAFT_LIMIT,
           P_STATUS, P_AS_OF
      FROM ACCT.ACCOUNT
     WHERE ACCOUNT_ID = P_ACCOUNT_ID
      WITH UR;

    IF P_STATUS IS NULL THEN
        SET V_TEXT = 'Account ' || COALESCE(RTRIM(CHAR(P_ACCOUNT_ID)), 'NULL') || ' not found';
        SIGNAL SQLSTATE '75002' SET MESSAGE_TEXT = V_TEXT;
    END IF;

    -- A frozen or closed account has nothing available to spend
    IF P_STATUS IN ('F', 'C') THEN
        SET P_AVAILABLE_BALANCE = 0;
    END IF;
END@

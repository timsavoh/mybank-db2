-- Signals if the account cannot take the requested movement.
--   75002 account not found
--   75003 account closed, or frozen/dormant and a debit was requested
CREATE OR REPLACE PROCEDURE UTIL.CHECK_ACCOUNT_STATUS (
    IN P_ACCOUNT_ID BIGINT,
    IN P_FOR_DEBIT  CHAR(1)
)
    LANGUAGE SQL
    SPECIFIC UTIL_CHECK_ACCOUNT_STATUS
    READS SQL DATA
BEGIN
    DECLARE V_STATUS CHAR(1);
    DECLARE V_MSG VARCHAR(70);

    SELECT STATUS INTO V_STATUS FROM ACCT.ACCOUNT WHERE ACCOUNT_ID = P_ACCOUNT_ID WITH CS;

    IF V_STATUS IS NULL THEN
        SET V_MSG = 'Account ' || RTRIM(CHAR(P_ACCOUNT_ID)) || ' not found';
        SIGNAL SQLSTATE '75002' SET MESSAGE_TEXT = V_MSG;
    END IF;

    IF V_STATUS = 'C' THEN
        SIGNAL SQLSTATE '75003' SET MESSAGE_TEXT = 'Account is closed';
    END IF;

    IF P_FOR_DEBIT = 'Y' AND V_STATUS = 'F' THEN
        SIGNAL SQLSTATE '75003' SET MESSAGE_TEXT = 'Account is frozen';
    END IF;
END@

-- Ring-fences funds on an account (teller/ops holds, pre-authorised payments).
-- HOLD_AMOUNT on the account is maintained by TRG_HOLD_PLACED. Returns the hold id.
-- Raises 75001 insufficient available funds, 75002/75003 account, 75007 duplicate
-- source reference, 75008 bad amount or expiry.
CREATE OR REPLACE PROCEDURE ACCT.PLACE_HOLD (
    IN  P_ACCOUNT_ID BIGINT,
    IN  P_AMOUNT     DECIMAL(15,2),
    IN  P_REASON     VARCHAR(20),
    IN  P_SOURCE_REF VARCHAR(40),
    IN  P_EXPIRES_TS TIMESTAMP,
    OUT P_HOLD_ID    BIGINT
)
    LANGUAGE SQL
    SPECIFIC ACCT_PLACE_HOLD
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE  CHAR(5);
    DECLARE V_SQLCODE   INTEGER;
    DECLARE V_MSG       VARCHAR(1000);
    DECLARE V_AVAILABLE DECIMAL(15,2);
    DECLARE V_EXPIRES   TIMESTAMP;
    DECLARE V_DUPS      INTEGER DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.LOG_ERROR('ACCT.PLACE_HOLD', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'ACCOUNT_ID=' || COALESCE(RTRIM(CHAR(P_ACCOUNT_ID)), 'NULL') ||
                            ' AMOUNT=' || COALESCE(VARCHAR(P_AMOUNT), 'NULL') ||
                            ' REF=' || COALESCE(P_SOURCE_REF, 'NULL'));
        RESIGNAL;
    END;

    SET P_HOLD_ID = NULL;

    IF P_AMOUNT IS NULL OR P_AMOUNT <= 0 THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Hold amount must be positive';
    END IF;
    IF COALESCE(RTRIM(P_REASON), '') = '' THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Hold reason is required';
    END IF;

    -- Default expiry is a week; holds never outlive 90 days
    SET V_EXPIRES = COALESCE(P_EXPIRES_TS, CURRENT TIMESTAMP + 7 DAYS);
    IF V_EXPIRES <= CURRENT TIMESTAMP OR V_EXPIRES > CURRENT TIMESTAMP + 90 DAYS THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Hold expiry must be within the next 90 days';
    END IF;

    CALL UTIL.CHECK_ACCOUNT_STATUS(P_ACCOUNT_ID, 'Y');

    -- Lock the account row so two holds can't both pass the funds check
    SELECT LEDGER_BALANCE - HOLD_AMOUNT + OVERDRAFT_LIMIT
      INTO V_AVAILABLE
      FROM ACCT.ACCOUNT
     WHERE ACCOUNT_ID = P_ACCOUNT_ID
      WITH RS USE AND KEEP UPDATE LOCKS;

    IF P_SOURCE_REF IS NOT NULL THEN
        SELECT COUNT(*) INTO V_DUPS
          FROM ACCT.ACCOUNT_HOLD
         WHERE ACCOUNT_ID = P_ACCOUNT_ID
           AND SOURCE_REF = P_SOURCE_REF
           AND STATUS = 'A';
        IF V_DUPS > 0 THEN
            SIGNAL SQLSTATE '75007' SET MESSAGE_TEXT = 'An active hold already exists for this reference';
        END IF;
    END IF;

    IF V_AVAILABLE < P_AMOUNT THEN
        SIGNAL SQLSTATE '75001' SET MESSAGE_TEXT = 'Insufficient funds';
    END IF;

    SELECT HOLD_ID
      INTO P_HOLD_ID
      FROM FINAL TABLE (INSERT INTO ACCT.ACCOUNT_HOLD
                            (ACCOUNT_ID, AMOUNT, REASON, SOURCE_REF, EXPIRES_TS, STATUS)
                        VALUES
                            (P_ACCOUNT_ID, P_AMOUNT, UPPER(P_REASON), P_SOURCE_REF, V_EXPIRES, 'A'));

    CALL UTIL.WRITE_AUDIT('ACCT.ACCOUNT_HOLD', RTRIM(CHAR(P_HOLD_ID)), 'I',
                          'Hold ' || VARCHAR(P_AMOUNT) || ' on ' || RTRIM(CHAR(P_ACCOUNT_ID)) ||
                          ' ' || UPPER(P_REASON) || COALESCE(' ref ' || P_SOURCE_REF, ''));
END@

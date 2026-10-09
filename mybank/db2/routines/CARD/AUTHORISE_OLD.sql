-- DO NOT USE - see CARD.AUTHORISE.
-- Card authorisation, pre-contactless version (chip & PIN / mag stripe only). No fraud
-- scoring, bumps ACCOUNT.HOLD_AMOUNT directly (pre ACCOUNT_HOLD table), so its holds never expire.
-- Returns the ISO response code in P_RESPONSE_CODE; never SIGNALs.
--
--   03/03/2012  TW   Created
--   19/06/2013  TW   Stolen/lost cards return 43
--   11/02/2015  AP   Contactless declined here - new CARD.AUTHORISE handles it
CREATE OR REPLACE PROCEDURE CARD.AUTHORISE_OLD (
    IN  P_PAN           CHAR(16),
    IN  P_MERCHANT_ID   INTEGER,
    IN  P_AMOUNT        DECIMAL(15,2),
    IN  P_ENTRY_MODE    CHAR(2),
    IN  P_EXTERNAL_REF  VARCHAR(40),
    OUT P_RESPONSE_CODE CHAR(2),
    OUT P_AUTH_ID       BIGINT
)
    LANGUAGE SQL
    SPECIFIC CARD_AUTHORISE_OLD
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLCODE INTEGER DEFAULT 0;
    DECLARE V_CARD_ID     BIGINT;
    DECLARE V_ACCOUNT_ID  BIGINT;
    DECLARE V_CARD_STATUS CHAR(1);
    DECLARE V_EXPIRY      DATE;
    DECLARE V_DAILY_LIMIT DECIMAL(9,2);
    DECLARE V_AVAILABLE   DECIMAL(15,2);
    DECLARE V_SPENT_TODAY DECIMAL(15,2);
    DECLARE V_BDATE       DATE;
    DECLARE V_STATUS      CHAR(1) DEFAULT 'D';

    SET P_RESPONSE_CODE = '00';
    SET P_AUTH_ID = NULL;

    SELECT BUSINESS_DATE INTO V_BDATE FROM REF.BANK_CONTROL WHERE CONTROL_ID = 1;

    SELECT CARD_ID, ACCOUNT_ID, STATUS, EXPIRY_DATE, DAILY_LIMIT
      INTO V_CARD_ID, V_ACCOUNT_ID, V_CARD_STATUS, V_EXPIRY, V_DAILY_LIMIT
      FROM CARD.CARD
     WHERE PAN = P_PAN;

    IF SQLCODE = 100 THEN
        -- can't write an AUTHORISATION row without a card id, so nothing is recorded
        SET P_RESPONSE_CODE = '14';
        RETURN;
    END IF;

    -- entry mode 07 = contactless. Not supported by this version (AP 2015)
    IF P_ENTRY_MODE = '07' THEN
        SET P_RESPONSE_CODE = '05';
    ELSEIF V_CARD_STATUS IN ('L', 'S') THEN
        SET P_RESPONSE_CODE = '43';
    ELSEIF V_CARD_STATUS <> 'A' THEN
        SET P_RESPONSE_CODE = '05';
    ELSEIF V_EXPIRY < CURRENT DATE THEN
        SET P_RESPONSE_CODE = '54';
    END IF;

    IF P_RESPONSE_CODE = '00' THEN
        SELECT VALUE(SUM(AMOUNT), 0)
          INTO V_SPENT_TODAY
          FROM CARD.AUTHORISATION
         WHERE CARD_ID = V_CARD_ID
           AND BUSINESS_DATE = V_BDATE
           AND RESPONSE_CODE = '00';

        -- 500 was the old ATM/POS limit before DAILY_LIMIT was added to CARD
        IF V_SPENT_TODAY + P_AMOUNT > VALUE(V_DAILY_LIMIT, 500) THEN
            SET P_RESPONSE_CODE = '61';
        END IF;
    END IF;

    IF P_RESPONSE_CODE = '00' THEN
        SELECT LEDGER_BALANCE - HOLD_AMOUNT + OVERDRAFT_LIMIT
          INTO V_AVAILABLE
          FROM ACCT.ACCOUNT
         WHERE ACCOUNT_ID = V_ACCOUNT_ID;

        IF V_AVAILABLE < P_AMOUNT THEN
            SET P_RESPONSE_CODE = '51';
        END IF;
    END IF;

    -- TODO: fraud score (phase 2) - never done, see CARD.AUTHORISE
    IF P_RESPONSE_CODE = '00' THEN
        SET V_STATUS = 'A';
        UPDATE ACCT.ACCOUNT
           SET HOLD_AMOUNT = HOLD_AMOUNT + P_AMOUNT
         WHERE ACCOUNT_ID = V_ACCOUNT_ID;
    END IF;

    SELECT AUTH_ID
      INTO P_AUTH_ID
      FROM FINAL TABLE (INSERT INTO CARD.AUTHORISATION
                            (CARD_ID, ACCOUNT_ID, MERCHANT_ID, AMOUNT, BUSINESS_DATE,
                             RESPONSE_CODE, STATUS, EXTERNAL_REF)
                        VALUES
                            (V_CARD_ID, V_ACCOUNT_ID, P_MERCHANT_ID, P_AMOUNT, V_BDATE,
                             P_RESPONSE_CODE, V_STATUS, P_EXTERNAL_REF));
END@

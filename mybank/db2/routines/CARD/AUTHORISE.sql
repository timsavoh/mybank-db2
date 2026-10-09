-- Card authorisation: the hot path, called by the card network gateway (loadgen) for every purchase.
-- Declines are business outcomes, not errors: the AUTHORISATION row is written with STATUS 'D' and the
-- ISO response code returned. Approval places a 7-day CARD_AUTH hold that BATCH.SETTLE_CARD_TRANSACTIONS
-- settles at end of day. A repeated external ref returns the original answer.
-- Response codes: 00 approved, 05, 14, 43, 51, 54, 59, 61. Raises 75008 bad argument, 75009 unknown merchant.
CREATE OR REPLACE PROCEDURE CARD.AUTHORISE (
    IN  P_PAN           CHAR(16),
    IN  P_MERCHANT_ID   INTEGER,
    IN  P_AMOUNT        DECIMAL(15,2),
    IN  P_EXTERNAL_REF  VARCHAR(40),
    OUT P_RESPONSE_CODE CHAR(2),
    OUT P_AUTH_ID       BIGINT
)
    LANGUAGE SQL
    SPECIFIC CARD_AUTHORISE
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE CHAR(5);
    DECLARE V_SQLCODE  INTEGER;
    DECLARE V_MSG      VARCHAR(1000);

    DECLARE V_DATE            DATE;
    DECLARE V_MCC             CHAR(4);
    DECLARE V_RISK_WEIGHT     SMALLINT;
    DECLARE V_CARD_ID         BIGINT;
    DECLARE V_ACCOUNT_ID      BIGINT;
    DECLARE V_CARD_STATUS     CHAR(1);
    DECLARE V_EXPIRY_DATE     DATE;
    DECLARE V_DAILY_LIMIT     DECIMAL(9,2);
    DECLARE V_ACCT_STATUS     CHAR(1);
    DECLARE V_AVAILABLE       DECIMAL(15,2);
    DECLARE V_SPENT_TODAY     DECIMAL(15,2);
    DECLARE V_RECENT_DECLINES INTEGER DEFAULT 0;
    DECLARE V_SCORE           SMALLINT DEFAULT 0;
    DECLARE V_HOLD_ID         BIGINT;
    DECLARE V_ALERT_ID        BIGINT;
    DECLARE V_DUPLICATE       SMALLINT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.LOG_ERROR('CARD.AUTHORISE', V_SQLSTATE, V_SQLCODE, V_MSG,
             'PAN=' || COALESCE(UTIL.MASK_PAN(P_PAN), 'NULL') ||
             ' MERCHANT=' || COALESCE(RTRIM(CHAR(P_MERCHANT_ID)), 'NULL') ||
             ' AMOUNT=' || COALESCE(VARCHAR(P_AMOUNT), 'NULL') ||
             ' REF=' || COALESCE(P_EXTERNAL_REF, 'NULL'));
        RESIGNAL;
    END;

    SET P_RESPONSE_CODE = NULL;
    SET P_AUTH_ID = NULL;

    IF P_EXTERNAL_REF IS NULL OR P_AMOUNT IS NULL OR P_AMOUNT <= 0 THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Positive amount and external reference required';
    END IF;

    -- Network retry / timeout resend: same answer as the first time
    SELECT AUTH_ID, RESPONSE_CODE INTO P_AUTH_ID, P_RESPONSE_CODE
      FROM CARD.AUTHORISATION
     WHERE EXTERNAL_REF = P_EXTERNAL_REF;

    IF P_AUTH_ID IS NOT NULL THEN
        RETURN;
    END IF;

    SELECT M.MCC, C.RISK_WEIGHT INTO V_MCC, V_RISK_WEIGHT
      FROM CARD.MERCHANT M
      JOIN REF.MERCHANT_CATEGORY C ON C.MCC = M.MCC
     WHERE M.MERCHANT_ID = P_MERCHANT_ID
      WITH UR;

    IF V_MCC IS NULL THEN
        SET V_MSG = 'Unknown merchant ' || COALESCE(RTRIM(CHAR(P_MERCHANT_ID)), 'NULL');
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = V_MSG;
    END IF;

    SET V_DATE = UTIL.POSTING_DATE();

    SELECT CARD_ID, ACCOUNT_ID, STATUS, EXPIRY_DATE, DAILY_LIMIT
      INTO V_CARD_ID, V_ACCOUNT_ID, V_CARD_STATUS, V_EXPIRY_DATE, V_DAILY_LIMIT
      FROM CARD.CARD
     WHERE PAN = P_PAN
      WITH UR;

    L_CHECKS:
    BEGIN
        IF V_CARD_STATUS IS NULL THEN
            -- AUTHORISATION.CARD_ID / ACCOUNT_ID are NOT NULL: 0 marks an unknown PAN
            SET V_CARD_ID = 0;
            SET V_ACCOUNT_ID = 0;
            SET P_RESPONSE_CODE = '14';
            LEAVE L_CHECKS;
        END IF;

        IF V_CARD_STATUS IN ('L', 'S') THEN
            SET P_RESPONSE_CODE = '43';
            LEAVE L_CHECKS;
        END IF;

        IF V_CARD_STATUS <> 'A' THEN
            SET P_RESPONSE_CODE = '05';
            LEAVE L_CHECKS;
        END IF;

        IF V_EXPIRY_DATE < V_DATE THEN
            SET P_RESPONSE_CODE = '54';
            LEAVE L_CHECKS;
        END IF;

        -- Update lock on the account row: concurrent auths on joint-account cards queue here
        -- rather than both passing the balance check
        SELECT STATUS, LEDGER_BALANCE - HOLD_AMOUNT + OVERDRAFT_LIMIT
          INTO V_ACCT_STATUS, V_AVAILABLE
          FROM ACCT.ACCOUNT
         WHERE ACCOUNT_ID = V_ACCOUNT_ID
          WITH RS USE AND KEEP UPDATE LOCKS;

        IF V_ACCT_STATUS IN ('F', 'C') THEN
            SET P_RESPONSE_CODE = '05';
            LEAVE L_CHECKS;
        END IF;

        SELECT COALESCE(SUM(AMOUNT), 0) INTO V_SPENT_TODAY
          FROM CARD.AUTHORISATION
         WHERE CARD_ID = V_CARD_ID
           AND BUSINESS_DATE = V_DATE
           AND STATUS IN ('A', 'S');

        IF V_SPENT_TODAY + P_AMOUNT > V_DAILY_LIMIT THEN
            SET P_RESPONSE_CODE = '61';
            LEAVE L_CHECKS;
        END IF;

        IF V_AVAILABLE < P_AMOUNT THEN
            SET P_RESPONSE_CODE = '51';
            LEAVE L_CHECKS;
        END IF;

        -- Fraud score 0-100: merchant category risk, declines on this card in the last
        -- 30 minutes of wall clock, and a bump for large tickets
        SELECT COUNT(*) INTO V_RECENT_DECLINES
          FROM CARD.AUTHORISATION
         WHERE CARD_ID = V_CARD_ID
           AND AUTH_TS > CURRENT TIMESTAMP - 30 MINUTES
           AND STATUS = 'D'
          WITH UR;

        SET V_SCORE = MIN(100, V_RISK_WEIGHT * 15 + V_RECENT_DECLINES * 10
                               + CASE WHEN P_AMOUNT > 1000 THEN 10 ELSE 0 END);

        IF V_SCORE >= 80 THEN
            SET P_RESPONSE_CODE = '59';
            LEAVE L_CHECKS;
        END IF;

        SET P_RESPONSE_CODE = '00';
    END L_CHECKS;

    SAVEPOINT SP_AUTH ON ROLLBACK RETAIN CURSORS;

    BEGIN
        -- Duplicate external ref racing in from a second gateway thread
        DECLARE CONTINUE HANDLER FOR SQLSTATE '23505' SET V_DUPLICATE = 1;

        IF P_RESPONSE_CODE = '00' THEN
            SELECT HOLD_ID INTO V_HOLD_ID
              FROM FINAL TABLE (INSERT INTO ACCT.ACCOUNT_HOLD
                                    (ACCOUNT_ID, AMOUNT, REASON, SOURCE_REF, EXPIRES_TS)
                                VALUES (V_ACCOUNT_ID, P_AMOUNT, 'CARD_AUTH', P_EXTERNAL_REF,
                                        CURRENT TIMESTAMP + 7 DAYS));
        END IF;

        SELECT AUTH_ID INTO P_AUTH_ID
          FROM FINAL TABLE (INSERT INTO CARD.AUTHORISATION
                                (CARD_ID, ACCOUNT_ID, MERCHANT_ID, AMOUNT, BUSINESS_DATE,
                                 RESPONSE_CODE, STATUS, HOLD_ID, FRAUD_SCORE, EXTERNAL_REF)
                            VALUES (V_CARD_ID, V_ACCOUNT_ID, P_MERCHANT_ID, P_AMOUNT, V_DATE,
                                    P_RESPONSE_CODE,
                                    CASE WHEN P_RESPONSE_CODE = '00' THEN 'A' ELSE 'D' END,
                                    V_HOLD_ID, V_SCORE, P_EXTERNAL_REF));
    END;

    IF V_DUPLICATE = 1 THEN
        ROLLBACK TO SAVEPOINT SP_AUTH;
        SELECT AUTH_ID, RESPONSE_CODE INTO P_AUTH_ID, P_RESPONSE_CODE
          FROM CARD.AUTHORISATION
         WHERE EXTERNAL_REF = P_EXTERNAL_REF;
        RETURN;
    END IF;

    RELEASE SAVEPOINT SP_AUTH;

    IF P_RESPONSE_CODE = '59' THEN
        CALL UTIL.RAISE_FRAUD_ALERT(V_ACCOUNT_ID, V_CARD_ID, NULL, V_SCORE,
             'Auth ' || RTRIM(CHAR(P_AUTH_ID)) || ' declined 59: MCC ' || V_MCC ||
             ' amount ' || VARCHAR(P_AMOUNT) || ', ' || RTRIM(CHAR(V_RECENT_DECLINES)) ||
             ' recent declines', V_ALERT_ID);
    END IF;
END@

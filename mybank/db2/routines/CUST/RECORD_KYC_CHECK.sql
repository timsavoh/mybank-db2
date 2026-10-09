-- Stores a KYC/AML check outcome from a provider and re-derives the customer's KYC status.
-- Called by the app when an ID&V provider responds. RESULT P pass, F fail, R refer.
-- Raises 75004 customer not found, 75008 result/score out of range (check constraints).
CREATE OR REPLACE PROCEDURE CUST.RECORD_KYC_CHECK (
    IN  P_CUSTOMER_ID BIGINT,
    IN  P_CHECK_TYPE  VARCHAR(20),
    IN  P_RESULT      CHAR(1),
    IN  P_SCORE       SMALLINT,
    IN  P_PROVIDER    VARCHAR(30),
    IN  P_NOTES       VARCHAR(500),
    OUT P_KYC_ID      BIGINT,
    OUT P_KYC_STATUS  CHAR(1)
)
    LANGUAGE SQL
    SPECIFIC CUST_RECORD_KYC_CHECK
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE   CHAR(5);
    DECLARE V_SQLCODE    INTEGER;
    DECLARE V_MSG        VARCHAR(1000);
    DECLARE V_OLD_STATUS CHAR(1);
    DECLARE V_CUST_STATUS CHAR(1);
    DECLARE V_FAILED     INTEGER DEFAULT 0;
    DECLARE V_REFERRED   INTEGER DEFAULT 0;
    DECLARE V_NOW        TIMESTAMP;

    -- The table's check constraints do the range validation for us
    DECLARE EXIT HANDLER FOR SQLSTATE '23513'
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'KYC result must be P/F/R, score 0-1000';

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.LOG_ERROR('CUST.RECORD_KYC_CHECK', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'CUSTOMER_ID=' || COALESCE(RTRIM(CHAR(P_CUSTOMER_ID)), 'NULL') ||
                            ' TYPE=' || COALESCE(P_CHECK_TYPE, 'NULL'));
        RESIGNAL;
    END;

    SELECT KYC_STATUS, STATUS INTO V_OLD_STATUS, V_CUST_STATUS
      FROM CUST.CUSTOMER
     WHERE CUSTOMER_ID = P_CUSTOMER_ID
      WITH RS USE AND KEEP UPDATE LOCKS;

    IF V_OLD_STATUS IS NULL OR V_CUST_STATUS = 'C' THEN
        SIGNAL SQLSTATE '75004' SET MESSAGE_TEXT = 'Customer not found or closed';
    END IF;

    IF COALESCE(RTRIM(P_CHECK_TYPE), '') = '' OR COALESCE(RTRIM(P_PROVIDER), '') = '' THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Check type and provider are required';
    END IF;

    SET V_NOW = CURRENT TIMESTAMP;

    SELECT KYC_ID
      INTO P_KYC_ID
      FROM FINAL TABLE (INSERT INTO CUST.KYC_CHECK
                            (CUSTOMER_ID, CHECK_TYPE, RESULT, SCORE, PROVIDER, CHECKED_TS, NOTES)
                        VALUES
                            (P_CUSTOMER_ID, UPPER(P_CHECK_TYPE), UPPER(P_RESULT), P_SCORE,
                             P_PROVIDER, V_NOW, P_NOTES));

    -- Customer status follows the latest result of each check type
    SELECT COALESCE(SUM(CASE WHEN K.RESULT = 'F' THEN 1 ELSE 0 END), 0),
           COALESCE(SUM(CASE WHEN K.RESULT = 'R' THEN 1 ELSE 0 END), 0)
      INTO V_FAILED, V_REFERRED
      FROM CUST.KYC_CHECK K
     WHERE K.CUSTOMER_ID = P_CUSTOMER_ID
       AND K.KYC_ID = (SELECT MAX(K2.KYC_ID)
                         FROM CUST.KYC_CHECK K2
                        WHERE K2.CUSTOMER_ID = K.CUSTOMER_ID
                          AND K2.CHECK_TYPE = K.CHECK_TYPE);

    SET P_KYC_STATUS = CASE WHEN V_FAILED > 0   THEN 'F'
                            WHEN V_REFERRED > 0 THEN 'P'
                            ELSE 'V' END;

    IF P_KYC_STATUS <> V_OLD_STATUS THEN
        UPDATE CUST.CUSTOMER
           SET KYC_STATUS  = P_KYC_STATUS,
               RISK_RATING = CASE WHEN P_KYC_STATUS = 'F' THEN MAX(RISK_RATING, 3)
                                  ELSE RISK_RATING END
         WHERE CUSTOMER_ID = P_CUSTOMER_ID;
    END IF;
END@

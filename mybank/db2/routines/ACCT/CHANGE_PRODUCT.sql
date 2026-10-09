-- Switches an account to another product of the same type and re-rates it: new overdraft
-- limit per the target product, interest at the new product's tiers from the next accrual.
-- Called by the app. OUT: old and new credit interest rates at today's balance.
-- Raises 75002/75003 account, 75008 unknown product, 75009 rule (type/GL mismatch, age,
-- withdrawn product, cooling-off period, overdrawn onto a no-overdraft product).
CREATE OR REPLACE PROCEDURE ACCT.CHANGE_PRODUCT (
    IN  P_ACCOUNT_ID       BIGINT,
    IN  P_NEW_PRODUCT_CODE CHAR(6),
    OUT P_OLD_RATE         DECIMAL(7,4),
    OUT P_NEW_RATE         DECIMAL(7,4),
    OUT P_NEW_OD_LIMIT     DECIMAL(15,2)
)
    LANGUAGE SQL
    SPECIFIC ACCT_CHANGE_PRODUCT
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE    CHAR(5);
    DECLARE V_SQLCODE     INTEGER;
    DECLARE V_MSG         VARCHAR(1000);
    DECLARE V_TEXT        VARCHAR(70);
    DECLARE V_STATUS      CHAR(1);
    DECLARE V_OLD_PRODUCT CHAR(6);
    DECLARE V_OLD_TYPE    CHAR(3);
    DECLARE V_OLD_GL      CHAR(4);
    DECLARE V_BALANCE     DECIMAL(15,2);
    DECLARE V_OD_LIMIT    DECIMAL(15,2);
    DECLARE V_OPENED      DATE;
    DECLARE V_DOB         DATE;
    DECLARE V_CUSTOMER_ID BIGINT;
    DECLARE V_NEW_TYPE    CHAR(3);
    DECLARE V_NEW_GL      CHAR(4);
    DECLARE V_NEW_ACTIVE  CHAR(1);
    DECLARE V_NEW_MIN_AGE SMALLINT;
    DECLARE V_NEW_OD_OK   CHAR(1);
    DECLARE V_NEW_OD_DEF  DECIMAL(15,2);
    DECLARE V_BDATE       DATE;
    DECLARE V_DAYS_OPEN   INTEGER;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.LOG_ERROR('ACCT.CHANGE_PRODUCT', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'ACCOUNT_ID=' || COALESCE(RTRIM(CHAR(P_ACCOUNT_ID)), 'NULL') ||
                            ' NEW=' || COALESCE(P_NEW_PRODUCT_CODE, 'NULL'));
        RESIGNAL;
    END;

    SELECT A.STATUS, A.PRODUCT_CODE, P.PRODUCT_TYPE, P.CONTROL_GL_CODE, A.LEDGER_BALANCE,
           A.OVERDRAFT_LIMIT, A.OPENED_DATE, C.DATE_OF_BIRTH, C.CUSTOMER_ID
      INTO V_STATUS, V_OLD_PRODUCT, V_OLD_TYPE, V_OLD_GL, V_BALANCE,
           V_OD_LIMIT, V_OPENED, V_DOB, V_CUSTOMER_ID
      FROM ACCT.ACCOUNT A
      JOIN REF.PRODUCT P ON P.PRODUCT_CODE = A.PRODUCT_CODE
      JOIN CUST.CUSTOMER C ON C.CUSTOMER_ID = A.PRIMARY_CUSTOMER_ID
     WHERE A.ACCOUNT_ID = P_ACCOUNT_ID
      WITH RS USE AND KEEP UPDATE LOCKS;

    IF V_STATUS IS NULL THEN
        SIGNAL SQLSTATE '75002' SET MESSAGE_TEXT = 'Account not found';
    END IF;
    IF V_STATUS IN ('C', 'F') THEN
        SIGNAL SQLSTATE '75003' SET MESSAGE_TEXT = 'Account is closed or frozen';
    END IF;

    SELECT PRODUCT_TYPE, CONTROL_GL_CODE, ACTIVE, MIN_AGE, OVERDRAFT_ALLOWED, DEFAULT_OD_LIMIT
      INTO V_NEW_TYPE, V_NEW_GL, V_NEW_ACTIVE, V_NEW_MIN_AGE, V_NEW_OD_OK, V_NEW_OD_DEF
      FROM REF.PRODUCT
     WHERE PRODUCT_CODE = P_NEW_PRODUCT_CODE
      WITH UR;

    IF V_NEW_TYPE IS NULL THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Unknown product code';
    END IF;
    IF P_NEW_PRODUCT_CODE = V_OLD_PRODUCT THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Account is already on this product';
    END IF;
    -- Same control GL, or the ledger would need re-classifying between GL accounts
    IF V_NEW_TYPE <> V_OLD_TYPE OR V_NEW_GL <> V_OLD_GL THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Can only switch between products of the same type';
    END IF;
    IF V_NEW_ACTIVE <> 'Y' THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Product is no longer available';
    END IF;

    SET V_BDATE = UTIL.CURRENT_BUSINESS_DATE();

    IF YEAR(V_BDATE - V_DOB) < V_NEW_MIN_AGE THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Customer is under the minimum age for this product';
    END IF;

    -- 30-day cooling-off: no switching a brand-new account
    SET V_DAYS_OPEN = DAYS(V_BDATE) - DAYS(V_OPENED);
    IF V_DAYS_OPEN < 30 THEN
        SET V_TEXT = 'Account opened ' || RTRIM(CHAR(V_DAYS_OPEN)) || ' days ago; switch allowed after 30';
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = V_TEXT;
    END IF;

    -- Overdraft: keep an agreed limit up to the new product's default
    SET P_NEW_OD_LIMIT = CASE WHEN V_NEW_OD_OK <> 'Y' THEN 0
                              WHEN V_OD_LIMIT = 0 THEN V_NEW_OD_DEF
                              WHEN V_OD_LIMIT > V_NEW_OD_DEF THEN V_NEW_OD_DEF
                              ELSE V_OD_LIMIT END;
    IF V_BALANCE < 0 AND -V_BALANCE > P_NEW_OD_LIMIT THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Overdrawn balance exceeds the new product limit';
    END IF;

    SET P_OLD_RATE = UTIL.INTEREST_RATE(V_OLD_PRODUCT, V_BALANCE, V_BDATE);
    SET P_NEW_RATE = UTIL.INTEREST_RATE(P_NEW_PRODUCT_CODE, V_BALANCE, V_BDATE);

    MERGE INTO ACCT.ACCOUNT T
    USING (SELECT P.PRODUCT_CODE, P_NEW_OD_LIMIT AS OD_LIMIT
             FROM REF.PRODUCT P
            WHERE P.PRODUCT_CODE = P_NEW_PRODUCT_CODE) S
       ON T.ACCOUNT_ID = P_ACCOUNT_ID
    WHEN MATCHED THEN
        UPDATE SET PRODUCT_CODE    = S.PRODUCT_CODE,
                   OVERDRAFT_LIMIT = S.OD_LIMIT;

    CALL UTIL.WRITE_AUDIT('ACCT.ACCOUNT', RTRIM(CHAR(P_ACCOUNT_ID)), 'U',
                          'Product switch ' || V_OLD_PRODUCT || '->' || P_NEW_PRODUCT_CODE ||
                          ' rate ' || VARCHAR(P_OLD_RATE) || '->' || VARCHAR(P_NEW_RATE) ||
                          ' effective ' || CHAR(V_BDATE, ISO));

    CALL UTIL.ENQUEUE_NOTIFICATION(V_CUSTOMER_ID, 'PRODUCT_CHANGED',
                                   '{"accountId":' || RTRIM(CHAR(P_ACCOUNT_ID)) ||
                                   ',"product":"' || P_NEW_PRODUCT_CODE || '"' ||
                                   ',"rate":' || VARCHAR(P_NEW_RATE) || '}');
END@

-- Opens a current or savings account for an existing customer, with an optional
-- cash opening deposit. Called by the app (branch and digital). Loans open via LOAN.
-- Raises 75004 customer not found, 75008 bad product/branch/amount, 75009 rule (age, KYC,
-- product withdrawn), 75011 generated number failed modulus check.
CREATE OR REPLACE PROCEDURE ACCT.OPEN_ACCOUNT (
    IN  P_CUSTOMER_ID     BIGINT,
    IN  P_PRODUCT_CODE    CHAR(6),
    IN  P_BRANCH_ID       SMALLINT,
    IN  P_ACCOUNT_NAME    VARCHAR(60),
    IN  P_OPENING_DEPOSIT DECIMAL(15,2),
    OUT P_ACCOUNT_ID      BIGINT,
    OUT P_SORT_CODE       CHAR(6),
    OUT P_ACCOUNT_NO      CHAR(8)
)
    LANGUAGE SQL
    SPECIFIC ACCT_OPEN_ACCOUNT
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE     CHAR(5);
    DECLARE V_SQLCODE      INTEGER;
    DECLARE V_MSG          VARCHAR(1000);
    DECLARE V_TEXT         VARCHAR(70);
    DECLARE V_CUST_STATUS  CHAR(1);
    DECLARE V_KYC_STATUS   CHAR(1);
    DECLARE V_DOB          DATE;
    DECLARE V_TITLE        VARCHAR(10);
    DECLARE V_FIRST_NAME   VARCHAR(50);
    DECLARE V_LAST_NAME    VARCHAR(50);
    DECLARE V_HOME_BRANCH  SMALLINT;
    DECLARE V_BRANCH_ID    SMALLINT;
    DECLARE V_BRANCH_CLOSED DATE;
    DECLARE V_PRODUCT_TYPE CHAR(3);
    DECLARE V_PRODUCT_NAME VARCHAR(60);
    DECLARE V_ACTIVE       CHAR(1);
    DECLARE V_WITHDRAWN    DATE;
    DECLARE V_MIN_AGE      SMALLINT;
    DECLARE V_OD_ALLOWED   CHAR(1);
    DECLARE V_OD_LIMIT     DECIMAL(15,2);
    DECLARE V_BASE         CHAR(7);
    DECLARE V_OPEN_DATE    DATE;
    DECLARE V_TXN_ID       BIGINT;
    DECLARE V_BALANCE      DECIMAL(15,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.LOG_ERROR('ACCT.OPEN_ACCOUNT', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'CUSTOMER_ID=' || COALESCE(RTRIM(CHAR(P_CUSTOMER_ID)), 'NULL') ||
                            ' PRODUCT=' || COALESCE(P_PRODUCT_CODE, 'NULL'));
        RESIGNAL;
    END;

    SET P_ACCOUNT_ID = NULL;
    SET P_SORT_CODE  = NULL;
    SET P_ACCOUNT_NO = NULL;

    -- Customer
    SELECT STATUS, KYC_STATUS, DATE_OF_BIRTH, TITLE, FIRST_NAME, LAST_NAME, HOME_BRANCH_ID
      INTO V_CUST_STATUS, V_KYC_STATUS, V_DOB, V_TITLE, V_FIRST_NAME, V_LAST_NAME, V_HOME_BRANCH
      FROM CUST.CUSTOMER
     WHERE CUSTOMER_ID = P_CUSTOMER_ID
      WITH CS;

    IF V_CUST_STATUS IS NULL THEN
        SIGNAL SQLSTATE '75004' SET MESSAGE_TEXT = 'Customer not found';
    END IF;
    IF V_CUST_STATUS = 'C' THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Customer is closed';
    END IF;
    IF V_KYC_STATUS = 'F' THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Customer has failed KYC';
    END IF;

    -- Product
    SELECT PRODUCT_TYPE, NAME, ACTIVE, WITHDRAWN_DATE, MIN_AGE, OVERDRAFT_ALLOWED, DEFAULT_OD_LIMIT
      INTO V_PRODUCT_TYPE, V_PRODUCT_NAME, V_ACTIVE, V_WITHDRAWN, V_MIN_AGE, V_OD_ALLOWED, V_OD_LIMIT
      FROM REF.PRODUCT
     WHERE PRODUCT_CODE = P_PRODUCT_CODE
      WITH UR;

    IF V_PRODUCT_TYPE IS NULL THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Unknown product code';
    END IF;
    IF V_PRODUCT_TYPE = 'LON' THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Loan accounts are opened by loan origination';
    END IF;

    SET V_OPEN_DATE = UTIL.POSTING_DATE();

    IF V_ACTIVE <> 'Y' OR (V_WITHDRAWN IS NOT NULL AND V_WITHDRAWN < V_OPEN_DATE) THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Product is no longer available';
    END IF;
    IF YEAR(V_OPEN_DATE - V_DOB) < V_MIN_AGE THEN
        SET V_TEXT = 'Customer is under the minimum age of ' || RTRIM(CHAR(V_MIN_AGE)) || ' for this product';
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = V_TEXT;
    END IF;

    IF P_OPENING_DEPOSIT < 0 THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Opening deposit cannot be negative';
    END IF;

    -- Branch (defaults to the customer's home branch) gives the sort code
    SET V_BRANCH_ID = COALESCE(P_BRANCH_ID, V_HOME_BRANCH);
    SELECT SORT_CODE, CLOSED_DATE
      INTO P_SORT_CODE, V_BRANCH_CLOSED
      FROM REF.BRANCH
     WHERE BRANCH_ID = V_BRANCH_ID
      WITH UR;

    IF P_SORT_CODE IS NULL THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Unknown branch';
    END IF;
    IF V_BRANCH_CLOSED IS NOT NULL THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Branch is closed';
    END IF;

    -- Account number: 7-digit base from the sequence plus check digit
    SET V_BASE = RTRIM(CHAR(NEXT VALUE FOR ACCT.SEQ_ACCOUNT_NO));
    SET P_ACCOUNT_NO = V_BASE || UTIL.ACCOUNT_CHECK_DIGIT(V_BASE);

    IF UTIL.MODULUS_CHECK(P_SORT_CODE, P_ACCOUNT_NO) <> 1 THEN
        SIGNAL SQLSTATE '75011' SET MESSAGE_TEXT = 'Generated account number failed modulus check';
    END IF;

    SELECT ACCOUNT_ID
      INTO P_ACCOUNT_ID
      FROM FINAL TABLE (INSERT INTO ACCT.ACCOUNT
                            (SORT_CODE, ACCOUNT_NO, PRODUCT_CODE, BRANCH_ID, PRIMARY_CUSTOMER_ID,
                             ACCOUNT_NAME, STATUS, OVERDRAFT_LIMIT, LAST_ACCRUAL_DATE,
                             LAST_ACTIVITY_DATE, OPENED_DATE)
                        VALUES
                            (P_SORT_CODE, P_ACCOUNT_NO, P_PRODUCT_CODE, V_BRANCH_ID, P_CUSTOMER_ID,
                             COALESCE(NULLIF(RTRIM(P_ACCOUNT_NAME), ''),
                                      UPPER(COALESCE(V_TITLE || ' ', '') ||
                                            SUBSTR(V_FIRST_NAME, 1, 1) || ' ' || V_LAST_NAME)),
                             'A',
                             CASE WHEN V_OD_ALLOWED = 'Y' THEN V_OD_LIMIT ELSE 0 END,
                             V_OPEN_DATE, V_OPEN_DATE, V_OPEN_DATE));

    INSERT INTO ACCT.ACCOUNT_HOLDER (ACCOUNT_ID, CUSTOMER_ID, HOLDER_ROLE, ADDED_DATE)
    VALUES (P_ACCOUNT_ID, P_CUSTOMER_ID, 'P', V_OPEN_DATE);

    IF P_OPENING_DEPOSIT > 0 THEN
        CALL UTIL.POST_LEDGER_ENTRY(P_ACCOUNT_ID, P_OPENING_DEPOSIT, 'CASH', 'Opening deposit',
                                    'OPEN ' || P_ACCOUNT_NO, '1100', NULL, NULL, 'N',
                                    NULL, NULL, NULL, NULL, NULL, V_TXN_ID, V_BALANCE);
    END IF;

    CALL UTIL.WRITE_AUDIT('ACCT.ACCOUNT', RTRIM(CHAR(P_ACCOUNT_ID)), 'I',
                          'Opened ' || P_PRODUCT_CODE || ' ' || P_SORT_CODE || '/' || P_ACCOUNT_NO ||
                          ' for customer ' || RTRIM(CHAR(P_CUSTOMER_ID)));

    CALL UTIL.ENQUEUE_NOTIFICATION(P_CUSTOMER_ID, 'ACCOUNT_OPENED',
                                   '{"product":"' || RTRIM(V_PRODUCT_NAME) || '","sortCode":"' ||
                                   UTIL.FORMAT_SORT_CODE(P_SORT_CODE) || '","accountNo":"' ||
                                   P_ACCOUNT_NO || '"}');
END@

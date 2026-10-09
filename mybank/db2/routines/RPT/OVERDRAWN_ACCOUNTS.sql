-- Reports page: overdrawn current/savings accounts (RS1, worst unarranged first) and a summary
-- by product (RS2). P_MIN_OVERDRAWN filters small balances; P_UNARRANGED_ONLY = 'Y' shows only
-- accounts over their arranged limit. Raises 75008 on a bad argument.
CREATE OR REPLACE PROCEDURE RPT.OVERDRAWN_ACCOUNTS (
    IN P_MIN_OVERDRAWN   DECIMAL(15,2) DEFAULT 0,
    IN P_UNARRANGED_ONLY CHAR(1)       DEFAULT 'N',
    IN P_BRANCH_ID       SMALLINT      DEFAULT NULL
)
    LANGUAGE SQL
    SPECIFIC RPT_OVERDRAWN_ACCOUNTS
    DYNAMIC RESULT SETS 2
    READS SQL DATA
BEGIN
    DECLARE V_TODAY      DATE;
    DECLARE V_MIN        DECIMAL(15,2);
    DECLARE V_UNARRANGED CHAR(1);

    DECLARE C_ACCOUNTS CURSOR WITH RETURN TO CLIENT FOR
        SELECT UTIL.FORMAT_SORT_CODE(A.SORT_CODE)                          AS SORT_CODE,
               A.ACCOUNT_NO,
               A.ACCOUNT_NAME,
               A.PRODUCT_CODE,
               C.CUSTOMER_NO,
               RTRIM(COALESCE(C.TITLE || ' ', '') || C.FIRST_NAME || ' ' || C.LAST_NAME) AS CUSTOMER_NAME,
               A.STATUS,
               A.LEDGER_BALANCE,
               A.OVERDRAFT_LIMIT,
               CASE WHEN -A.LEDGER_BALANCE > A.OVERDRAFT_LIMIT
                    THEN -A.LEDGER_BALANCE - A.OVERDRAFT_LIMIT ELSE 0 END  AS UNARRANGED_AMOUNT,
               UTIL.AVAILABLE_BALANCE(A.ACCOUNT_ID)                        AS AVAILABLE_BALANCE,
               DECIMAL(ROUND(A.ACCRUED_INTEREST, 2), 15, 2)                AS ACCRUED_INTEREST,
               OD.OVERDRAWN_SINCE,
               DAYS(V_TODAY) - DAYS(OD.OVERDRAWN_SINCE)                    AS DAYS_OVERDRAWN,
               A.LAST_ACTIVITY_DATE
          FROM ACCT.ACCOUNT A
          JOIN REF.PRODUCT P   ON P.PRODUCT_CODE = A.PRODUCT_CODE
          JOIN CUST.CUSTOMER C ON C.CUSTOMER_ID = A.PRIMARY_CUSTOMER_ID,
               -- first posting after the last time the balance was in credit; accounts whose
               -- history has been purged fall back to the opening date
               TABLE (SELECT COALESCE(MIN(T.BUSINESS_DATE), A.OPENED_DATE) AS OVERDRAWN_SINCE
                        FROM TXN.POSTED_TXN T
                       WHERE T.ACCOUNT_ID = A.ACCOUNT_ID
                         AND T.TXN_ID > COALESCE((SELECT MAX(T2.TXN_ID)
                                                    FROM TXN.POSTED_TXN T2
                                                   WHERE T2.ACCOUNT_ID = A.ACCOUNT_ID
                                                     AND T2.BALANCE_AFTER >= 0), 0)) AS OD
         WHERE A.LEDGER_BALANCE < 0
           AND A.STATUS <> 'C'
           AND P.PRODUCT_TYPE IN ('CUR', 'SAV')
           AND -A.LEDGER_BALANCE >= V_MIN
           AND (V_UNARRANGED = 'N' OR -A.LEDGER_BALANCE > A.OVERDRAFT_LIMIT)
           AND (P_BRANCH_ID IS NULL OR A.BRANCH_ID = P_BRANCH_ID)
         ORDER BY UNARRANGED_AMOUNT DESC, A.LEDGER_BALANCE, A.ACCOUNT_NO
          WITH UR;

    DECLARE C_BY_PRODUCT CURSOR WITH RETURN TO CLIENT FOR
        SELECT P.PRODUCT_CODE,
               P.NAME                                                      AS PRODUCT_NAME,
               COUNT(*)                                                    AS OVERDRAWN_ACCOUNTS,
               SUM(CASE WHEN -A.LEDGER_BALANCE > A.OVERDRAFT_LIMIT THEN 1 ELSE 0 END) AS UNARRANGED_ACCOUNTS,
               SUM(-A.LEDGER_BALANCE)                                      AS TOTAL_OVERDRAWN,
               SUM(CASE WHEN -A.LEDGER_BALANCE > A.OVERDRAFT_LIMIT
                        THEN -A.LEDGER_BALANCE - A.OVERDRAFT_LIMIT ELSE 0 END) AS TOTAL_UNARRANGED,
               DECIMAL(AVG(-A.LEDGER_BALANCE), 15, 2)                      AS AVG_OVERDRAWN,
               MAX(-A.LEDGER_BALANCE)                                      AS MAX_OVERDRAWN,
               P.OD_RATE
          FROM ACCT.ACCOUNT A
          JOIN REF.PRODUCT P ON P.PRODUCT_CODE = A.PRODUCT_CODE
         WHERE A.LEDGER_BALANCE < 0
           AND A.STATUS <> 'C'
           AND P.PRODUCT_TYPE IN ('CUR', 'SAV')
           AND -A.LEDGER_BALANCE >= V_MIN
           AND (V_UNARRANGED = 'N' OR -A.LEDGER_BALANCE > A.OVERDRAFT_LIMIT)
           AND (P_BRANCH_ID IS NULL OR A.BRANCH_ID = P_BRANCH_ID)
         GROUP BY P.PRODUCT_CODE, P.NAME, P.OD_RATE
         ORDER BY TOTAL_OVERDRAWN DESC
          WITH UR;

    SET V_MIN = COALESCE(P_MIN_OVERDRAWN, 0);
    SET V_UNARRANGED = COALESCE(UPPER(P_UNARRANGED_ONLY), 'N');

    IF V_MIN < 0 OR V_UNARRANGED NOT IN ('Y', 'N') THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Invalid overdrawn report arguments';
    END IF;

    SET V_TODAY = UTIL.CURRENT_BUSINESS_DATE();

    OPEN C_ACCOUNTS;
    OPEN C_BY_PRODUCT;
END@

-- Reports page: dormant accounts (status D, or no customer activity for P_MIN_DAYS_INACTIVE days)
-- with all holders listed (RS1), and a per-branch summary (RS2). Written against the old
-- MYBANK.ACCOUNTS / MYBANK.CUSTOMERS aliases. Raises 75008 on a bad argument.
CREATE OR REPLACE PROCEDURE RPT.DORMANT_ACCOUNTS (
    IN P_MIN_DAYS_INACTIVE INTEGER  DEFAULT 365,
    IN P_BRANCH_ID         SMALLINT DEFAULT NULL
)
    LANGUAGE SQL
    SPECIFIC RPT_DORMANT_ACCOUNTS
    DYNAMIC RESULT SETS 2
    READS SQL DATA
BEGIN
    DECLARE V_TODAY    DATE;
    DECLARE V_MIN_DAYS INTEGER;

    DECLARE C_ACCOUNTS CURSOR WITH RETURN TO CLIENT FOR
        SELECT B.NAME                                                      AS BRANCH_NAME,
               UTIL.FORMAT_SORT_CODE(A.SORT_CODE)                          AS SORT_CODE,
               A.ACCOUNT_NO,
               A.ACCOUNT_NAME,
               A.PRODUCT_CODE,
               A.STATUS,
               A.LEDGER_BALANCE,
               A.OPENED_DATE,
               A.LAST_ACTIVITY_DATE,
               DAYS(V_TODAY) - DAYS(COALESCE(A.LAST_ACTIVITY_DATE, A.OPENED_DATE)) AS DAYS_INACTIVE,
               COUNT(C.CUSTOMER_ID)                                        AS HOLDER_COUNT,
               LISTAGG(RTRIM(COALESCE(C.TITLE || ' ', '') || C.FIRST_NAME || ' ' || C.LAST_NAME)
                       || ' (' || C.CUSTOMER_NO || ')', '; ')
                   WITHIN GROUP (ORDER BY H.HOLDER_ROLE DESC, C.LAST_NAME, C.FIRST_NAME) AS HOLDERS
          FROM MYBANK.ACCOUNTS A
          JOIN REF.BRANCH B ON B.BRANCH_ID = A.BRANCH_ID
          LEFT JOIN ACCT.ACCOUNT_HOLDER H ON H.ACCOUNT_ID = A.ACCOUNT_ID
          LEFT JOIN MYBANK.CUSTOMERS C ON C.CUSTOMER_ID = H.CUSTOMER_ID
         WHERE A.STATUS IN ('A', 'D')
           AND A.PRODUCT_CODE NOT LIKE 'LON%'
           AND (A.STATUS = 'D'
                OR DAYS(V_TODAY) - DAYS(COALESCE(A.LAST_ACTIVITY_DATE, A.OPENED_DATE)) >= V_MIN_DAYS)
           AND (P_BRANCH_ID IS NULL OR A.BRANCH_ID = P_BRANCH_ID)
         GROUP BY B.NAME, A.SORT_CODE, A.ACCOUNT_NO, A.ACCOUNT_NAME, A.PRODUCT_CODE, A.STATUS,
                  A.LEDGER_BALANCE, A.OPENED_DATE, A.LAST_ACTIVITY_DATE
         ORDER BY DAYS_INACTIVE DESC, A.LEDGER_BALANCE DESC
          WITH UR;

    DECLARE C_BY_BRANCH CURSOR WITH RETURN TO CLIENT FOR
        SELECT B.BRANCH_ID,
               B.NAME                                                      AS BRANCH_NAME,
               B.REGION,
               COUNT(*)                                                    AS DORMANT_ACCOUNTS,
               SUM(CASE WHEN A.STATUS = 'D' THEN 1 ELSE 0 END)             AS FLAGGED_D,
               SUM(A.LEDGER_BALANCE)                                       AS TOTAL_BALANCE,
               MAX(A.LEDGER_BALANCE)                                       AS LARGEST_BALANCE,
               -- 15+ years dormant with a balance goes to the Reclaim Fund
               SUM(CASE WHEN COALESCE(A.LAST_ACTIVITY_DATE, A.OPENED_DATE) < V_TODAY - 15 YEARS
                        THEN 1 ELSE 0 END)                                 AS RECLAIM_FUND_ELIGIBLE,
               LISTAGG(DISTINCT A.PRODUCT_CODE, ', ') WITHIN GROUP (ORDER BY A.PRODUCT_CODE) AS PRODUCTS
          FROM MYBANK.ACCOUNTS A
          JOIN REF.BRANCH B ON B.BRANCH_ID = A.BRANCH_ID
         WHERE A.STATUS IN ('A', 'D')
           AND A.PRODUCT_CODE NOT LIKE 'LON%'
           AND (A.STATUS = 'D'
                OR DAYS(V_TODAY) - DAYS(COALESCE(A.LAST_ACTIVITY_DATE, A.OPENED_DATE)) >= V_MIN_DAYS)
           AND (P_BRANCH_ID IS NULL OR A.BRANCH_ID = P_BRANCH_ID)
         GROUP BY B.BRANCH_ID, B.NAME, B.REGION
         ORDER BY DORMANT_ACCOUNTS DESC, B.BRANCH_ID
          WITH UR;

    SET V_MIN_DAYS = COALESCE(P_MIN_DAYS_INACTIVE, 365);
    IF V_MIN_DAYS < 30 THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Minimum days inactive must be 30 or more';
    END IF;

    SET V_TODAY = UTIL.CURRENT_BUSINESS_DATE();

    OPEN C_ACCOUNTS;
    OPEN C_BY_BRANCH;
END@

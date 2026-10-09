-- Reports page: branch scorecard. One result set with GROUPING SETS rows per branch, per region,
-- per product type and bank total (REPORT_LEVEL says which). Balances are as at now; activity
-- is for the date range (default last 20 business days). Raises 75008 on a bad date range.
CREATE OR REPLACE PROCEDURE RPT.BRANCH_PERFORMANCE (
    IN P_FROM_DATE DATE DEFAULT NULL,
    IN P_TO_DATE   DATE DEFAULT NULL
)
    LANGUAGE SQL
    SPECIFIC RPT_BRANCH_PERFORMANCE
    DYNAMIC RESULT SETS 1
    READS SQL DATA
BEGIN
    DECLARE V_FROM_DATE DATE;
    DECLARE V_TO_DATE   DATE;
    DECLARE V_DAYS      INTEGER DEFAULT 1;
    DECLARE V_HOLIDAY   INTEGER DEFAULT 0;

    DECLARE C_BRANCHES CURSOR WITH RETURN TO CLIENT FOR
        WITH ACTIVITY (ACCOUNT_ID, TXN_COUNT, TOTAL_IN, TOTAL_OUT) AS (
            SELECT T.ACCOUNT_ID,
                   COUNT(*),
                   SUM(CASE WHEN T.AMOUNT > 0 THEN T.AMOUNT ELSE 0 END),
                   SUM(CASE WHEN T.AMOUNT < 0 THEN -T.AMOUNT ELSE 0 END)
              FROM TXN.POSTED_TXN T
             WHERE T.BUSINESS_DATE BETWEEN V_FROM_DATE AND V_TO_DATE
             GROUP BY T.ACCOUNT_ID
        )
        SELECT CASE WHEN GROUPING(B.BRANCH_ID) = 0    THEN 'BRANCH'
                    WHEN GROUPING(B.REGION) = 0       THEN 'REGION'
                    WHEN GROUPING(P.PRODUCT_TYPE) = 0 THEN 'PRODUCT'
                    ELSE 'BANK' END                                        AS REPORT_LEVEL,
               GROUPING(B.REGION)                                          AS G_REGION,
               GROUPING(B.BRANCH_ID)                                       AS G_BRANCH,
               GROUPING(P.PRODUCT_TYPE)                                    AS G_PRODUCT,
               B.REGION,
               B.BRANCH_ID,
               B.NAME                                                      AS BRANCH_NAME,
               CASE WHEN GROUPING(B.SORT_CODE) = 0
                    THEN UTIL.FORMAT_SORT_CODE(B.SORT_CODE) END            AS SORT_CODE,
               P.PRODUCT_TYPE,
               COUNT(*)                                                    AS OPEN_ACCOUNTS,
               SUM(CASE WHEN A.OPENED_DATE BETWEEN V_FROM_DATE AND V_TO_DATE
                        THEN 1 ELSE 0 END)                                 AS NEW_ACCOUNTS,
               SUM(CASE WHEN A.STATUS = 'D' THEN 1 ELSE 0 END)             AS DORMANT_ACCOUNTS,
               SUM(CASE WHEN A.LEDGER_BALANCE > 0 THEN A.LEDGER_BALANCE ELSE 0 END)  AS DEPOSITS,
               SUM(CASE WHEN A.LEDGER_BALANCE < 0 THEN -A.LEDGER_BALANCE ELSE 0 END) AS LENDING,
               SUM(COALESCE(X.TXN_COUNT, 0))                               AS TXN_COUNT,
               SUM(COALESCE(X.TOTAL_IN, 0))                                AS TOTAL_IN,
               SUM(COALESCE(X.TOTAL_OUT, 0))                               AS TOTAL_OUT,
               RANK() OVER (PARTITION BY GROUPING(B.BRANCH_ID), GROUPING(B.REGION), GROUPING(P.PRODUCT_TYPE)
                            ORDER BY SUM(CASE WHEN A.LEDGER_BALANCE > 0 THEN A.LEDGER_BALANCE ELSE 0 END) DESC)
                                                                           AS DEPOSIT_RANK
          FROM ACCT.ACCOUNT A
          JOIN REF.BRANCH B  ON B.BRANCH_ID = A.BRANCH_ID
          JOIN REF.PRODUCT P ON P.PRODUCT_CODE = A.PRODUCT_CODE
          LEFT JOIN ACTIVITY X ON X.ACCOUNT_ID = A.ACCOUNT_ID
         WHERE A.STATUS <> 'C'
         GROUP BY GROUPING SETS ((B.REGION, B.BRANCH_ID, B.NAME, B.SORT_CODE),
                                 (B.REGION),
                                 (P.PRODUCT_TYPE),
                                 ())
         ORDER BY CASE WHEN GROUPING(B.BRANCH_ID) = 0 THEN 1
                       WHEN GROUPING(B.REGION) = 0 THEN 2
                       WHEN GROUPING(P.PRODUCT_TYPE) = 0 THEN 3
                       ELSE 4 END,
                  B.REGION, B.BRANCH_ID, P.PRODUCT_TYPE
          WITH UR;

    SET V_TO_DATE = COALESCE(P_TO_DATE, UTIL.CURRENT_BUSINESS_DATE());

    IF P_FROM_DATE IS NOT NULL THEN
        SET V_FROM_DATE = P_FROM_DATE;
    ELSE
        SET V_FROM_DATE = V_TO_DATE;
        BACK_LOOP:
        WHILE V_DAYS < 20 DO
            SET V_FROM_DATE = V_FROM_DATE - 1 DAY;
            SELECT COUNT(*) INTO V_HOLIDAY FROM REF.HOLIDAY WHERE HOLIDAY_DATE = V_FROM_DATE;
            IF DAYOFWEEK_ISO(V_FROM_DATE) < 6 AND V_HOLIDAY = 0 THEN
                SET V_DAYS = V_DAYS + 1;
            END IF;
        END WHILE BACK_LOOP;
    END IF;

    IF V_FROM_DATE > V_TO_DATE THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'From date is after to date';
    END IF;

    OPEN C_BRANCHES;
END@

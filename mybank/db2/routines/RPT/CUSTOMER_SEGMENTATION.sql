-- Reports page: active customers ranked into value buckets by net relationship balance.
-- RS1 summarises each NTILE bucket; RS2 lists customers whose recorded SEGMENT doesn't match
-- the value-based one (reclassification candidates, top 200). Raises 75008 on bad arguments.
CREATE OR REPLACE PROCEDURE RPT.CUSTOMER_SEGMENTATION (
    IN P_SEGMENT CHAR(3)  DEFAULT NULL,
    IN P_BUCKETS SMALLINT DEFAULT 10
)
    LANGUAGE SQL
    SPECIFIC RPT_CUSTOMER_SEGMENTATION
    DYNAMIC RESULT SETS 2
    READS SQL DATA
BEGIN
    DECLARE V_TODAY   DATE;
    DECLARE V_BUCKETS SMALLINT;

    DECLARE C_BUCKETS CURSOR WITH RETURN TO CLIENT FOR
        WITH REL (CUSTOMER_ID, SEGMENT, DATE_OF_BIRTH, ACCOUNTS, PRODUCT_TYPES, DEPOSITS, BORROWING) AS (
            SELECT C.CUSTOMER_ID, C.SEGMENT, C.DATE_OF_BIRTH,
                   COUNT(DISTINCT A.ACCOUNT_ID),
                   COUNT(DISTINCT P.PRODUCT_TYPE),
                   SUM(CASE WHEN A.LEDGER_BALANCE > 0 THEN A.LEDGER_BALANCE ELSE 0 END),
                   SUM(CASE WHEN A.LEDGER_BALANCE < 0 THEN -A.LEDGER_BALANCE ELSE 0 END)
              FROM CUST.CUSTOMER C
              JOIN ACCT.ACCOUNT_HOLDER H ON H.CUSTOMER_ID = C.CUSTOMER_ID
              JOIN ACCT.ACCOUNT A        ON A.ACCOUNT_ID = H.ACCOUNT_ID AND A.STATUS <> 'C'
              JOIN REF.PRODUCT P         ON P.PRODUCT_CODE = A.PRODUCT_CODE
             WHERE C.STATUS = 'A'
               AND (P_SEGMENT IS NULL OR C.SEGMENT = P_SEGMENT)
             GROUP BY C.CUSTOMER_ID, C.SEGMENT, C.DATE_OF_BIRTH
        ),
        ACTIVITY (CUSTOMER_ID, TXN_COUNT) AS (
            SELECT H.CUSTOMER_ID, COUNT(*)
              FROM TXN.POSTED_TXN T
              JOIN ACCT.ACCOUNT_HOLDER H ON H.ACCOUNT_ID = T.ACCOUNT_ID
             WHERE T.BUSINESS_DATE > V_TODAY - 30 DAYS
               AND T.TXN_TYPE NOT IN ('INT', 'FEE')
             GROUP BY H.CUSTOMER_ID
        ),
        SCORED AS (
            SELECT R.*,
                   R.DEPOSITS - R.BORROWING                                AS NET_POSITION,
                   COALESCE(X.TXN_COUNT, 0)                                AS TXN_COUNT_30D,
                   YEAR(V_TODAY - R.DATE_OF_BIRTH)                         AS AGE,
                   NTILE(V_BUCKETS) OVER (ORDER BY R.DEPOSITS - R.BORROWING) AS VALUE_BUCKET
              FROM REL R
              LEFT JOIN ACTIVITY X ON X.CUSTOMER_ID = R.CUSTOMER_ID
        )
        SELECT S.VALUE_BUCKET,
               COUNT(*)                                                    AS CUSTOMERS,
               MIN(S.NET_POSITION)                                         AS MIN_NET_POSITION,
               MAX(S.NET_POSITION)                                         AS MAX_NET_POSITION,
               DECIMAL(AVG(S.NET_POSITION), 15, 2)                         AS AVG_NET_POSITION,
               SUM(S.DEPOSITS)                                             AS TOTAL_DEPOSITS,
               SUM(S.BORROWING)                                            AS TOTAL_BORROWING,
               DECIMAL(AVG(DECIMAL(S.ACCOUNTS, 7, 2)), 7, 2)               AS AVG_ACCOUNTS,
               DECIMAL(AVG(DECIMAL(S.TXN_COUNT_30D, 9, 2)), 9, 1)          AS AVG_TXNS_30D,
               INT(AVG(S.AGE))                                             AS AVG_AGE,
               SUM(CASE WHEN S.SEGMENT = 'MAS' THEN 1 ELSE 0 END)          AS SEG_MAS,
               SUM(CASE WHEN S.SEGMENT = 'AFF' THEN 1 ELSE 0 END)          AS SEG_AFF,
               SUM(CASE WHEN S.SEGMENT = 'PRM' THEN 1 ELSE 0 END)          AS SEG_PRM,
               SUM(CASE WHEN S.SEGMENT = 'STU' THEN 1 ELSE 0 END)          AS SEG_STU,
               SUM(CASE WHEN S.SEGMENT = 'SME' THEN 1 ELSE 0 END)          AS SEG_SME
          FROM SCORED S
         GROUP BY S.VALUE_BUCKET
         ORDER BY S.VALUE_BUCKET DESC
          WITH UR;

    DECLARE C_CANDIDATES CURSOR WITH RETURN TO CLIENT FOR
        WITH REL (CUSTOMER_ID, CUSTOMER_NO, FULL_NAME, SEGMENT, DATE_OF_BIRTH, DEPOSITS, BORROWING) AS (
            SELECT C.CUSTOMER_ID, C.CUSTOMER_NO, C.FIRST_NAME || ' ' || C.LAST_NAME, C.SEGMENT, C.DATE_OF_BIRTH,
                   SUM(CASE WHEN A.LEDGER_BALANCE > 0 THEN A.LEDGER_BALANCE ELSE 0 END),
                   SUM(CASE WHEN A.LEDGER_BALANCE < 0 THEN -A.LEDGER_BALANCE ELSE 0 END)
              FROM CUST.CUSTOMER C
              JOIN ACCT.ACCOUNT_HOLDER H ON H.CUSTOMER_ID = C.CUSTOMER_ID
              JOIN ACCT.ACCOUNT A        ON A.ACCOUNT_ID = H.ACCOUNT_ID AND A.STATUS <> 'C'
             WHERE C.STATUS = 'A'
               AND C.SEGMENT <> 'SME'
               AND (P_SEGMENT IS NULL OR C.SEGMENT = P_SEGMENT)
             GROUP BY C.CUSTOMER_ID, C.CUSTOMER_NO, C.FIRST_NAME, C.LAST_NAME, C.SEGMENT, C.DATE_OF_BIRTH
        ),
        SUGGESTED AS (
            SELECT R.*,
                   R.DEPOSITS - R.BORROWING                                AS NET_POSITION,
                   YEAR(V_TODAY - R.DATE_OF_BIRTH)                         AS AGE,
                   NTILE(V_BUCKETS) OVER (ORDER BY R.DEPOSITS - R.BORROWING) AS VALUE_BUCKET,
                   -- thresholds as agreed with Marketing, 2016. Not in a table.
                   CASE WHEN R.DEPOSITS - R.BORROWING >= 75000 THEN 'PRM'
                        WHEN R.DEPOSITS - R.BORROWING >= 20000 THEN 'AFF'
                        WHEN YEAR(V_TODAY - R.DATE_OF_BIRTH) < 24 THEN 'STU'
                        ELSE 'MAS' END                                     AS SUGGESTED_SEGMENT
              FROM REL R
        )
        SELECT S.CUSTOMER_NO,
               S.FULL_NAME,
               S.AGE,
               S.SEGMENT                                                   AS CURRENT_SEGMENT,
               S.SUGGESTED_SEGMENT,
               S.NET_POSITION,
               S.DEPOSITS,
               S.BORROWING,
               S.VALUE_BUCKET
          FROM SUGGESTED S
         WHERE S.SEGMENT <> S.SUGGESTED_SEGMENT
         ORDER BY ABS(S.NET_POSITION) DESC, S.CUSTOMER_NO
         FETCH FIRST 200 ROWS ONLY
          WITH UR;

    SET V_BUCKETS = COALESCE(P_BUCKETS, 10);
    IF V_BUCKETS < 2 OR V_BUCKETS > 100 THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Buckets must be between 2 and 100';
    END IF;
    IF P_SEGMENT IS NOT NULL AND P_SEGMENT NOT IN ('MAS', 'AFF', 'PRM', 'STU', 'SME') THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Unknown customer segment';
    END IF;

    SET V_TODAY = UTIL.CURRENT_BUSINESS_DATE();

    OPEN C_BUCKETS;
    OPEN C_CANDIDATES;
END@

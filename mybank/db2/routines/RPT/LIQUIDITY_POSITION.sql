-- Reports page: daily in/out flows by product type with a running net (RS1) and the current
-- balance position per control GL reconciled to the ledger (RS2). History comes from the
-- RPT.MQT_DAILY_LIQUIDITY summary; today is read live. Defaults to last 10 business days.
CREATE OR REPLACE PROCEDURE RPT.LIQUIDITY_POSITION (
    IN P_FROM_DATE    DATE    DEFAULT NULL,
    IN P_TO_DATE      DATE    DEFAULT NULL,
    IN P_PRODUCT_TYPE CHAR(3) DEFAULT NULL
)
    LANGUAGE SQL
    SPECIFIC RPT_LIQUIDITY_POSITION
    DYNAMIC RESULT SETS 2
    READS SQL DATA
BEGIN
    DECLARE V_FROM_DATE DATE;
    DECLARE V_TO_DATE   DATE;
    DECLARE V_TODAY     DATE;
    DECLARE V_DAYS      INTEGER DEFAULT 1;
    DECLARE V_HOLIDAY   INTEGER DEFAULT 0;

    -- NB: the MQT is REFRESH DEFERRED and only refreshed by BATCH.REFRESH_REPORTING_MQTS, so
    -- today's figures come from POSTED_TXN. Don't SET CURRENT REFRESH AGE ANY in here: the
    -- optimizer would then happily answer the LIVE branch from the stale MQT (it matches).
    DECLARE C_FLOWS CURSOR WITH RETURN TO CLIENT FOR
        WITH FLOWS (BUSINESS_DATE, PRODUCT_TYPE, TXN_COUNT, TOTAL_IN, TOTAL_OUT, SOURCE) AS (
            SELECT L.BUSINESS_DATE, L.PRODUCT_TYPE, SUM(L.TXN_COUNT), SUM(L.TOTAL_IN), SUM(L.TOTAL_OUT), 'MQT'
              FROM RPT.MQT_DAILY_LIQUIDITY L
             WHERE L.BUSINESS_DATE BETWEEN V_FROM_DATE AND V_TO_DATE
               AND L.BUSINESS_DATE < V_TODAY
               AND (P_PRODUCT_TYPE IS NULL OR L.PRODUCT_TYPE = P_PRODUCT_TYPE)
             GROUP BY L.BUSINESS_DATE, L.PRODUCT_TYPE
            UNION ALL
            SELECT T.BUSINESS_DATE, P.PRODUCT_TYPE, COUNT(*),
                   SUM(CASE WHEN T.AMOUNT > 0 THEN T.AMOUNT ELSE 0 END),
                   SUM(CASE WHEN T.AMOUNT < 0 THEN -T.AMOUNT ELSE 0 END),
                   'LIVE'
              FROM TXN.POSTED_TXN T
              JOIN ACCT.ACCOUNT A ON A.ACCOUNT_ID = T.ACCOUNT_ID
              JOIN REF.PRODUCT P  ON P.PRODUCT_CODE = A.PRODUCT_CODE
             WHERE T.BUSINESS_DATE BETWEEN V_FROM_DATE AND V_TO_DATE
               AND T.BUSINESS_DATE >= V_TODAY
               AND (P_PRODUCT_TYPE IS NULL OR P.PRODUCT_TYPE = P_PRODUCT_TYPE)
             GROUP BY T.BUSINESS_DATE, P.PRODUCT_TYPE
        )
        SELECT F.BUSINESS_DATE,
               VARCHAR(DAYNAME(F.BUSINESS_DATE), 9)                        AS DAY_NAME,
               F.PRODUCT_TYPE,
               F.TXN_COUNT,
               F.TOTAL_IN,
               F.TOTAL_OUT,
               F.TOTAL_IN - F.TOTAL_OUT                                    AS NET_FLOW,
               SUM(F.TOTAL_IN - F.TOTAL_OUT) OVER (PARTITION BY F.PRODUCT_TYPE
                                                  ORDER BY F.BUSINESS_DATE
                                                  ROWS UNBOUNDED PRECEDING) AS CUMULATIVE_NET,
               DECIMAL(AVG(F.TOTAL_IN - F.TOTAL_OUT) OVER (PARTITION BY F.PRODUCT_TYPE
                                                          ORDER BY F.BUSINESS_DATE
                                                          ROWS 4 PRECEDING), 15, 2) AS NET_5DAY_AVG,
               F.SOURCE
          FROM FLOWS F
         ORDER BY F.BUSINESS_DATE, F.PRODUCT_TYPE
          WITH UR;

    DECLARE C_POSITION CURSOR WITH RETURN TO CLIENT FOR
        SELECT P.CONTROL_GL_CODE                                           AS GL_CODE,
               G.NAME                                                      AS GL_NAME,
               P.PRODUCT_TYPE,
               COUNT(A.ACCOUNT_ID)                                         AS ACCOUNTS,
               COALESCE(SUM(CASE WHEN A.LEDGER_BALANCE > 0 THEN A.LEDGER_BALANCE END), 0)  AS CREDIT_BALANCES,
               COALESCE(SUM(CASE WHEN A.LEDGER_BALANCE < 0 THEN -A.LEDGER_BALANCE END), 0) AS DEBIT_BALANCES,
               COALESCE(SUM(A.LEDGER_BALANCE), 0)                          AS NET_BALANCE,
               COALESCE(SUM(A.HOLD_AMOUNT), 0)                             AS HOLDS,
               -GB.BALANCE                                                 AS GL_BALANCE,
               COALESCE(SUM(A.LEDGER_BALANCE), 0) + GB.BALANCE             AS DIFFERENCE
          FROM REF.PRODUCT P
          JOIN REF.GL_ACCOUNT G ON G.GL_CODE = P.CONTROL_GL_CODE
          JOIN GL.V_GL_BALANCE GB ON GB.GL_CODE = P.CONTROL_GL_CODE
          LEFT JOIN ACCT.ACCOUNT A ON A.PRODUCT_CODE = P.PRODUCT_CODE
                                  AND A.STATUS <> 'C'
         WHERE (P_PRODUCT_TYPE IS NULL OR P.PRODUCT_TYPE = P_PRODUCT_TYPE)
         GROUP BY P.CONTROL_GL_CODE, G.NAME, P.PRODUCT_TYPE, GB.BALANCE
         ORDER BY P.CONTROL_GL_CODE
          WITH UR;

    SET V_TODAY = UTIL.CURRENT_BUSINESS_DATE();
    SET V_TO_DATE = COALESCE(P_TO_DATE, V_TODAY);

    IF P_FROM_DATE IS NOT NULL THEN
        SET V_FROM_DATE = P_FROM_DATE;
    ELSE
        SET V_FROM_DATE = V_TO_DATE;
        BACK_LOOP:
        WHILE V_DAYS < 10 DO
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

    OPEN C_FLOWS;
    OPEN C_POSITION;
END@

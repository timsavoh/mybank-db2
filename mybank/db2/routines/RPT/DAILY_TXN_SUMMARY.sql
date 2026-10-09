-- Reports page: posted transactions by business date and type, with ROLLUP day subtotals and
-- a grand total (RS1), and a channel breakdown (RS2). Defaults to the last 5 business days.
-- Still reads the old MYBANK.TRANSACTIONS alias from the 2011 report. Raises 75008 bad range.
CREATE OR REPLACE PROCEDURE RPT.DAILY_TXN_SUMMARY (
    IN P_FROM_DATE DATE    DEFAULT NULL,
    IN P_TO_DATE   DATE    DEFAULT NULL,
    IN P_CHANNEL   CHAR(3) DEFAULT NULL
)
    LANGUAGE SQL
    SPECIFIC RPT_DAILY_TXN_SUMMARY
    DYNAMIC RESULT SETS 2
    READS SQL DATA
BEGIN
    DECLARE V_FROM_DATE DATE;
    DECLARE V_TO_DATE   DATE;
    DECLARE V_DAYS      INTEGER DEFAULT 1;
    DECLARE V_HOLIDAY   INTEGER DEFAULT 0;

    DECLARE C_SUMMARY CURSOR WITH RETURN TO CLIENT FOR
        SELECT T.BUSINESS_DATE,
               CASE WHEN GROUPING(T.BUSINESS_DATE) = 1 THEN 'TOTAL'
                    WHEN GROUPING(T.TXN_TYPE) = 1 THEN 'DAY TOTAL'
                    ELSE 'DETAIL' END                                     AS ROW_TYPE,
               CASE WHEN GROUPING(T.BUSINESS_DATE) = 1 THEN 'All dates'
                    ELSE VARCHAR(VARCHAR_FORMAT(T.BUSINESS_DATE, 'Dy DD Mon YYYY'), 16) END AS DAY_LABEL,
               COALESCE(T.TXN_TYPE, '*')                                  AS TXN_TYPE,
               CASE WHEN GROUPING(T.TXN_TYPE) = 1 THEN 'All types'
                    ELSE CASE T.TXN_TYPE
                             WHEN 'CARD' THEN 'Card settlement'
                             WHEN 'FPO'  THEN 'Faster Payment out'
                             WHEN 'FPI'  THEN 'Faster Payment in'
                             WHEN 'XFR'  THEN 'Internal transfer'
                             WHEN 'DD'   THEN 'Direct debit'
                             WHEN 'SO'   THEN 'Standing order'
                             WHEN 'CASH' THEN 'Cash'
                             WHEN 'FEE'  THEN 'Fees'
                             WHEN 'INT'  THEN 'Interest'
                             WHEN 'LOAN' THEN 'Loan'
                             WHEN 'CHQ'  THEN 'Cheque'
                             WHEN 'ADJ'  THEN 'Adjustment'
                             ELSE T.TXN_TYPE END
               END                                                        AS TXN_TYPE_DESC,
               COUNT(*)                                                   AS TXN_COUNT,
               SUM(CASE WHEN T.AMOUNT > 0 THEN 1 ELSE 0 END)              AS CREDIT_COUNT,
               SUM(CASE WHEN T.AMOUNT < 0 THEN 1 ELSE 0 END)              AS DEBIT_COUNT,
               SUM(CASE WHEN T.AMOUNT > 0 THEN T.AMOUNT ELSE 0 END)       AS TOTAL_IN,
               SUM(CASE WHEN T.AMOUNT < 0 THEN -T.AMOUNT ELSE 0 END)      AS TOTAL_OUT,
               SUM(T.AMOUNT)                                              AS NET_AMOUNT,
               DECIMAL(AVG(ABS(T.AMOUNT)), 15, 2)                         AS AVG_AMOUNT
          FROM MYBANK.TRANSACTIONS T
         WHERE T.BUSINESS_DATE BETWEEN V_FROM_DATE AND V_TO_DATE
           AND (P_CHANNEL IS NULL OR T.CHANNEL = P_CHANNEL)
         GROUP BY ROLLUP (T.BUSINESS_DATE, T.TXN_TYPE)
         ORDER BY GROUPING(T.BUSINESS_DATE), T.BUSINESS_DATE, GROUPING(T.TXN_TYPE), T.TXN_TYPE
          WITH UR;

    DECLARE C_CHANNEL CURSOR WITH RETURN TO CLIENT FOR
        SELECT COALESCE(T.CHANNEL, '*')                                   AS CHANNEL,
               CASE WHEN GROUPING(T.CHANNEL) = 1 THEN 'All channels'
                    WHEN T.CHANNEL = 'WEB' THEN 'Internet banking'
                    WHEN T.CHANNEL = 'MOB' THEN 'Mobile app'
                    WHEN T.CHANNEL = 'BRN' THEN 'Branch'
                    WHEN T.CHANNEL = 'API' THEN 'Open banking / scheme'
                    WHEN T.CHANNEL = 'SYS' THEN 'System / batch'
                    ELSE T.CHANNEL END                                    AS CHANNEL_DESC,
               COUNT(*)                                                   AS TXN_COUNT,
               SUM(ABS(T.AMOUNT))                                         AS GROSS_VALUE,
               DECIMAL(100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER () / 2, 0), 5, 1) AS PCT_OF_COUNT
          FROM MYBANK.TRANSACTIONS T
         WHERE T.BUSINESS_DATE BETWEEN V_FROM_DATE AND V_TO_DATE
           AND (P_CHANNEL IS NULL OR T.CHANNEL = P_CHANNEL)
         GROUP BY ROLLUP (T.CHANNEL)
         ORDER BY GROUPING(T.CHANNEL), COUNT(*) DESC
          WITH UR;

    SET V_TO_DATE = COALESCE(P_TO_DATE, UTIL.CURRENT_BUSINESS_DATE());

    IF P_FROM_DATE IS NOT NULL THEN
        SET V_FROM_DATE = P_FROM_DATE;
    ELSE
        -- walk back to the 5th business day (weekends and bank holidays don't count)
        SET V_FROM_DATE = V_TO_DATE;
        BACK_LOOP:
        WHILE V_DAYS < 5 DO
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

    OPEN C_SUMMARY;
    OPEN C_CHANNEL;
END@

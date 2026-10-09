-- Reports page: top merchants by settled card spend (RS1) and spend by merchant category (RS2),
-- read from RPT.MQT_MERCHANT_SPEND (refreshed overnight, so today is not included).
-- Defaults to the last 20 business days, top 20. Raises 75008 on a bad range or P_TOP_N.
CREATE OR REPLACE PROCEDURE RPT.TOP_MERCHANTS (
    IN P_FROM_DATE DATE    DEFAULT NULL,
    IN P_TO_DATE   DATE    DEFAULT NULL,
    IN P_TOP_N     INTEGER DEFAULT 20
)
    LANGUAGE SQL
    SPECIFIC RPT_TOP_MERCHANTS
    DYNAMIC RESULT SETS 2
    READS SQL DATA
BEGIN
    DECLARE V_FROM_DATE DATE;
    DECLARE V_TO_DATE   DATE;
    DECLARE V_TOP_N     INTEGER;
    DECLARE V_DAYS      INTEGER DEFAULT 1;
    DECLARE V_HOLIDAY   INTEGER DEFAULT 0;

    DECLARE C_MERCHANTS CURSOR WITH RETURN TO CLIENT FOR
        WITH SPEND (MERCHANT_ID, TXN_COUNT, TOTAL_SPEND, ACTIVE_DAYS) AS (
            SELECT S.MERCHANT_ID, SUM(S.TXN_COUNT), SUM(S.TOTAL_SPEND), COUNT(*)
              FROM RPT.MQT_MERCHANT_SPEND S
             WHERE S.BUSINESS_DATE BETWEEN V_FROM_DATE AND V_TO_DATE
             GROUP BY S.MERCHANT_ID
        ),
        RANKED AS (
            SELECT SP.MERCHANT_ID,
                   M.NAME                                                      AS MERCHANT_NAME,
                   M.TOWN,
                   M.COUNTRY,
                   M.MCC,
                   COALESCE(C.DESCRIPTION, 'Unknown MCC ' || M.MCC)            AS CATEGORY,
                   SP.TXN_COUNT,
                   SP.TOTAL_SPEND,
                   DECIMAL(SP.TOTAL_SPEND / SP.TXN_COUNT, 15, 2)               AS AVG_TICKET,
                   SP.ACTIVE_DAYS,
                   RANK() OVER (ORDER BY SP.TOTAL_SPEND DESC)                  AS SPEND_RANK,
                   RANK() OVER (ORDER BY SP.TXN_COUNT DESC)                    AS VOLUME_RANK,
                   RANK() OVER (PARTITION BY M.MCC ORDER BY SP.TOTAL_SPEND DESC) AS RANK_IN_CATEGORY,
                   DECIMAL(100E0 * SP.TOTAL_SPEND
                           / NULLIF(SUM(SP.TOTAL_SPEND) OVER (), 0), 5, 2)     AS PCT_OF_SPEND
              FROM SPEND SP
              JOIN CARD.MERCHANT M ON M.MERCHANT_ID = SP.MERCHANT_ID
              LEFT JOIN REF.MERCHANT_CATEGORY C ON C.MCC = M.MCC
        )
        SELECT R.SPEND_RANK, R.MERCHANT_ID, R.MERCHANT_NAME, R.TOWN, R.COUNTRY, R.MCC, R.CATEGORY,
               R.TXN_COUNT, R.TOTAL_SPEND, R.AVG_TICKET, R.PCT_OF_SPEND,
               R.VOLUME_RANK, R.RANK_IN_CATEGORY, R.ACTIVE_DAYS
          FROM RANKED R
         WHERE R.SPEND_RANK <= V_TOP_N
         ORDER BY R.SPEND_RANK, R.MERCHANT_NAME
          WITH UR;

    DECLARE C_CATEGORIES CURSOR WITH RETURN TO CLIENT FOR
        SELECT RANK() OVER (ORDER BY SUM(S.TOTAL_SPEND) DESC)                  AS CATEGORY_RANK,
               M.MCC,
               COALESCE(C.DESCRIPTION, 'Unknown MCC ' || M.MCC)                AS CATEGORY,
               COALESCE(C.RISK_WEIGHT, 1)                                      AS RISK_WEIGHT,
               COUNT(DISTINCT S.MERCHANT_ID)                                   AS MERCHANTS,
               SUM(S.TXN_COUNT)                                                AS TXN_COUNT,
               SUM(S.TOTAL_SPEND)                                              AS TOTAL_SPEND,
               DECIMAL(100E0 * SUM(S.TOTAL_SPEND)
                       / NULLIF(SUM(SUM(S.TOTAL_SPEND)) OVER (), 0), 5, 2)     AS PCT_OF_SPEND
          FROM RPT.MQT_MERCHANT_SPEND S
          JOIN CARD.MERCHANT M ON M.MERCHANT_ID = S.MERCHANT_ID
          LEFT JOIN REF.MERCHANT_CATEGORY C ON C.MCC = M.MCC
         WHERE S.BUSINESS_DATE BETWEEN V_FROM_DATE AND V_TO_DATE
         GROUP BY M.MCC, C.DESCRIPTION, C.RISK_WEIGHT
         ORDER BY CATEGORY_RANK, M.MCC
          WITH UR;

    SET V_TOP_N = COALESCE(P_TOP_N, 20);
    IF V_TOP_N < 1 OR V_TOP_N > 500 THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Top N must be between 1 and 500';
    END IF;

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

    OPEN C_MERCHANTS;
    OPEN C_CATEGORIES;
END@

-- Reports page: fraud alert trends by ISO week and rule (RS1) and by day of week (RS2).
-- Dates arrive as UK strings 'DD/MM/YYYY' from the old reports screen (never changed to DATE);
-- default is the last 40 business days. Raises 75008 if a date can't be parsed or range is bad.
CREATE OR REPLACE PROCEDURE RPT.FRAUD_ALERT_TRENDS (
    IN P_FROM_DATE VARCHAR(10) DEFAULT NULL,
    IN P_TO_DATE   VARCHAR(10) DEFAULT NULL
)
    LANGUAGE SQL
    SPECIFIC RPT_FRAUD_ALERT_TRENDS
    DYNAMIC RESULT SETS 2
    READS SQL DATA
BEGIN
    DECLARE V_FROM_DATE DATE;
    DECLARE V_TO_DATE   DATE;
    DECLARE V_DAYS      INTEGER DEFAULT 1;
    DECLARE V_HOLIDAY   INTEGER DEFAULT 0;

    DECLARE C_WEEKLY CURSOR WITH RETURN TO CLIENT FOR
        WITH WEEKLY AS (
            SELECT CHAR(VARCHAR_FORMAT(F.BUSINESS_DATE, 'IYYY') || '-W' ||
                        RIGHT(DIGITS(WEEK_ISO(F.BUSINESS_DATE)), 2), 8)   AS ISO_WEEK,
                   MIN(F.BUSINESS_DATE)                                    AS FIRST_DATE,
                   MAX(F.BUSINESS_DATE)                                    AS LAST_DATE,
                   COALESCE(R.NAME, 'AUTH_SCORE')                          AS RULE_NAME,
                   COUNT(*)                                                AS ALERTS,
                   SUM(CASE WHEN F.STATUS = 'O' THEN 1 ELSE 0 END)         AS STILL_OPEN,
                   SUM(CASE WHEN F.STATUS = 'C' THEN 1 ELSE 0 END)         AS CLOSED,
                   SUM(CASE WHEN F.STATUS = 'E' THEN 1 ELSE 0 END)         AS ESCALATED,
                   DECIMAL(AVG(DECIMAL(F.SCORE, 7, 2)), 7, 1)              AS AVG_SCORE,
                   SUM(CASE WHEN F.SCORE >= 70 THEN 1 ELSE 0 END)          AS HIGH_SCORE,
                   -- wall-clock minutes to resolve (TIMESTAMPDIFF works on a CHAR duration)
                   INT(AVG(CASE WHEN F.RESOLVED_TS IS NOT NULL
                                THEN TIMESTAMPDIFF(4, CHAR(F.RESOLVED_TS - F.RAISED_TS)) END)) AS AVG_MINS_TO_RESOLVE
              FROM RISK.FRAUD_ALERT F
              LEFT JOIN RISK.FRAUD_RULE R ON R.RULE_ID = F.RULE_ID
             WHERE F.BUSINESS_DATE BETWEEN V_FROM_DATE AND V_TO_DATE
             GROUP BY VARCHAR_FORMAT(F.BUSINESS_DATE, 'IYYY'), WEEK_ISO(F.BUSINESS_DATE), R.NAME
        )
        SELECT W.ISO_WEEK,
               W.FIRST_DATE,
               W.LAST_DATE,
               W.RULE_NAME,
               W.ALERTS,
               W.ALERTS - LAG(W.ALERTS, 1, 0) OVER (PARTITION BY W.RULE_NAME ORDER BY W.ISO_WEEK) AS CHANGE_ON_PRIOR_WEEK,
               W.STILL_OPEN,
               W.CLOSED,
               W.ESCALATED,
               W.AVG_SCORE,
               W.HIGH_SCORE,
               W.AVG_MINS_TO_RESOLVE
          FROM WEEKLY W
         ORDER BY W.ISO_WEEK, W.RULE_NAME
          WITH UR;

    DECLARE C_DAY_OF_WEEK CURSOR WITH RETURN TO CLIENT FOR
        SELECT DAYOFWEEK(F.BUSINESS_DATE)                                  AS DAY_NO,
               VARCHAR(DAYNAME(F.BUSINESS_DATE), 9)                        AS DAY_NAME,
               COUNT(*)                                                    AS ALERTS,
               COUNT(DISTINCT F.BUSINESS_DATE)                             AS BUSINESS_DAYS,
               DECIMAL(DECIMAL(COUNT(*), 9, 2) / COUNT(DISTINCT F.BUSINESS_DATE), 9, 1) AS ALERTS_PER_DAY,
               DECIMAL(AVG(DECIMAL(F.SCORE, 7, 2)), 7, 1)                  AS AVG_SCORE,
               SUM(CASE WHEN F.SCORE >= 70 THEN 1 ELSE 0 END)              AS HIGH_SCORE,
               COUNT(DISTINCT F.ACCOUNT_ID)                                AS ACCOUNTS,
               CHAR(VARCHAR_FORMAT(MAX(F.RAISED_TS), 'DD/MM/YYYY HH24:MI'), 16) AS LAST_RAISED
          FROM RISK.FRAUD_ALERT F
         WHERE F.BUSINESS_DATE BETWEEN V_FROM_DATE AND V_TO_DATE
         GROUP BY DAYOFWEEK(F.BUSINESS_DATE), DAYNAME(F.BUSINESS_DATE)
         ORDER BY DAY_NO
          WITH UR;

    -- bad date strings from the screen come back as 75008, not a raw -180/-20448
    DECLARE EXIT HANDLER FOR SQLSTATE '22007', SQLSTATE '22008'
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Dates must be DD/MM/YYYY';

    IF P_TO_DATE IS NULL OR P_TO_DATE = '' THEN
        SET V_TO_DATE = UTIL.CURRENT_BUSINESS_DATE();
    ELSE
        SET V_TO_DATE = DATE(TIMESTAMP_FORMAT(P_TO_DATE, 'DD/MM/YYYY'));
    END IF;

    IF P_FROM_DATE IS NOT NULL AND P_FROM_DATE <> '' THEN
        SET V_FROM_DATE = DATE(TIMESTAMP_FORMAT(P_FROM_DATE, 'DD/MM/YYYY'));
    ELSE
        SET V_FROM_DATE = V_TO_DATE;
        BACK_LOOP:
        WHILE V_DAYS < 40 DO
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

    OPEN C_WEEKLY;
    OPEN C_DAY_OF_WEEK;
END@

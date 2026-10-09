-- Fraud analyst queue: open alerts, highest score first, with customer and any held
-- payment awaiting a decision. Called by the app (ops console). Returns 1 result set.
-- Raises 75008 bad row limit or score.
CREATE OR REPLACE PROCEDURE RISK.GET_OPEN_ALERTS (
    IN P_MIN_SCORE  SMALLINT,
    IN P_ACCOUNT_ID BIGINT,
    IN P_MAX_ROWS   INTEGER
)
    LANGUAGE SQL
    SPECIFIC RISK_GET_OPEN_ALERTS
    DYNAMIC RESULT SETS 1
    READS SQL DATA
BEGIN
    DECLARE V_MIN_SCORE SMALLINT;
    DECLARE V_MAX_ROWS  INTEGER;

    DECLARE C_ALERTS CURSOR WITH RETURN TO CLIENT FOR
        SELECT V.ALERT_ID,
               V.ACCOUNT_ID,
               UTIL.FORMAT_SORT_CODE(V.SORT_CODE) AS SORT_CODE,
               V.ACCOUNT_NO,
               C.CUSTOMER_ID,
               C.CUSTOMER_NO,
               C.FIRST_NAME || ' ' || C.LAST_NAME AS CUSTOMER_NAME,
               V.CARD_ID,
               UTIL.MASK_PAN(K.PAN) AS MASKED_PAN,
               V.RULE_ID,
               COALESCE(V.RULE_NAME, 'ONLINE') AS RULE_NAME,
               V.SCORE,
               V.DETAIL,
               V.BUSINESS_DATE,
               V.RAISED_TS,
               TIMESTAMPDIFF(4, CHAR(CURRENT TIMESTAMP - V.RAISED_TS)) AS AGE_MINUTES,
               (SELECT COUNT(*) FROM PAY.PAYMENT P
                 WHERE P.ACCOUNT_ID = V.ACCOUNT_ID
                   AND P.STATUS = 'H'
                   AND P.BUSINESS_DATE >= V.BUSINESS_DATE) AS HELD_PAYMENTS,
               (SELECT SUM(P.AMOUNT) FROM PAY.PAYMENT P
                 WHERE P.ACCOUNT_ID = V.ACCOUNT_ID
                   AND P.STATUS = 'H'
                   AND P.BUSINESS_DATE >= V.BUSINESS_DATE) AS HELD_AMOUNT,
               A.STATUS AS ACCOUNT_STATUS
          FROM RISK.V_OPEN_ALERTS V
          JOIN ACCT.ACCOUNT A ON A.ACCOUNT_ID = V.ACCOUNT_ID
          JOIN CUST.CUSTOMER C ON C.CUSTOMER_ID = A.PRIMARY_CUSTOMER_ID
          LEFT JOIN CARD.CARD K ON K.CARD_ID = V.CARD_ID
         WHERE V.SCORE >= V_MIN_SCORE
           AND (P_ACCOUNT_ID IS NULL OR V.ACCOUNT_ID = P_ACCOUNT_ID)
         ORDER BY V.SCORE DESC, V.RAISED_TS
         FETCH FIRST V_MAX_ROWS ROWS ONLY
          WITH UR;

    SET V_MIN_SCORE = COALESCE(P_MIN_SCORE, 0);
    SET V_MAX_ROWS  = COALESCE(P_MAX_ROWS, 50);

    IF V_MAX_ROWS NOT BETWEEN 1 AND 500 THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Max rows must be between 1 and 500';
    END IF;
    IF V_MIN_SCORE < 0 THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'Minimum score cannot be negative';
    END IF;

    OPEN C_ALERTS;
END@

-- Recent authorisations on a card for the app's card screen and the teller view.
-- One result set, newest first, at most 200 rows over the last P_DAYS business days (default 7).
-- Raises 75005 card not found.
CREATE OR REPLACE PROCEDURE CARD.GET_CARD_ACTIVITY (
    IN P_CARD_ID BIGINT,
    IN P_DAYS    SMALLINT
)
    LANGUAGE SQL
    SPECIFIC CARD_GET_CARD_ACTIVITY
    DYNAMIC RESULT SETS 1
    READS SQL DATA
BEGIN
    DECLARE V_FROM_DATE DATE;
    DECLARE V_FOUND     INTEGER DEFAULT 0;

    DECLARE C_ACTIVITY CURSOR WITH RETURN TO CLIENT FOR
        SELECT A.AUTH_ID,
               UTIL.MASK_PAN(C.PAN)                                    AS MASKED_PAN,
               A.AUTH_TS,
               A.BUSINESS_DATE,
               M.NAME                                                  AS MERCHANT_NAME,
               M.TOWN                                                  AS MERCHANT_TOWN,
               M.MCC,
               G.DESCRIPTION                                           AS CATEGORY,
               A.AMOUNT,
               A.RESPONSE_CODE,
               CASE A.RESPONSE_CODE
                    WHEN '00' THEN 'Approved'
                    WHEN '05' THEN 'Do not honour'
                    WHEN '14' THEN 'Invalid card'
                    WHEN '43' THEN 'Stolen card'
                    WHEN '51' THEN 'Insufficient funds'
                    WHEN '54' THEN 'Expired card'
                    WHEN '59' THEN 'Suspected fraud'
                    WHEN '61' THEN 'Exceeds limit'
                    ELSE 'Other' END                                   AS RESPONSE_TEXT,
               A.STATUS,
               CASE A.STATUS
                    WHEN 'A' THEN 'Pending'
                    WHEN 'S' THEN 'Settled'
                    WHEN 'R' THEN 'Reversed'
                    WHEN 'X' THEN 'Expired'
                    WHEN 'D' THEN 'Declined' END                       AS STATUS_TEXT,
               TIMESTAMPDIFF(4, CHAR(CURRENT TIMESTAMP - A.AUTH_TS))   AS MINUTES_AGO,
               A.SETTLED_TXN_ID
          FROM CARD.AUTHORISATION A
          JOIN CARD.CARD C ON C.CARD_ID = A.CARD_ID
          JOIN CARD.MERCHANT M ON M.MERCHANT_ID = A.MERCHANT_ID
          LEFT JOIN REF.MERCHANT_CATEGORY G ON G.MCC = M.MCC
         WHERE A.CARD_ID = P_CARD_ID
           AND A.BUSINESS_DATE >= V_FROM_DATE
         ORDER BY A.AUTH_TS DESC, A.AUTH_ID DESC
         FETCH FIRST 200 ROWS ONLY
          WITH UR;

    SELECT COUNT(*) INTO V_FOUND FROM CARD.CARD WHERE CARD_ID = P_CARD_ID WITH UR;
    IF V_FOUND = 0 THEN
        SIGNAL SQLSTATE '75005' SET MESSAGE_TEXT = 'Card not found';
    END IF;

    SET V_FROM_DATE = UTIL.CURRENT_BUSINESS_DATE() - COALESCE(P_DAYS, 7) DAYS;

    OPEN C_ACTIVITY;
END@

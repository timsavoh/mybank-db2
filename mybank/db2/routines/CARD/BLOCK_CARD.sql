-- Changes card status: B temporary block (freeze), L lost, S stolen, or A to unfreeze a blocked card.
-- Called by the app (web, mobile, teller). Audit and customer SMS come from triggers on CARD.CARD.
-- Raises 75005 card not found or expired, 75008 bad status, 75009 lost/stolen cards cannot be reactivated.
CREATE OR REPLACE PROCEDURE CARD.BLOCK_CARD (
    IN P_CARD_ID    BIGINT,
    IN P_NEW_STATUS CHAR(1),
    IN P_REASON     VARCHAR(40)
)
    LANGUAGE SQL
    SPECIFIC CARD_BLOCK_CARD
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE CHAR(5);
    DECLARE V_SQLCODE  INTEGER;
    DECLARE V_MSG      VARCHAR(1000);

    DECLARE V_STATUS CHAR(1);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.LOG_ERROR('CARD.BLOCK_CARD', V_SQLSTATE, V_SQLCODE, V_MSG,
             'CARD_ID=' || COALESCE(RTRIM(CHAR(P_CARD_ID)), 'NULL') ||
             ' NEW_STATUS=' || COALESCE(P_NEW_STATUS, 'NULL'));
        RESIGNAL;
    END;

    IF P_NEW_STATUS IS NULL OR P_NEW_STATUS NOT IN ('A', 'B', 'L', 'S') THEN
        SIGNAL SQLSTATE '75008' SET MESSAGE_TEXT = 'New card status must be A, B, L or S';
    END IF;

    SELECT STATUS INTO V_STATUS
      FROM CARD.CARD
     WHERE CARD_ID = P_CARD_ID
      WITH RS USE AND KEEP UPDATE LOCKS;

    IF V_STATUS IS NULL OR V_STATUS = 'E' THEN
        SIGNAL SQLSTATE '75005' SET MESSAGE_TEXT = 'Card not found or expired';
    END IF;

    IF V_STATUS = P_NEW_STATUS THEN
        RETURN;
    END IF;

    IF V_STATUS IN ('L', 'S') THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Lost or stolen cards cannot be changed; issue a new card';
    END IF;

    UPDATE CARD.CARD
       SET STATUS = P_NEW_STATUS,
           BLOCKED_REASON = CASE WHEN P_NEW_STATUS = 'A' THEN NULL
                                 ELSE COALESCE(P_REASON,
                                               CASE P_NEW_STATUS WHEN 'L' THEN 'LOST'
                                                                 WHEN 'S' THEN 'STOLEN'
                                                                 ELSE 'CUSTOMER FREEZE' END)
                            END
     WHERE CARD_ID = P_CARD_ID;
END@

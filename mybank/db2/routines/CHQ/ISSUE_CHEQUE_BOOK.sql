-- Cheques discontinued 2021 - kept for reference, not called.
-- Issues a cheque book of P_LEAVES cheques to a current account: one CHEQUE_BOOK row and one
-- unused CHEQUE row per leaf. Serials follow on from the account's last book.
CREATE OR REPLACE PROCEDURE CHQ.ISSUE_CHEQUE_BOOK (
    IN  P_ACCOUNT_ID BIGINT,
    IN  P_LEAVES     SMALLINT,
    OUT P_BOOK_ID    BIGINT
)
    LANGUAGE SQL
    SPECIFIC CHQ_ISSUE_CHEQUE_BOOK
    MODIFIES SQL DATA
BEGIN
    DECLARE V_PRODUCT CHAR(6);
    DECLARE V_STATUS  CHAR(1);
    DECLARE V_FIRST   INTEGER;
    DECLARE V_LEAVES  SMALLINT;
    DECLARE V_SERIAL  INTEGER;

    SELECT PRODUCT_CODE, STATUS
      INTO V_PRODUCT, V_STATUS
      FROM ACCT.ACCOUNT
     WHERE ACCOUNT_ID = P_ACCOUNT_ID;

    IF V_STATUS IS NULL THEN
        SIGNAL SQLSTATE '75002' SET MESSAGE_TEXT = 'Account not found';
    END IF;

    -- no cheque books on savings or basic accounts
    IF V_PRODUCT NOT LIKE 'CUR%' OR V_PRODUCT = 'CUR004' OR V_STATUS <> 'A' THEN
        SIGNAL SQLSTATE '75009' SET MESSAGE_TEXT = 'Cheque book not available on this account';
    END IF;

    SET V_LEAVES = VALUE(P_LEAVES, 30);
    IF V_LEAVES NOT IN (30, 50, 100) THEN
        SET V_LEAVES = 30;
    END IF;

    -- serials start at 100001 for every account (sort code + account no makes them unique)
    SELECT VALUE(MAX(LAST_SERIAL), 100000) + 1
      INTO V_FIRST
      FROM CHQ.CHEQUE_BOOK
     WHERE ACCOUNT_ID = P_ACCOUNT_ID;

    SELECT BOOK_ID
      INTO P_BOOK_ID
      FROM FINAL TABLE (INSERT INTO CHQ.CHEQUE_BOOK (ACCOUNT_ID, FIRST_SERIAL, LAST_SERIAL, ISSUED_DATE)
                        VALUES (P_ACCOUNT_ID, V_FIRST, V_FIRST + V_LEAVES - 1, CURRENT DATE));

    SET V_SERIAL = V_FIRST;
    LEAF_LOOP:
    WHILE V_SERIAL <= V_FIRST + V_LEAVES - 1 DO
        INSERT INTO CHQ.CHEQUE (BOOK_ID, SERIAL_NO, STATUS) VALUES (P_BOOK_ID, V_SERIAL, 'U');
        SET V_SERIAL = V_SERIAL + 1;
    END WHILE LEAF_LOOP;

    -- TODO: first book free, charge for further books (never agreed with Product)
    -- CALL UTIL.CALC_FEE_TEMP('CHQBOOK', 0) ...
END@

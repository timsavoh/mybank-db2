-- Month-end: one OPS.STATEMENT per open account with activity since its previous statement
-- (or since opening), with OPS.STATEMENT_LINE rows and an XML rendition in STATEMENT_XML built
-- with XMLELEMENT/XMLATTRIBUTES/XMLAGG. Accounts that already have a statement ending today are skipped.
CREATE OR REPLACE PROCEDURE BATCH.GENERATE_STATEMENTS (OUT P_ROWS_PROCESSED INTEGER)
    LANGUAGE SQL
    SPECIFIC BATCH_GENERATE_STATEMENTS
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE CHAR(5);
    DECLARE V_SQLCODE  INTEGER;
    DECLARE V_MSG      VARCHAR(1000);
    DECLARE V_RUN_ID   BIGINT;
    DECLARE V_ROWS     INTEGER DEFAULT 0;
    DECLARE V_LINES    INTEGER DEFAULT 0;
    DECLARE V_COUNT    INTEGER;
    DECLARE V_EOF      SMALLINT DEFAULT 0;
    DECLARE V_TODAY    DATE;

    DECLARE V_ACCOUNT_ID   BIGINT;
    DECLARE V_PERIOD_START DATE;
    DECLARE V_STATEMENT_ID BIGINT;

    DECLARE C_ACCOUNTS CURSOR WITH HOLD FOR
        SELECT A.ACCOUNT_ID,
               COALESCE(LS.LAST_PERIOD_END + 1 DAY, A.OPENED_DATE) AS PERIOD_START
          FROM ACCT.ACCOUNT A
          LEFT OUTER JOIN (SELECT ACCOUNT_ID, MAX(PERIOD_END) AS LAST_PERIOD_END
                             FROM OPS.STATEMENT
                            GROUP BY ACCOUNT_ID) LS
            ON LS.ACCOUNT_ID = A.ACCOUNT_ID
         WHERE A.STATUS <> 'C'
           AND (LS.LAST_PERIOD_END IS NULL OR LS.LAST_PERIOD_END < V_TODAY)
           AND EXISTS (SELECT 1
                         FROM TXN.POSTED_TXN T
                        WHERE T.ACCOUNT_ID = A.ACCOUNT_ID
                          AND T.BUSINESS_DATE >= COALESCE(LS.LAST_PERIOD_END + 1 DAY, A.OPENED_DATE)
                          AND T.BUSINESS_DATE <= V_TODAY)
         ORDER BY A.ACCOUNT_ID
          WITH CS;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET V_EOF = 1;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.END_JOB_RUN(V_RUN_ID, 'F', V_ROWS, V_MSG);
        CALL UTIL.LOG_ERROR('BATCH.GENERATE_STATEMENTS', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'ACCOUNT_ID=' || COALESCE(RTRIM(CHAR(V_ACCOUNT_ID)), '-'));
        RESIGNAL;
    END;

    CALL UTIL.START_JOB_RUN('GENERATE_STATEMENTS', V_RUN_ID);
    SET V_TODAY = UTIL.CURRENT_BUSINESS_DATE();

    OPEN C_ACCOUNTS;
    STMT_LOOP:
    LOOP
        SET V_EOF = 0;
        FETCH C_ACCOUNTS INTO V_ACCOUNT_ID, V_PERIOD_START;
        IF V_EOF = 1 THEN
            LEAVE STMT_LOOP;
        END IF;

        SET V_STATEMENT_ID = NEXT VALUE FOR OPS.SEQ_STATEMENT_NO;

        -- Header: opening balance is the balance before the first line, closing after the last
        INSERT INTO OPS.STATEMENT (STATEMENT_ID, ACCOUNT_ID, PERIOD_START, PERIOD_END, OPENING_BALANCE,
                                   CLOSING_BALANCE, TOTAL_IN, TOTAL_OUT, LINE_COUNT)
        SELECT V_STATEMENT_ID, V_ACCOUNT_ID, V_PERIOD_START, V_TODAY,
               SUM(CASE WHEN X.FIRST_NO = 1 THEN X.BALANCE_AFTER - X.AMOUNT ELSE 0 END),
               SUM(CASE WHEN X.LAST_NO = 1 THEN X.BALANCE_AFTER ELSE 0 END),
               SUM(CASE WHEN X.AMOUNT > 0 THEN X.AMOUNT ELSE 0 END),
               SUM(CASE WHEN X.AMOUNT < 0 THEN -X.AMOUNT ELSE 0 END),
               COUNT(*)
          FROM (SELECT T.AMOUNT, T.BALANCE_AFTER,
                       ROW_NUMBER() OVER (ORDER BY T.TXN_ID) AS FIRST_NO,
                       ROW_NUMBER() OVER (ORDER BY T.TXN_ID DESC) AS LAST_NO
                  FROM TXN.POSTED_TXN T
                 WHERE T.ACCOUNT_ID = V_ACCOUNT_ID
                   AND T.BUSINESS_DATE BETWEEN V_PERIOD_START AND V_TODAY) X;

        INSERT INTO OPS.STATEMENT_LINE (STATEMENT_ID, LINE_NO, TXN_ID, BUSINESS_DATE, DESCRIPTION,
                                        AMOUNT, BALANCE_AFTER)
        SELECT V_STATEMENT_ID,
               ROW_NUMBER() OVER (ORDER BY T.TXN_ID),
               T.TXN_ID, T.BUSINESS_DATE, T.DESCRIPTION, T.AMOUNT, T.BALANCE_AFTER
          FROM TXN.POSTED_TXN T
         WHERE T.ACCOUNT_ID = V_ACCOUNT_ID
           AND T.BUSINESS_DATE BETWEEN V_PERIOD_START AND V_TODAY;
        GET DIAGNOSTICS V_COUNT = ROW_COUNT;
        SET V_LINES = V_LINES + V_COUNT;

        UPDATE OPS.STATEMENT S
           SET STATEMENT_XML =
               (SELECT XMLDOCUMENT(
                         XMLELEMENT(NAME "statement",
                           XMLATTRIBUTES(S.STATEMENT_ID AS "id", A.CURRENCY AS "currency",
                                         S.GENERATED_TS AS "generated"),
                           XMLELEMENT(NAME "account",
                             XMLATTRIBUTES(UTIL.FORMAT_SORT_CODE(A.SORT_CODE) AS "sortCode",
                                           A.ACCOUNT_NO AS "accountNo"),
                             XMLELEMENT(NAME "name", A.ACCOUNT_NAME),
                             XMLELEMENT(NAME "product", P.NAME),
                             XMLELEMENT(NAME "holder",
                               RTRIM(COALESCE(C.TITLE || ' ', '') || C.FIRST_NAME || ' ' || C.LAST_NAME))),
                           XMLELEMENT(NAME "period",
                             XMLATTRIBUTES(S.PERIOD_START AS "from", S.PERIOD_END AS "to")),
                           XMLELEMENT(NAME "summary",
                             XMLELEMENT(NAME "openingBalance", S.OPENING_BALANCE),
                             XMLELEMENT(NAME "moneyIn", S.TOTAL_IN),
                             XMLELEMENT(NAME "moneyOut", S.TOTAL_OUT),
                             XMLELEMENT(NAME "closingBalance", S.CLOSING_BALANCE)),
                           XMLELEMENT(NAME "lines",
                             XMLATTRIBUTES(S.LINE_COUNT AS "count"),
                             (SELECT XMLAGG(
                                       XMLELEMENT(NAME "line",
                                         XMLATTRIBUTES(L.LINE_NO AS "no", L.BUSINESS_DATE AS "date"),
                                         XMLELEMENT(NAME "description", L.DESCRIPTION),
                                         XMLELEMENT(NAME "amount", L.AMOUNT),
                                         XMLELEMENT(NAME "balance", L.BALANCE_AFTER))
                                       ORDER BY L.LINE_NO)
                                FROM OPS.STATEMENT_LINE L
                               WHERE L.STATEMENT_ID = S.STATEMENT_ID))))
                  FROM ACCT.ACCOUNT A
                  JOIN REF.PRODUCT P
                    ON P.PRODUCT_CODE = A.PRODUCT_CODE
                  JOIN CUST.CUSTOMER C
                    ON C.CUSTOMER_ID = A.PRIMARY_CUSTOMER_ID
                 WHERE A.ACCOUNT_ID = S.ACCOUNT_ID)
         WHERE S.STATEMENT_ID = V_STATEMENT_ID;

        SET V_ROWS = V_ROWS + 1;
        IF MOD(V_ROWS, 200) = 0 THEN
            COMMIT;
        END IF;
    END LOOP STMT_LOOP;
    CLOSE C_ACCOUNTS;

    COMMIT;

    SET P_ROWS_PROCESSED = V_ROWS;
    CALL UTIL.END_JOB_RUN(V_RUN_ID, 'S', V_ROWS,
         RTRIM(CHAR(V_ROWS)) || ' statements, ' || RTRIM(CHAR(V_LINES)) || ' lines, period ending '
         || CHAR(V_TODAY, ISO));
END@

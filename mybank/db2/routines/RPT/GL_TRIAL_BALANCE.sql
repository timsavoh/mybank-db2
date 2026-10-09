-- Reports page: GL trial balance as at P_AS_OF (default current business date). RS1 walks the
-- REF.GL_ACCOUNT hierarchy (recursive CTE) with balances rolled up to each parent, plus
-- month-to-date movement; RS2 is the totals and ledger-invariant checks (OK / BREAK).
CREATE OR REPLACE PROCEDURE RPT.GL_TRIAL_BALANCE (
    IN P_AS_OF         DATE    DEFAULT NULL,
    IN P_POSTABLE_ONLY CHAR(1) DEFAULT 'N'
)
    LANGUAGE SQL
    SPECIFIC RPT_GL_TRIAL_BALANCE
    DYNAMIC RESULT SETS 2
    READS SQL DATA
BEGIN
    DECLARE V_AS_OF        DATE;
    DECLARE V_PERIOD_START DATE;
    DECLARE V_POSTABLE     CHAR(1);

    DECLARE C_TRIAL_BALANCE CURSOR WITH RETURN TO CLIENT FOR
        WITH HIER (GL_CODE, NAME, GL_TYPE, POSTABLE, LVL, SORT_PATH) AS (
            SELECT G.GL_CODE, G.NAME, G.GL_TYPE, G.POSTABLE, 1, CAST(G.GL_CODE AS VARCHAR(60))
              FROM REF.GL_ACCOUNT G
             WHERE G.PARENT_GL_CODE IS NULL
            UNION ALL
            SELECT C.GL_CODE, C.NAME, C.GL_TYPE, C.POSTABLE, H.LVL + 1, H.SORT_PATH || '/' || C.GL_CODE
              FROM HIER H, REF.GL_ACCOUNT C
             WHERE C.PARENT_GL_CODE = H.GL_CODE
               AND H.LVL < 10
        ),
        -- every (ancestor, descendant) pair including self, so parents can sum their subtree
        ANCESTRY (ANCESTOR_CODE, GL_CODE, DEPTH) AS (
            SELECT G.GL_CODE, G.GL_CODE, 0
              FROM REF.GL_ACCOUNT G
            UNION ALL
            SELECT A.ANCESTOR_CODE, C.GL_CODE, A.DEPTH + 1
              FROM ANCESTRY A, REF.GL_ACCOUNT C
             WHERE C.PARENT_GL_CODE = A.GL_CODE
               AND A.DEPTH < 10
        ),
        LEAF (GL_CODE, BALANCE, MTD_MOVEMENT, ENTRIES) AS (
            SELECT E.GL_CODE,
                   SUM(E.AMOUNT),
                   SUM(CASE WHEN E.BUSINESS_DATE >= V_PERIOD_START THEN E.AMOUNT ELSE 0 END),
                   COUNT(*)
              FROM GL.GL_ENTRY E
             WHERE E.BUSINESS_DATE <= V_AS_OF
             GROUP BY E.GL_CODE
        ),
        ROLLED (GL_CODE, BALANCE, MTD_MOVEMENT, ENTRIES) AS (
            SELECT A.ANCESTOR_CODE,
                   SUM(COALESCE(L.BALANCE, 0)),
                   SUM(COALESCE(L.MTD_MOVEMENT, 0)),
                   SUM(COALESCE(L.ENTRIES, 0))
              FROM ANCESTRY A
              LEFT JOIN LEAF L ON L.GL_CODE = A.GL_CODE
             GROUP BY A.ANCESTOR_CODE
        )
        SELECT H.LVL,
               H.GL_CODE,
               REPEAT('  ', H.LVL - 1) || H.NAME                           AS ACCOUNT_NAME,
               CASE H.GL_TYPE WHEN 'A' THEN 'Asset'   WHEN 'L' THEN 'Liability'
                              WHEN 'Q' THEN 'Equity'  WHEN 'I' THEN 'Income'
                              ELSE 'Expense' END                           AS GL_TYPE,
               H.POSTABLE,
               CASE WHEN R.BALANCE > 0 THEN R.BALANCE END                  AS DEBIT,
               CASE WHEN R.BALANCE < 0 THEN -R.BALANCE END                 AS CREDIT,
               R.BALANCE                                                   AS NET_BALANCE,
               R.MTD_MOVEMENT,
               R.ENTRIES
          FROM HIER H
          JOIN ROLLED R ON R.GL_CODE = H.GL_CODE
         WHERE V_POSTABLE = 'N' OR H.POSTABLE = 'Y'
         ORDER BY H.SORT_PATH
          WITH UR;

    DECLARE C_CHECKS CURSOR WITH RETURN TO CLIENT FOR
        SELECT 'Total debits = total credits'                              AS CHECK_NAME,
               SUM(CASE WHEN E.AMOUNT > 0 THEN E.AMOUNT ELSE 0 END)        AS EXPECTED,
               SUM(CASE WHEN E.AMOUNT < 0 THEN -E.AMOUNT ELSE 0 END)       AS ACTUAL,
               SUM(E.AMOUNT)                                               AS DIFFERENCE,
               CASE WHEN COALESCE(SUM(E.AMOUNT), 0) = 0 THEN 'OK' ELSE 'BREAK' END AS STATUS
          FROM GL.GL_ENTRY E
         WHERE E.BUSINESS_DATE <= V_AS_OF
        UNION ALL
        -- customer balances are only held as at now, so this one is only meaningful for today
        SELECT 'Customer balances = product control GLs',
               X.ACCOUNTS_TOTAL,
               X.CONTROL_TOTAL,
               X.ACCOUNTS_TOTAL - X.CONTROL_TOTAL,
               CASE WHEN V_AS_OF < UTIL.CURRENT_BUSINESS_DATE() THEN 'N/A'
                    WHEN X.ACCOUNTS_TOTAL = X.CONTROL_TOTAL THEN 'OK'
                    ELSE 'BREAK' END
          FROM (SELECT (SELECT COALESCE(SUM(LEDGER_BALANCE), 0) FROM ACCT.ACCOUNT) AS ACCOUNTS_TOTAL,
                       (SELECT COALESCE(-SUM(E.AMOUNT), 0)
                          FROM GL.GL_ENTRY E
                         WHERE E.GL_CODE IN (SELECT DISTINCT CONTROL_GL_CODE FROM REF.PRODUCT)) AS CONTROL_TOTAL
                  FROM SYSIBM.SYSDUMMY1) X
        UNION ALL
        SELECT 'Internal transfer suspense (1900) nets to zero',
               DECIMAL(0, 31, 2),
               COALESCE(SUM(E.AMOUNT), 0),
               COALESCE(SUM(E.AMOUNT), 0),
               CASE WHEN COALESCE(SUM(E.AMOUNT), 0) = 0 THEN 'OK' ELSE 'BREAK' END
          FROM GL.GL_ENTRY E
         WHERE E.GL_CODE = '1900'
           AND E.BUSINESS_DATE <= V_AS_OF
          WITH UR;

    SET V_AS_OF = COALESCE(P_AS_OF, UTIL.CURRENT_BUSINESS_DATE());
    SET V_PERIOD_START = V_AS_OF - (DAY(V_AS_OF) - 1) DAYS;
    SET V_POSTABLE = COALESCE(UPPER(P_POSTABLE_ONLY), 'N');

    OPEN C_TRIAL_BALANCE;
    OPEN C_CHECKS;
END@

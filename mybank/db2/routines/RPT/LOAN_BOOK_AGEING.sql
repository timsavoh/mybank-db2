-- Reports page: personal loan book by vintage (months on book, RS1) and by arrears ageing
-- (days past the oldest unpaid instalment, RS2), as at P_AS_OF (default current business date).
-- Buckets use TIMESTAMPDIFF, which estimates (30-day months) - fine for a MI report.
CREATE OR REPLACE PROCEDURE RPT.LOAN_BOOK_AGEING (
    IN P_AS_OF DATE DEFAULT NULL
)
    LANGUAGE SQL
    SPECIFIC RPT_LOAN_BOOK_AGEING
    DYNAMIC RESULT SETS 2
    READS SQL DATA
BEGIN
    DECLARE V_AS_OF    DATE;
    DECLARE V_AS_OF_TS TIMESTAMP;

    DECLARE C_VINTAGE CURSOR WITH RETURN TO CLIENT FOR
        WITH BOOK AS (
            SELECT L.LOAN_ID, L.PRINCIPAL, L.OUTSTANDING_PRINCIPAL, L.ANNUAL_RATE, L.TERM_MONTHS,
                   L.ARREARS_AMOUNT, L.MISSED_PAYMENTS, L.STATUS,
                   TIMESTAMPDIFF(64, CHAR(V_AS_OF_TS - TIMESTAMP(L.START_DATE, '00.00.00'))) AS MONTHS_ON_BOOK
              FROM LOAN.LOAN L
             WHERE L.STATUS IN ('A', 'D')
               AND L.START_DATE <= V_AS_OF
        )
        SELECT CASE WHEN B.MONTHS_ON_BOOK < 6  THEN 1
                    WHEN B.MONTHS_ON_BOOK < 12 THEN 2
                    WHEN B.MONTHS_ON_BOOK < 24 THEN 3
                    WHEN B.MONTHS_ON_BOOK < 36 THEN 4
                    ELSE 5 END                                             AS BUCKET_SEQ,
               CASE WHEN B.MONTHS_ON_BOOK < 6  THEN '0-5 months'
                    WHEN B.MONTHS_ON_BOOK < 12 THEN '6-11 months'
                    WHEN B.MONTHS_ON_BOOK < 24 THEN '1-2 years'
                    WHEN B.MONTHS_ON_BOOK < 36 THEN '2-3 years'
                    ELSE '3 years +' END                                   AS VINTAGE,
               COUNT(*)                                                    AS LOANS,
               SUM(B.PRINCIPAL)                                            AS ORIGINAL_PRINCIPAL,
               SUM(B.OUTSTANDING_PRINCIPAL)                                AS OUTSTANDING,
               DECIMAL(100E0 * SUM(B.OUTSTANDING_PRINCIPAL) / NULLIF(SUM(B.PRINCIPAL), 0), 5, 1) AS PCT_OUTSTANDING,
               DECIMAL(SUM(B.ANNUAL_RATE * B.OUTSTANDING_PRINCIPAL)
                       / NULLIF(SUM(B.OUTSTANDING_PRINCIPAL), 0), 7, 4)    AS WEIGHTED_RATE,
               INT(AVG(B.TERM_MONTHS - B.MONTHS_ON_BOOK))                  AS AVG_MONTHS_REMAINING,
               SUM(CASE WHEN B.ARREARS_AMOUNT > 0 THEN 1 ELSE 0 END)       AS LOANS_IN_ARREARS,
               SUM(B.ARREARS_AMOUNT)                                       AS ARREARS_AMOUNT,
               SUM(CASE WHEN B.STATUS = 'D' THEN 1 ELSE 0 END)             AS DEFAULTED
          FROM BOOK B
         GROUP BY CASE WHEN B.MONTHS_ON_BOOK < 6  THEN 1
                       WHEN B.MONTHS_ON_BOOK < 12 THEN 2
                       WHEN B.MONTHS_ON_BOOK < 24 THEN 3
                       WHEN B.MONTHS_ON_BOOK < 36 THEN 4
                       ELSE 5 END,
                  CASE WHEN B.MONTHS_ON_BOOK < 6  THEN '0-5 months'
                       WHEN B.MONTHS_ON_BOOK < 12 THEN '6-11 months'
                       WHEN B.MONTHS_ON_BOOK < 24 THEN '1-2 years'
                       WHEN B.MONTHS_ON_BOOK < 36 THEN '2-3 years'
                       ELSE '3 years +' END
         ORDER BY 1
          WITH UR;

    DECLARE C_ARREARS CURSOR WITH RETURN TO CLIENT FOR
        WITH OLDEST_DUE (LOAN_ID, OLDEST_UNPAID) AS (
            SELECT S.LOAN_ID, MIN(S.DUE_DATE)
              FROM LOAN.REPAYMENT_SCHEDULE S
             WHERE S.STATUS IN ('D', 'M')
               AND S.DUE_DATE < V_AS_OF
             GROUP BY S.LOAN_ID
        ),
        DPD AS (
            SELECT L.LOAN_ID, L.OUTSTANDING_PRINCIPAL, L.ARREARS_AMOUNT, L.MISSED_PAYMENTS, L.MONTHLY_PAYMENT,
                   CASE WHEN O.OLDEST_UNPAID IS NULL THEN 0
                        ELSE TIMESTAMPDIFF(16, CHAR(V_AS_OF_TS - TIMESTAMP(O.OLDEST_UNPAID, '00.00.00')))
                   END                                                     AS DAYS_PAST_DUE
              FROM LOAN.LOAN L
              LEFT JOIN OLDEST_DUE O ON O.LOAN_ID = L.LOAN_ID
             WHERE L.STATUS IN ('A', 'D')
               AND L.START_DATE <= V_AS_OF
        ),
        BUCKETED AS (
            SELECT D.*,
                   CASE WHEN D.DAYS_PAST_DUE = 0  THEN 0
                        WHEN D.DAYS_PAST_DUE < 30 THEN 1
                        WHEN D.DAYS_PAST_DUE < 60 THEN 2
                        WHEN D.DAYS_PAST_DUE < 90 THEN 3
                        ELSE 4 END                                         AS BUCKET_SEQ
              FROM DPD D
        )
        SELECT K.BUCKET_SEQ,
               CASE K.BUCKET_SEQ WHEN 0 THEN 'Up to date'
                                 WHEN 1 THEN '1-29 days'
                                 WHEN 2 THEN '30-59 days'
                                 WHEN 3 THEN '60-89 days'
                                 ELSE '90+ days (default)' END             AS ARREARS_BUCKET,
               COUNT(*)                                                    AS LOANS,
               SUM(K.OUTSTANDING_PRINCIPAL)                                AS OUTSTANDING,
               SUM(K.ARREARS_AMOUNT)                                       AS ARREARS_AMOUNT,
               SUM(K.MISSED_PAYMENTS)                                      AS MISSED_PAYMENTS,
               MAX(K.DAYS_PAST_DUE)                                        AS MAX_DAYS_PAST_DUE,
               DECIMAL(100E0 * SUM(K.OUTSTANDING_PRINCIPAL)
                       / NULLIF(SUM(SUM(K.OUTSTANDING_PRINCIPAL)) OVER (), 0), 5, 1) AS PCT_OF_BOOK
          FROM BUCKETED K
         GROUP BY K.BUCKET_SEQ
         ORDER BY K.BUCKET_SEQ
          WITH UR;

    SET V_AS_OF = COALESCE(P_AS_OF, UTIL.CURRENT_BUSINESS_DATE());
    SET V_AS_OF_TS = TIMESTAMP(V_AS_OF, '00.00.00');

    OPEN C_VINTAGE;
    OPEN C_ARREARS;
END@

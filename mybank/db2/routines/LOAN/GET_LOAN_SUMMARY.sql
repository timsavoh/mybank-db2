-- Loan position for the app's loan screen. Two result sets:
--   1. one summary row (balances, next payment, arrears, amounts repaid)
--   2. the remaining (unpaid) instalments of the schedule
-- Raises 75013 loan not found.
CREATE OR REPLACE PROCEDURE LOAN.GET_LOAN_SUMMARY (
    IN P_LOAN_ID BIGINT
)
    LANGUAGE SQL
    SPECIFIC LOAN_GET_LOAN_SUMMARY
    DYNAMIC RESULT SETS 2
    READS SQL DATA
BEGIN
    DECLARE V_FOUND INTEGER DEFAULT 0;

    DECLARE C_SUMMARY CURSOR WITH RETURN TO CLIENT FOR
        SELECT L.LOAN_ID,
               L.CUSTOMER_ID,
               A.SORT_CODE,
               A.ACCOUNT_NO,
               L.STATUS,
               CASE L.STATUS WHEN 'A' THEN 'Active' WHEN 'P' THEN 'Paid off'
                             WHEN 'D' THEN 'Defaulted' END                  AS STATUS_TEXT,
               L.PRINCIPAL,
               L.ANNUAL_RATE,
               L.TERM_MONTHS,
               L.MONTHLY_PAYMENT,
               L.START_DATE,
               L.NEXT_DUE_DATE,
               L.OUTSTANDING_PRINCIPAL,
               -A.LEDGER_BALANCE                                           AS AMOUNT_OWED,
               L.ARREARS_AMOUNT,
               L.MISSED_PAYMENTS,
               COALESCE(R.TOTAL_REPAID, 0)                                  AS TOTAL_REPAID,
               COALESCE(R.REPAYMENT_COUNT, 0)                               AS REPAYMENT_COUNT,
               R.LAST_PAID_DATE,
               (SELECT COUNT(*) FROM LOAN.REPAYMENT_SCHEDULE S
                 WHERE S.LOAN_ID = L.LOAN_ID AND S.STATUS <> 'P')           AS INSTALMENTS_REMAINING,
               LAST_DAY(ADD_MONTHS(L.START_DATE, L.TERM_MONTHS))            AS FINAL_PAYMENT_MONTH_END,
               TIMESTAMPDIFF(64, CHAR(TIMESTAMP(UTIL.CURRENT_BUSINESS_DATE())
                                      - TIMESTAMP(L.START_DATE)))           AS MONTHS_ELAPSED
          FROM LOAN.LOAN L
          JOIN ACCT.ACCOUNT A ON A.ACCOUNT_ID = L.LOAN_ACCOUNT_ID
          LEFT JOIN (SELECT LOAN_ID, SUM(AMOUNT) AS TOTAL_REPAID, COUNT(*) AS REPAYMENT_COUNT,
                            MAX(PAID_DATE) AS LAST_PAID_DATE
                       FROM LOAN.REPAYMENT
                      WHERE LOAN_ID = P_LOAN_ID
                      GROUP BY LOAN_ID) R ON R.LOAN_ID = L.LOAN_ID
         WHERE L.LOAN_ID = P_LOAN_ID
          WITH UR;

    DECLARE C_SCHEDULE CURSOR WITH RETURN TO CLIENT FOR
        SELECT INSTALMENT_NO, DUE_DATE, PAYMENT, INTEREST, PRINCIPAL, BALANCE_AFTER, STATUS
          FROM LOAN.REPAYMENT_SCHEDULE
         WHERE LOAN_ID = P_LOAN_ID
           AND STATUS <> 'P'
         ORDER BY INSTALMENT_NO
          WITH UR;

    SELECT COUNT(*) INTO V_FOUND FROM LOAN.LOAN WHERE LOAN_ID = P_LOAN_ID WITH UR;
    IF V_FOUND = 0 THEN
        SIGNAL SQLSTATE '75013' SET MESSAGE_TEXT = 'Loan not found';
    END IF;

    OPEN C_SUMMARY;
    OPEN C_SCHEDULE;
END@

-- Internal helper for ACCRUE_INTEREST and CAPITALISE_INTEREST (not a scheduled job).
-- Accruals are 6dp per account but the GL is 2dp, so rather than posting rounded per-account
-- amounts (which drift) we true the accrual GLs up to the sub-ledger each run:
--   2210 (payable)    = -ROUND(SUM(ACCRUED_INTEREST) over accounts with a positive accrual, 2)
--   1210 (receivable) =  ROUND(-SUM(ACCRUED_INTEREST) over accounts with a negative accrual, 2)
-- The difference to the current GL balance is posted as one balanced pair each
-- (5100/2210 and 1210/4210; a negative difference is a reversal). LON accounts are excluded.
CREATE OR REPLACE PROCEDURE BATCH.TRUE_UP_ACCRUAL_GL (
    IN  P_BUSINESS_DATE  DATE,
    IN  P_CALLER         VARCHAR(40),
    OUT P_PAYABLE_ADJ    DECIMAL(15,2),
    OUT P_RECEIVABLE_ADJ DECIMAL(15,2)
)
    LANGUAGE SQL
    SPECIFIC BATCH_TRUE_UP_ACCRUAL_GL
    MODIFIES SQL DATA
BEGIN
    DECLARE V_PAYABLE_TARGET    DECIMAL(15,2);
    DECLARE V_RECEIVABLE_TARGET DECIMAL(15,2);
    DECLARE V_PAYABLE_GL        DECIMAL(15,2);
    DECLARE V_RECEIVABLE_GL     DECIMAL(15,2);
    DECLARE V_CORR              BIGINT;

    SELECT DECIMAL(ROUND(COALESCE(SUM(CASE WHEN A.ACCRUED_INTEREST > 0 THEN A.ACCRUED_INTEREST END), 0), 2), 15, 2),
           DECIMAL(ROUND(COALESCE(-SUM(CASE WHEN A.ACCRUED_INTEREST < 0 THEN A.ACCRUED_INTEREST END), 0), 2), 15, 2)
      INTO V_PAYABLE_TARGET, V_RECEIVABLE_TARGET
      FROM ACCT.ACCOUNT A
     WHERE A.ACCRUED_INTEREST <> 0
       AND A.PRODUCT_CODE IN (SELECT P.PRODUCT_CODE FROM REF.PRODUCT P WHERE P.PRODUCT_TYPE <> 'LON');

    SELECT COALESCE(-SUM(CASE WHEN GL_CODE = '2210' THEN AMOUNT END), 0),
           COALESCE(SUM(CASE WHEN GL_CODE = '1210' THEN AMOUNT END), 0)
      INTO V_PAYABLE_GL, V_RECEIVABLE_GL
      FROM GL.GL_ENTRY
     WHERE GL_CODE IN ('2210', '1210');

    SET P_PAYABLE_ADJ = V_PAYABLE_TARGET - V_PAYABLE_GL;
    SET P_RECEIVABLE_ADJ = V_RECEIVABLE_TARGET - V_RECEIVABLE_GL;

    IF P_PAYABLE_ADJ <> 0 OR P_RECEIVABLE_ADJ <> 0 THEN
        SET V_CORR = NEXT VALUE FOR TXN.SEQ_CORRELATION;
    END IF;

    IF P_PAYABLE_ADJ <> 0 THEN
        CALL UTIL.POST_GL_PAIR('5100', '2210', P_PAYABLE_ADJ, P_BUSINESS_DATE, V_CORR, NULL,
                               'Credit interest accrual true-up ' || P_CALLER);
    END IF;

    IF P_RECEIVABLE_ADJ <> 0 THEN
        CALL UTIL.POST_GL_PAIR('1210', '4210', P_RECEIVABLE_ADJ, P_BUSINESS_DATE, V_CORR, NULL,
                               'Overdraft interest accrual true-up ' || P_CALLER);
    END IF;
END@

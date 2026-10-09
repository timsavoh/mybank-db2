-- 'Y' when the current business date is the last business day of its month (the next
-- business day falls in another month) or ops forced month-end (BANK_CONTROL.FORCE_MONTH_END).
-- Called by the scheduler to decide whether MONTHEND jobs join tonight's EOD chain.
CREATE OR REPLACE FUNCTION BATCH.IS_MONTH_END ()
    RETURNS CHAR(1)
    LANGUAGE SQL
    SPECIFIC BATCH_IS_MONTH_END
    READS SQL DATA
    NOT DETERMINISTIC
    NO EXTERNAL ACTION
BEGIN
    DECLARE V_TODAY DATE;
    DECLARE V_FORCE CHAR(1);

    SELECT BUSINESS_DATE, FORCE_MONTH_END
      INTO V_TODAY, V_FORCE
      FROM REF.BANK_CONTROL
     WHERE CONTROL_ID = 1
      WITH UR;

    IF V_FORCE = 'Y' THEN
        RETURN 'Y';
    END IF;

    IF MONTH(UTIL.NEXT_BUSINESS_DAY(V_TODAY)) <> MONTH(V_TODAY) THEN
        RETURN 'Y';
    END IF;

    RETURN 'N';
END@

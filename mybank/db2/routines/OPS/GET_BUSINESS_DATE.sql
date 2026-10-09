-- Current business date and day status for the app header and ops console.
-- P_POSTING_DATE is what an online posting made now would be value-dated
-- (next business day once EOD cut-off has started). Raises 75015 if the control row is missing.
CREATE OR REPLACE PROCEDURE OPS.GET_BUSINESS_DATE (
    OUT P_BUSINESS_DATE      DATE,
    OUT P_PREV_BUSINESS_DATE DATE,
    OUT P_NEXT_BUSINESS_DATE DATE,
    OUT P_POSTING_DATE       DATE,
    OUT P_DAY_STATUS         CHAR(1),
    OUT P_DAY_OPENED_TS      TIMESTAMP,
    OUT P_MINUTES_PER_DAY    SMALLINT,
    OUT P_IS_MONTH_END       CHAR(1)
)
    LANGUAGE SQL
    SPECIFIC OPS_GET_BUSINESS_DATE
    READS SQL DATA
BEGIN
    DECLARE V_FORCE_ME CHAR(1);

    SELECT BUSINESS_DATE, PREV_BUSINESS_DATE, DAY_STATUS, DAY_OPENED_TS,
           MINUTES_PER_BUSINESS_DAY, FORCE_MONTH_END
      INTO P_BUSINESS_DATE, P_PREV_BUSINESS_DATE, P_DAY_STATUS, P_DAY_OPENED_TS,
           P_MINUTES_PER_DAY, V_FORCE_ME
      FROM REF.BANK_CONTROL
     WHERE CONTROL_ID = 1
      WITH UR;

    IF P_BUSINESS_DATE IS NULL THEN
        SIGNAL SQLSTATE '75015' SET MESSAGE_TEXT = 'Bank control record missing';
    END IF;

    SET P_NEXT_BUSINESS_DATE = UTIL.NEXT_BUSINESS_DAY(P_BUSINESS_DATE);
    SET P_POSTING_DATE = CASE WHEN P_DAY_STATUS = 'C' THEN P_NEXT_BUSINESS_DATE
                              ELSE P_BUSINESS_DATE END;

    -- Month-end runs on the last business day of the month
    SET P_IS_MONTH_END = CASE WHEN V_FORCE_ME = 'Y'
                                OR MONTH(P_NEXT_BUSINESS_DATE) <> MONTH(P_BUSINESS_DATE)
                              THEN 'Y' ELSE 'N' END;
END@

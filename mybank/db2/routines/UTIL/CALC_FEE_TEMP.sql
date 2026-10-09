-- TEMPORARY - hard-coded fee amounts until REF.FEE_SCHEDULE is loaded. Remove after go-live.
-- (KH 03/2016). Superseded by UTIL.CALC_FEE; the 2016 tariff below is long out of date.
CREATE OR REPLACE FUNCTION UTIL.CALC_FEE_TEMP (P_FEE_TYPE VARCHAR(10), P_AMOUNT DECIMAL(15,2))
    RETURNS DECIMAL(9,2)
    LANGUAGE SQL
    SPECIFIC UTIL_CALC_FEE_TEMP
    DETERMINISTIC
    NO EXTERNAL ACTION
    CONTAINS SQL
BEGIN
    DECLARE V_FEE DECIMAL(9,2) DEFAULT 0;

    IF P_FEE_TYPE = 'UNPAID' THEN
        SET V_FEE = 25.00;                    -- unpaid DD/SO (was 30.00 pre-2015)
    ELSEIF P_FEE_TYPE = 'CHAPS' THEN
        SET V_FEE = 30.00;
    ELSEIF P_FEE_TYPE = 'FX' THEN
        SET V_FEE = ROUND(ABS(P_AMOUNT) * 0.0299, 2);
    ELSEIF P_FEE_TYPE = 'CASHABROAD' THEN
        SET V_FEE = ROUND(ABS(P_AMOUNT) * 0.02, 2);
        IF V_FEE < 1.75 THEN
            SET V_FEE = 1.75;
        END IF;
    ELSEIF P_FEE_TYPE = 'CHQSTOP' THEN
        SET V_FEE = 10.00;
    ELSEIF P_FEE_TYPE = 'ODLETTER' THEN
        SET V_FEE = 15.00;                    -- TODO: confirm with Product - not in tariff
    END IF;

    RETURN V_FEE;
END@

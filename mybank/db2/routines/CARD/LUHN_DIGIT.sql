-- Luhn (mod 10) check digit for a 15-digit PAN body. Used by CARD.ISSUE_CARD.
CREATE OR REPLACE FUNCTION CARD.LUHN_DIGIT (P_BODY CHAR(15))
    RETURNS CHAR(1)
    LANGUAGE SQL
    SPECIFIC CARD_LUHN_DIGIT
    DETERMINISTIC
    NO EXTERNAL ACTION
    CONTAINS SQL
BEGIN
    DECLARE V_SUM   INTEGER DEFAULT 0;
    DECLARE V_I     INTEGER DEFAULT 15;
    DECLARE V_D     INTEGER;
    DECLARE V_FLIP  SMALLINT DEFAULT 1;

    -- Walk right to left; the rightmost body digit is doubled because the
    -- check digit will sit to its right
    WHILE V_I >= 1 DO
        SET V_D = INTEGER(SUBSTR(P_BODY, V_I, 1));
        IF V_FLIP = 1 THEN
            SET V_D = V_D * 2;
            IF V_D > 9 THEN
                SET V_D = V_D - 9;
            END IF;
        END IF;
        SET V_SUM = V_SUM + V_D;
        SET V_FLIP = 1 - V_FLIP;
        SET V_I = V_I - 1;
    END WHILE;

    RETURN CHAR(MOD(10 - MOD(V_SUM, 10), 10));
END@

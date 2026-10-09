-- ONE-OFF MIGRATION: 2015 product rationalisation. Moves accounts from retired product codes
-- to their replacements using ACCT.PRODUCT_CODE_MAP. Run 14/02/2015 (CHG0031140).
-- P_DRY_RUN = 'Y' just counts. Re-runnable: only picks up rows not yet MIGRATED.
CREATE OR REPLACE PROCEDURE ACCT.MIGRATE_PRODUCT_CODES (
    IN  P_DRY_RUN        CHAR(1),
    OUT P_ACCOUNTS_MOVED INTEGER
)
    LANGUAGE SQL
    SPECIFIC ACCT_MIGRATE_PRODUCT_CODES
    MODIFIES SQL DATA
BEGIN
    DECLARE V_ROWS INTEGER DEFAULT 0;

    SET P_ACCOUNTS_MOVED = 0;

    MAP_LOOP:
    FOR M AS C_MAP CURSOR WITH HOLD FOR
        SELECT OLD_PRODUCT_CODE, NEW_PRODUCT_CODE
          FROM ACCT.PRODUCT_CODE_MAP
         WHERE MIGRATED = 'N'
         ORDER BY OLD_PRODUCT_CODE
    DO
        IF P_DRY_RUN = 'Y' THEN
            SELECT COUNT(*) INTO V_ROWS
              FROM ACCT.ACCOUNT
             WHERE PRODUCT_CODE = M.OLD_PRODUCT_CODE;
        ELSE
            UPDATE ACCT.ACCOUNT
               SET PRODUCT_CODE = M.NEW_PRODUCT_CODE
             WHERE PRODUCT_CODE = M.OLD_PRODUCT_CODE;
            GET DIAGNOSTICS V_ROWS = ROW_COUNT;

            UPDATE ACCT.PRODUCT_CODE_MAP
               SET MIGRATED = 'Y',
                   ACCOUNTS_MOVED = V_ROWS,
                   MIGRATED_TS = CURRENT TIMESTAMP
             WHERE OLD_PRODUCT_CODE = M.OLD_PRODUCT_CODE;

            -- rates: new product's tiers apply from next accrual. TODO re-rate mid-month? (PB)
            COMMIT;
        END IF;

        SET P_ACCOUNTS_MOVED = P_ACCOUNTS_MOVED + V_ROWS;
    END FOR MAP_LOOP;

    /* standing orders on the old savings product were cancelled by hand, not here
    UPDATE PAY.STANDING_ORDER SET STATUS = 'C'
     WHERE ACCOUNT_ID IN (SELECT ACCOUNT_ID FROM ACCT.ACCOUNT WHERE PRODUCT_CODE = 'SAV003');
    */
END@

-- MyBank plc: legacy table cleanup
-- Statement terminator: @
--
-- Run AFTER all routines are deployed. Drops the tables from 05_legacy.sql that were retired
-- in production, but (as in production) not the routines that use them. With the default
-- AUTO_REVAL = DEFERRED, Db2 lets the DROP through and marks each dependent SQL routine
-- invalid: SYSCAT.ROUTINES.VALID = 'N', its package VALID = 'X' (inoperative), and a row in
-- SYSCAT.INVALIDOBJECTS. Calling one fails revalidation with SQL0727N / SQLSTATE 56098
-- (reason SQL0204N: table not found). Left invalid on purpose:
--   ACCT.MIGRATE_PRODUCT_CODES   (ACCT.PRODUCT_CODE_MAP)
--   CHQ.CLEAR_CHEQUE             (CHQ.CLEARING_BATCH)
--   BATCH.ACCRUE_INTEREST_2019   (REF.INTEREST_RATE_2019)
--   RPT.MONTHLY_SUMMARY_BAK      (RPT.MONTHLY_SUMMARY)
--
-- To list them:
--   SELECT ROUTINESCHEMA, ROUTINENAME, VALID FROM SYSCAT.ROUTINES WHERE VALID <> 'Y'
--   SELECT OBJECTSCHEMA, OBJECTNAME, OBJECTTYPE FROM SYSCAT.INVALIDOBJECTS
-- Don't run SYSPROC.ADMIN_REVALIDATE_DB_OBJECTS expecting it to fix them - it can't.

-- CHG0031140 follow-up: product code migration complete (2015). Map table no longer needed.
DROP TABLE ACCT.PRODUCT_CODE_MAP@

-- CHG0052210: cheque clearing moved to the ICS supplier (2019). Batch table retired.
DROP TABLE CHQ.CLEARING_BATCH@

-- CHG0055019: 2019 rate model change; rates now in REF.INTEREST_RATE_TIER.
DROP TABLE REF.INTEREST_RATE_2019@

-- CHG0047730: monthly MI moved to the reporting MQTs (2018).
DROP TABLE RPT.MONTHLY_SUMMARY@

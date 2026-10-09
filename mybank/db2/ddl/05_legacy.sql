-- MyBank plc: legacy tables
-- Statement terminator: @
--
-- Tables that only the legacy (never-called) routines reference. They are created here so
-- those routines compile, then 99_legacy_cleanup.sql (run AFTER the routines are deployed)
-- drops most of them again - reproducing what happened in production, where the tables were
-- dropped years ago and the routines were left behind, marked invalid in SYSCAT.ROUTINES.
--
-- Deploy order: 01..04 ddl, seed, 05_legacy.sql, routines, 99_legacy_cleanup.sql.

------------------------------------------------------------------------------
-- Product code mapping for the 2015 product rationalisation
-- (ACCT.MIGRATE_PRODUCT_CODES). Dropped by 99_legacy_cleanup.sql.
------------------------------------------------------------------------------
CREATE TABLE ACCT.PRODUCT_CODE_MAP (
    OLD_PRODUCT_CODE CHAR(6)     NOT NULL,
    NEW_PRODUCT_CODE CHAR(6)     NOT NULL,
    MAP_REASON       VARCHAR(60),
    MIGRATED         CHAR(1)     NOT NULL WITH DEFAULT 'N',
    ACCOUNTS_MOVED   INTEGER,
    MIGRATED_TS      TIMESTAMP,
    CONSTRAINT PK_PRODUCT_CODE_MAP PRIMARY KEY (OLD_PRODUCT_CODE)
) IN TS_DATA@

INSERT INTO ACCT.PRODUCT_CODE_MAP (OLD_PRODUCT_CODE, NEW_PRODUCT_CODE, MAP_REASON, MIGRATED, ACCOUNTS_MOVED, MIGRATED_TS) VALUES
    ('SAV003', 'SAV001', 'Instant Access Classic withdrawn 31/12/2014', 'Y', 412, '2015-02-14-02.11.37.000000'),
    ('CUR9OL', 'CUR001', 'Pre-2008 current account (CA01)',              'Y', 1873, '2015-02-14-02.14.02.000000'),
    ('CUR9GR', 'CUR003', 'Graduate account folded into Student',        'N', NULL, NULL)@

------------------------------------------------------------------------------
-- Cheque clearing batches (CHQ.CLEAR_CHEQUE). Cheque clearing moved to the
-- Image Clearing System supplier in 2019. Dropped by 99_legacy_cleanup.sql.
------------------------------------------------------------------------------
CREATE TABLE CHQ.CLEARING_BATCH (
    BATCH_ID       INTEGER       NOT NULL,
    BUSINESS_DATE  DATE          NOT NULL,
    STATUS         CHAR(1)       NOT NULL WITH DEFAULT 'O',
    ITEM_COUNT     INTEGER       NOT NULL WITH DEFAULT 0,
    TOTAL_AMOUNT   DECIMAL(15,2) NOT NULL WITH DEFAULT 0,
    RETURNED_COUNT INTEGER       NOT NULL WITH DEFAULT 0,
    OPENED_TS      TIMESTAMP     NOT NULL WITH DEFAULT CURRENT TIMESTAMP,
    CLOSED_TS      TIMESTAMP,
    CONSTRAINT PK_CLEARING_BATCH PRIMARY KEY (BATCH_ID),
    CONSTRAINT CK_CLEARING_STATUS CHECK (STATUS IN ('O', 'C', 'X'))
) IN TS_DATA@

------------------------------------------------------------------------------
-- 2019 savings rate bands (BATCH.ACCRUE_INTEREST_2019), replaced by
-- REF.INTEREST_RATE_TIER in the 2019 rate model change. Dropped by 99_legacy_cleanup.sql.
------------------------------------------------------------------------------
CREATE TABLE REF.INTEREST_RATE_2019 (
    PRODUCT_CODE CHAR(6)       NOT NULL,
    BAND_FROM    DECIMAL(15,2) NOT NULL,
    BAND_TO      DECIMAL(15,2),
    GROSS_RATE   DECIMAL(7,4)  NOT NULL,
    AER          DECIMAL(7,4)  NOT NULL,
    CONSTRAINT PK_INTEREST_RATE_2019 PRIMARY KEY (PRODUCT_CODE, BAND_FROM)
) IN TS_DATA@

INSERT INTO REF.INTEREST_RATE_2019 (PRODUCT_CODE, BAND_FROM, BAND_TO, GROSS_RATE, AER) VALUES
    ('SAV001',     0.00,  1000.00, 0.2500, 0.2500),
    ('SAV001',  1000.00, 10000.00, 0.5000, 0.5000),
    ('SAV001', 10000.00,     NULL, 0.7500, 0.7500),
    ('SAV002',     0.00,     NULL, 1.2000, 1.2100),
    ('SAV003',     0.00,     NULL, 0.1000, 0.1000)@

------------------------------------------------------------------------------
-- Month-end summary table loaded by the old monthly MI job (RPT.MONTHLY_SUMMARY_BAK is a
-- copy of its loader). Replaced by the MQTs in 2018. Dropped by 99_legacy_cleanup.sql.
------------------------------------------------------------------------------
CREATE TABLE RPT.MONTHLY_SUMMARY (
    MONTH_END     DATE          NOT NULL,
    PRODUCT_CODE  CHAR(6)       NOT NULL,
    ACCOUNTS      INTEGER       NOT NULL,
    TOTAL_BALANCE DECIMAL(17,2) NOT NULL,
    TXN_COUNT     INTEGER       NOT NULL,
    TOTAL_IN      DECIMAL(17,2) NOT NULL,
    TOTAL_OUT     DECIMAL(17,2) NOT NULL,
    LOADED_TS     TIMESTAMP     NOT NULL WITH DEFAULT CURRENT TIMESTAMP,
    CONSTRAINT PK_MONTHLY_SUMMARY PRIMARY KEY (MONTH_END, PRODUCT_CODE)
) IN TS_DATA@

------------------------------------------------------------------------------
-- Developer trace table written by UTIL.DEBUG_DUMP_ACCOUNT. Nobody dropped this one;
-- nothing else reads it.
------------------------------------------------------------------------------
CREATE TABLE OPS.DEBUG_TRACE (
    TRACE_ID   BIGINT        NOT NULL GENERATED ALWAYS AS IDENTITY (START WITH 1),
    TRACE_TS   TIMESTAMP     NOT NULL WITH DEFAULT CURRENT TIMESTAMP,
    TRACED_BY  VARCHAR(128)  NOT NULL WITH DEFAULT USER,
    SOURCE     VARCHAR(40)   NOT NULL,
    KEY_VALUE  VARCHAR(40),
    DETAIL     VARCHAR(1000),
    CONSTRAINT PK_DEBUG_TRACE PRIMARY KEY (TRACE_ID)
) IN TS_DATA@

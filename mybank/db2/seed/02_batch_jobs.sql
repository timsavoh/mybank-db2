-- MyBank plc: batch job catalogue, read by the external scheduler (app, scheduler profile).
-- Statement terminator: @
--
--   INTRADAY  every wall-clock minute, in CHAIN_SEQ order
--   EOD       the end-of-day chain, every MINUTES_PER_BUSINESS_DAY (5) wall-clock minutes,
--             run strictly in CHAIN_SEQ order; stop the chain on the first failure
--   MONTHEND  part of the same chain, included only when BATCH.IS_MONTH_END() = 'Y'
--   NIGHTLY   part of the same chain, every EOD
--   DB2TASK   scheduled inside Db2 by SYSPROC.ADMIN_TASK_ADD (db2/tasks/admin_tasks.sql);
--             the external scheduler must not run these
--
-- Chain jobs take one OUT parameter: CALL <PROC_NAME>(?)  (rows processed).
-- DB2TASK jobs take no parameters.

INSERT INTO OPS.BATCH_JOB (JOB_NAME, DESCRIPTION, PROC_NAME, SCHEDULE_TYPE, CHAIN_SEQ) VALUES
    ('EXPIRE_CARD_AUTHS',        'Expire lapsed holds and their card authorisations',               'BATCH.EXPIRE_CARD_AUTHS',        'INTRADAY', 1),
    ('PROCESS_PAYMENT_QUEUE',    'Post queued pending transactions whose value date has arrived',   'BATCH.PROCESS_PAYMENT_QUEUE',    'INTRADAY', 2),
    ('DISPATCH_NOTIFICATIONS',   'Send queued customer notifications (outbox)',                     'BATCH.DISPATCH_NOTIFICATIONS',   'INTRADAY', 3),

    ('EOD_CUTOFF',               'Cut off the business day: online postings move to next day',      'BATCH.EOD_CUTOFF',               'EOD',      10),
    ('SETTLE_CARD_TRANSACTIONS', 'Settle approved card authorisations into posted transactions',    'BATCH.SETTLE_CARD_TRANSACTIONS', 'EOD',      20),
    ('RUN_STANDING_ORDERS',      'Pay standing orders due today',                                   'BATCH.RUN_STANDING_ORDERS',      'EOD',      30),
    ('COLLECT_DIRECT_DEBITS',    'Collect direct debits due today',                                 'BATCH.COLLECT_DIRECT_DEBITS',    'EOD',      40),
    ('ASSESS_FEES',              'Over-limit and monthly account fees',                             'BATCH.ASSESS_FEES',              'EOD',      50),
    ('ACCRUE_INTEREST',          'Daily interest accrual on deposit and overdrawn accounts',        'BATCH.ACCRUE_INTEREST',          'EOD',      60),
    ('FLAG_DORMANT_ACCOUNTS',    'Mark accounts with no customer activity for 12 months dormant',  'BATCH.FLAG_DORMANT_ACCOUNTS',    'EOD',      70),
    ('RUN_FRAUD_RULES',          'Run the SQL fraud rules in RISK.FRAUD_RULE and raise alerts',     'BATCH.RUN_FRAUD_RULES',          'EOD',      80),

    ('CAPITALISE_INTEREST',      'Pay/charge accrued interest to accounts',                         'BATCH.CAPITALISE_INTEREST',      'MONTHEND', 100),
    ('LOAN_REPAYMENT_RUN',       'Collect loan instalments due; arrears handling',                  'BATCH.LOAN_REPAYMENT_RUN',       'MONTHEND', 110),
    ('GENERATE_STATEMENTS',      'Monthly account statements with XML rendition',                   'BATCH.GENERATE_STATEMENTS',      'MONTHEND', 120),
    ('MONTH_END_GL_CLOSE',       'Month-end GL snapshot rolled up the chart of accounts',           'BATCH.MONTH_END_GL_CLOSE',       'MONTHEND', 130),

    ('SNAPSHOT_DAILY_BALANCES',  'End-of-day account balance snapshot',                             'BATCH.SNAPSHOT_DAILY_BALANCES',  'EOD',      150),
    ('GL_RECONCILE',             'Ledger invariants and daily GL balances; writes recon breaks',    'BATCH.GL_RECONCILE',             'EOD',      160),
    ('ARCHIVE_AND_PURGE',        'Archive old transactions, compress GL, purge history',            'BATCH.ARCHIVE_AND_PURGE',        'NIGHTLY',  170),
    ('ROLL_BUSINESS_DATE',       'Roll to the next business day and reopen',                        'BATCH.ROLL_BUSINESS_DATE',       'EOD',      999),

    ('PURGE_AUDIT_LOG',          'Purge old audit and error log rows (Db2 admin task, hourly)',     'BATCH.PURGE_AUDIT_LOG',          'DB2TASK',  NULL),
    ('REFRESH_REPORTING_MQTS',   'Refresh reporting MQTs (Db2 admin task, every 15 minutes)',       'BATCH.REFRESH_REPORTING_MQTS',   'DB2TASK',  NULL),
    ('RUNSTATS',                 'Statistics on high-churn tables (Db2 admin task, every 30 min)',  'BATCH.RUNSTATS',                 'DB2TASK',  NULL)@

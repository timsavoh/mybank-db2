# MyBank — source system design

MyBank plc is a fictional UK retail bank running on Db2 LUW. It exists to be migrated to
PostgreSQL. It should look like a real 15-year-old Db2 estate: layered schemas, a lot of
SQL PL, batch chains, a few things nobody remembers writing, and Db2-isms everywhere.

## Components

| Component | Tech | Role |
|---|---|---|
| `db2` | Db2 Community Edition 12.1 | Source database, database `MYBANK` |
| `app` | Java 17, Spring Boot, Db2 JCC driver | REST API calling stored procedures, plus a small web UI (teller, reports, ops console) |
| `scheduler` | Same jar, `scheduler` profile | Stand-in for Control-M: job definitions in YAML, dependencies, run history in Db2 |
| `loadgen` | Same jar, `loadgen` profile | Simulated customers, card network and inbound payment scheme. Calls the app's HTTP API, never the DB |

A handful of jobs are also scheduled inside Db2 via `SYSPROC.ADMIN_TASK_ADD`, the way some
shops do it, so the migration has to deal with two schedulers.

## Compressed time

The bank runs on a **business date** held in `REF.BANK_CONTROL`, separate from the wall clock.
Real banks do this, and it lets us run the whole batch calendar at demo speed.

- **1 business day = 5 minutes** of wall clock (configurable: `MINUTES_PER_BUSINESS_DAY`).
- Weekends and UK bank holidays exist in `REF.HOLIDAY` and roll over in seconds. Standing
  orders and direct debits due on non-business days roll forward, so "Mondays" are heavier.
- **Intraday jobs** run every minute of wall clock.
- **End-of-day chain** runs at the end of each business day (every 5 min) and ends by rolling the date.
- **Month-end** runs on the last business day of the month: roughly every 1h45m of wall clock.
  The ops console also has a "Force month-end" button for demos.
- Interest accrues per *calendar* day elapsed, so Monday's accrual covers the weekend.

## Data footprint (local target < 1 GB)

| Item | Seed | Steady state |
|---|---|---|
| Customers | 10,000 | grows slowly (~20/business day) |
| Accounts | ~18,000 | grows slowly |
| Cards | ~12,000 | |
| Posted transactions | 60 business days, ~300k (~5,000/day incl. standing orders, direct debits, salaries) | purged beyond 60 business days |
| Load generator | — | ~10 TPS default, slider 0–200 TPS |

`BATCH.ARCHIVE_AND_PURGE` keeps the database bounded. On DigitalOcean the retention is raised
and the seed scaled up; nothing else changes.

## Schemas and tables

Schemas are deliberately split the way a real estate grows over time.

| Schema | Tables |
|---|---|
| `REF` | `BANK_CONTROL`, `HOLIDAY`, `BRANCH`, `GL_ACCOUNT` (chart of accounts, hierarchical), `PRODUCT`, `INTEREST_RATE_TIER`, `FEE_SCHEDULE`, `MERCHANT_CATEGORY` |
| `CUST` | `CUSTOMER`, `ADDRESS`, `CONTACT`, `KYC_CHECK` |
| `ACCT` | `ACCOUNT`, `ACCOUNT_HOLDER` (joint accounts), `ACCOUNT_HOLD`, `DAILY_BALANCE`, `INTEREST_ACCRUAL` |
| `TXN` | `POSTED_TXN`, `PENDING_TXN`, `POSTED_TXN_ARCHIVE` |
| `CARD` | `CARD`, `MERCHANT`, `AUTHORISATION`, `DISPUTE` |
| `PAY` | `PAYEE`, `PAYMENT`, `STANDING_ORDER`, `DD_MANDATE`, `DD_COLLECTION` |
| `LOAN` | `LOAN`, `REPAYMENT_SCHEDULE`, `REPAYMENT` |
| `GL` | `GL_ENTRY`, `GL_DAILY_BALANCE`, `RECON_BREAK` |
| `RISK` | `FRAUD_RULE` (rules stored as SQL predicates), `FRAUD_ALERT` |
| `OPS` | `BATCH_JOB`, `BATCH_JOB_RUN`, `AUDIT_LOG`, `ERROR_LOG`, `NOTIFICATION_OUTBOX`, `STATEMENT`, `STATEMENT_LINE` |
| `CHQ` | `CHEQUE_BOOK`, `CHEQUE` (discontinued product; tables still there) |

Plus: sequences for customer, account, card and statement numbers; identity columns elsewhere;
`ROW CHANGE TIMESTAMP` columns on the main tables; ~8 views; 2 materialized query tables
(`RPT.MQT_DAILY_LIQUIDITY`, `RPT.MQT_MERCHANT_SPEND`, `REFRESH DEFERRED`).

### The ledger invariant

Every money movement goes through `UTIL.POST_LEDGER_ENTRY`, which writes the customer-side
`POSTED_TXN` and a balanced pair of `GL_ENTRY` rows. Two checks hold at all times on the source:

1. `SUM(GL_ENTRY.AMOUNT) = 0`
2. `SUM(ACCOUNT.LEDGER_BALANCE) = GL balance of the customer-deposits control account`

These are the validation service's headline checks after migration.

## Stored procedures and functions (100)

"Db2 features" is what makes each one interesting to convert.

### Online — called by the app (40)

| # | Name | Does | Db2 features exercised |
|---|---|---|---|
| 1 | `CUST.CREATE_CUSTOMER` | New customer, returns id | Identity, `SIGNAL`, OUT params |
| 2 | `CUST.UPDATE_CONTACT` | Change contact details | `MERGE` |
| 3 | `CUST.GET_CUSTOMER_360` | Customer, accounts, recent activity | **3 dynamic result sets** |
| 4 | `CUST.SEARCH_CUSTOMERS` | Search with optional filters, paging | Dynamic SQL `PREPARE`/`EXECUTE`, `FETCH FIRST`, `ROW_NUMBER()` |
| 5 | `CUST.RECORD_KYC_CHECK` | Store KYC outcome | `CURRENT TIMESTAMP`, check constraints |
| 6 | `CUST.CLOSE_CUSTOMER` | Close if all accounts closed | `EXIT HANDLER`, nested `CALL` |
| 7 | `CUST.GET_STATEMENT` | Statement header and lines | 2 result sets, `VARCHAR_FORMAT` |
| 8 | `ACCT.OPEN_ACCOUNT` | Open account for a product | `NEXT VALUE FOR`, modulus-check UDF |
| 9 | `ACCT.CLOSE_ACCOUNT` | Sweep balance, close | Nested calls, `SAVEPOINT` / `ROLLBACK TO SAVEPOINT` |
| 10 | `ACCT.ADD_JOINT_HOLDER` | Add second holder | `SQLSTATE` custom codes |
| 11 | `ACCT.GET_BALANCE` | Ledger and available balance | `WITH UR`, scalar UDF |
| 12 | `ACCT.GET_TRANSACTIONS` | Paged history with running balance | `SUM() OVER (ORDER BY ...)`, result set |
| 13 | `ACCT.PLACE_HOLD` | Ring-fence funds | `SELECT ... FROM FINAL TABLE (INSERT ...)` |
| 14 | `ACCT.RELEASE_HOLD` | Release a hold | `GET DIAGNOSTICS ROW_COUNT` |
| 15 | `ACCT.SET_OVERDRAFT_LIMIT` | Change limit, audited | `CONTINUE HANDLER` |
| 16 | `ACCT.CHANGE_PRODUCT` | Switch product, re-rate | `MERGE`, date arithmetic |
| 17 | `ACCT.FREEZE_ACCOUNT` | Freeze/unfreeze | `SIGNAL` in `IF` |
| 18 | `PAY.TRANSFER_FUNDS` | Internal transfer | Handlers, `WITH RS USE AND KEEP UPDATE LOCKS`, lock ordering |
| 19 | `PAY.CREATE_PAYEE` | Add payee | Sort-code UDF |
| 20 | `PAY.SEND_FASTER_PAYMENT` | Outbound payment | Limits, fraud call, pending txn |
| 21 | `PAY.RECEIVE_INBOUND_PAYMENT` | Inbound from scheme | `MERGE` on idempotency key |
| 22 | `PAY.CREATE_STANDING_ORDER` | New standing order | Business-day UDF |
| 23 | `PAY.CANCEL_STANDING_ORDER` | Cancel | |
| 24 | `PAY.CREATE_DD_MANDATE` | New direct debit mandate | |
| 25 | `PAY.CANCEL_DD_MANDATE` | Cancel mandate | |
| 26 | `PAY.DEPOSIT_CASH` | Branch deposit | GL posting |
| 27 | `PAY.WITHDRAW_CASH` | ATM/branch withdrawal | Available-balance check |
| 28 | `CARD.ISSUE_CARD` | Issue card | `NEXT VALUE FOR`, PAN masking UDF |
| 29 | `CARD.AUTHORISE` | **Hot path**: approve/decline card auth | Declines returned as ISO response codes (a `SIGNAL` would roll back the decline record), hold, fraud score |
| 30 | `CARD.REVERSE_AUTH` | Reverse an auth | |
| 31 | `CARD.BLOCK_CARD` | Lost/stolen | |
| 32 | `CARD.RAISE_DISPUTE` | Dispute a transaction | |
| 33 | `CARD.GET_CARD_ACTIVITY` | Recent auths | Result set, `TIMESTAMPDIFF` |
| 34 | `LOAN.QUOTE_LOAN` | Amortisation schedule | `DECLARE GLOBAL TEMPORARY TABLE`, `DECIMAL` rounding, result set |
| 35 | `LOAN.ORIGINATE_LOAN` | Book loan, disburse | Multi-row insert of schedule |
| 36 | `LOAN.MAKE_REPAYMENT` | Ad-hoc repayment | |
| 37 | `LOAN.GET_LOAN_SUMMARY` | Loan position | |
| 38 | `OPS.GET_BUSINESS_DATE` | Current business date and status | |
| 39 | `RISK.GET_OPEN_ALERTS` | Alert queue | Result set |
| 40 | `RISK.RESOLVE_ALERT` | Close an alert | |

### Batch — scheduled (22)

| # | Name | Schedule | Db2 features exercised |
|---|---|---|---|
| 41 | `BATCH.EXPIRE_CARD_AUTHS` | Intraday, 1 min | Set-based `DELETE` |
| 42 | `BATCH.PROCESS_PAYMENT_QUEUE` | Intraday, 1 min | Cursor loop, per-row handler |
| 43 | `BATCH.DISPATCH_NOTIFICATIONS` | Intraday, 1 min | `SKIP LOCKED DATA` |
| 44 | `BATCH.EOD_CUTOFF` | EOD step 1 | Control-table state machine |
| 45 | `BATCH.SETTLE_CARD_TRANSACTIONS` | EOD | `MERGE`, auth → posted |
| 46 | `BATCH.RUN_STANDING_ORDERS` | EOD | Holiday calendar roll-forward |
| 47 | `BATCH.COLLECT_DIRECT_DEBITS` | EOD | Unpaid returns on insufficient funds |
| 48 | `BATCH.ASSESS_FEES` | EOD | Window functions, fee UDF |
| 49 | `BATCH.ACCRUE_INTEREST` | EOD | Cursor `WITH HOLD`, commit every N, `DAYS()`, tiered rates |
| 50 | `BATCH.SNAPSHOT_DAILY_BALANCES` | EOD | Big `INSERT ... SELECT` |
| 51 | `BATCH.FLAG_DORMANT_ACCOUNTS` | EOD | `ADD_MONTHS` |
| 52 | `BATCH.RUN_FRAUD_RULES` | EOD | **Dynamic SQL built from `RISK.FRAUD_RULE` rows** (`:BDATE` token replaced with a literal): Db2 SQL hiding in data |
| 53 | `BATCH.GL_RECONCILE` | EOD | Ledger invariant, writes breaks |
| 54 | `BATCH.ROLL_BUSINESS_DATE` | EOD final step | Next-business-day UDF |
| 55 | `BATCH.CAPITALISE_INTEREST` | Month-end | `LAST_DAY()`, posting accruals |
| 56 | `BATCH.GENERATE_STATEMENTS` | Month-end | `XMLELEMENT` / `XMLAGG` statement documents |
| 57 | `BATCH.LOAN_REPAYMENT_RUN` | Month-end | Arrears handling |
| 58 | `BATCH.MONTH_END_GL_CLOSE` | Month-end | Recursive CTE over GL hierarchy |
| 59 | `BATCH.ARCHIVE_AND_PURGE` | Nightly | Move-then-delete in chunks, keeps DB < 1 GB |
| 60 | `BATCH.PURGE_AUDIT_LOG` | Db2 `ADMIN_TASK_ADD` | |
| 61 | `BATCH.REFRESH_REPORTING_MQTS` | Db2 `ADMIN_TASK_ADD` | `REFRESH TABLE` |
| 62 | `BATCH.RUNSTATS` | Db2 `ADMIN_TASK_ADD` | `CALL SYSPROC.ADMIN_CMD('RUNSTATS ...')` |

### Internal helpers and functions (16)

| # | Name | Kind | Db2 features exercised |
|---|---|---|---|
| 63 | `UTIL.POST_LEDGER_ENTRY` | Procedure | The core double-entry poster everything calls |
| 64 | `UTIL.POST_GL_PAIR` | Procedure | |
| 65 | `UTIL.CHECK_ACCOUNT_STATUS` | Procedure | `SIGNAL` with custom SQLSTATEs |
| 66 | `UTIL.LOG_ERROR` | Procedure | **`AUTONOMOUS`**: commits even if caller rolls back. PostgreSQL has no equivalent |
| 67 | `UTIL.WRITE_AUDIT` | Procedure | |
| 68 | `UTIL.RAISE_FRAUD_ALERT` | Procedure | |
| 69 | `UTIL.ENQUEUE_NOTIFICATION` | Procedure | |
| 70 | `UTIL.START_JOB_RUN` / `END_JOB_RUN` | Procedure | Batch bookkeeping |
| 71 | `UTIL.AVAILABLE_BALANCE` | Scalar UDF | |
| 72 | `UTIL.CALC_FEE` | Scalar UDF | |
| 73 | `UTIL.INTEREST_RATE` | Scalar UDF | Tier lookup |
| 74 | `UTIL.NEXT_BUSINESS_DAY` | Scalar UDF | Loop over holiday calendar |
| 75 | `UTIL.MODULUS_CHECK` | Scalar UDF | Sort code/account check digit |
| 76 | `UTIL.MASK_PAN` | Scalar UDF | `REPEAT`, `SUBSTR` |
| 77 | `UTIL.FORMAT_SORT_CODE` | Scalar UDF | `VARCHAR_FORMAT`, `LPAD` |
| 78 | `UTIL.SPLIT_REFERENCE` | Table UDF | `RETURNS TABLE` |

### Reporting — called from the reports page (10)

| # | Name | Db2 features exercised |
|---|---|---|
| 79 | `RPT.DAILY_TXN_SUMMARY` | `GROUP BY ROLLUP` |
| 80 | `RPT.TOP_MERCHANTS` | `RANK() OVER`, reads MQT |
| 81 | `RPT.BRANCH_PERFORMANCE` | `GROUPING SETS` |
| 82 | `RPT.OVERDRAWN_ACCOUNTS` | |
| 83 | `RPT.LIQUIDITY_POSITION` | Reads MQT (optimizer routing) |
| 84 | `RPT.CUSTOMER_SEGMENTATION` | `NTILE`, `CASE` |
| 85 | `RPT.FRAUD_ALERT_TRENDS` | `WEEK_ISO`, `DAYOFWEEK`, `TIMESTAMP_FORMAT` |
| 86 | `RPT.LOAN_BOOK_AGEING` | `TIMESTAMPDIFF` buckets |
| 87 | `RPT.GL_TRIAL_BALANCE` | Recursive CTE (no `RECURSIVE` keyword) |
| 88 | `RPT.DORMANT_ACCOUNTS` | `LISTAGG` |

### Legacy — never called (12)

Planted for the inventory stage to find. Some reference tables that no longer exist, so they
fail to compile on Postgres and would waste effort if converted blindly.

| # | Name | Story |
|---|---|---|
| 89 | `PAY.TRANSFER_FUNDS_V1` | Superseded in 2019 |
| 90 | `CARD.AUTHORISE_OLD` | Pre-contactless version |
| 91 | `BATCH.ACCRUE_INTEREST_2019` | Old rate model |
| 92 | `RPT.MONTHLY_SUMMARY_BAK` | Someone's backup copy |
| 93 | `CUST.MERGE_DUPLICATE_CUSTOMERS` | One-off data fix, left behind |
| 94 | `UTIL.CALC_FEE_TEMP` | "Temporary" |
| 95 | `ACCT.MIGRATE_PRODUCT_CODES` | One-off migration |
| 96 | `CHQ.ISSUE_CHEQUE_BOOK` | Cheques discontinued |
| 97 | `CHQ.CLEAR_CHEQUE` | Cheques discontinued |
| 98 | `CHQ.STOP_CHEQUE` | Cheques discontinued |
| 99 | `LOAN.QUOTE_LOAN_TEST` | Test copy |
| 100 | `UTIL.DEBUG_DUMP_ACCOUNT` | Developer debugging aid |

## Triggers (~12)

- Row-level audit triggers on `CUSTOMER`, `ACCOUNT`, `CARD` (inline `MODE DB2SQL` bodies)
- `BEFORE INSERT` on `POSTED_TXN` defaulting the business date from `BANK_CONTROL`
- `BEFORE UPDATE` on `POSTED_TXN` that `SIGNAL`s: posted transactions are immutable
- Statement-level trigger with `REFERENCING NEW TABLE` summarising bulk loads
- `INSTEAD OF` trigger on a view used by the teller screen
- `AFTER UPDATE` on `ACCOUNT` maintaining `LAST_ACTIVITY_DATE`

Every trigger that writes rows is a CDC double-fire risk on the target, and the conversion
inventory flags it as such.

## Db2 feature coverage

Checklist of what a migration team will have to handle, with where it appears:

- Result sets from procedures: 3, 7, 12, 33, 34, 39, reports
- Condition handlers (`EXIT`, `CONTINUE`, `UNDO`): 6, 15, 18, 42
- `SIGNAL` and custom SQLSTATEs the app depends on: 1, 10, 17, 29, 65
- Autonomous transactions: 66
- Global temporary tables: 34
- Dynamic SQL, including SQL stored in data: 4, 52
- `MERGE`, `FINAL TABLE`, `SKIP LOCKED DATA`, isolation clauses: 2, 13, 18, 21, 43
- Db2 date and format functions: 7, 49, 51, 55, 77, 85, 86
- XML functions: 56
- Materialized query tables and `REFRESH TABLE`: 61, 80, 83
- Admin routines (`ADMIN_CMD`, `ADMIN_TASK_ADD`): 60–62
- Sequences, identity, `ROW CHANGE TIMESTAMP`: schema-wide
- Uppercase identifiers and multiple schemas: schema-wide
- Application code catching Db2 `SQLCODE`s (-803, -438): `app`

## Repo layout

```
mybank/
  docs/design.md
  db2/
    ddl/           schemas, tables, sequences, views, MQTs, triggers
    routines/      one file per routine, by schema
    seed/          reference data and generated seed
    seed/generate.py  deterministic seed generator (Python -> DEL files -> Db2 LOAD)
    tasks/         ADMIN_TASK_ADD registrations
    deploy.sh      builds the database from scratch in dependency order
    sql.sh         run SQL against the container
  app/             Spring Boot (profiles: api, scheduler, loadgen)
  docker-compose.yml
```

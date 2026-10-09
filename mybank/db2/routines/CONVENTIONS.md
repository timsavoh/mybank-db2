# Routine conventions

Read `mybank/docs/design.md` first for the domain and the full routine list.
DDL is in `db2/ddl/` (tables `02_tables.sql`, views/MQTs `03_views.sql`, triggers `04_triggers.sql`).
Reference data is in `db2/seed/01_reference.sql`. The core helpers in `routines/UTIL/` are done
and tested; build on them, don't change them.

## Files and deployment

- One routine per file: `db2/routines/<SCHEMA>/<NAME>.sql`, statement terminator `@`.
- `CREATE OR REPLACE PROCEDURE|FUNCTION`, always with `SPECIFIC <SCHEMA>_<NAME>`.
- Header: 1–3 comment lines saying what it does, who calls it, and any SQLSTATEs it raises.
- Compile: `db2/deploy_routines.sh <SCHEMA>` (from `mybank/`). Retries until dependencies resolve.
- Ad-hoc SQL: `db2/sql.sh "SELECT ..."` or `db2/sql.sh -f file.sql` (file uses `@` terminator).
  Use `$TMPDIR` for scratch files.
- The database will be rebuilt from scratch later, so test data you create is disposable.
- Do not edit DDL, seed files or other schemas' folders. If you are blocked by the schema,
  work around it or report it in your final message.

## Style

Write it like a real 2010s Db2 shop would: SQL PL, uppercase keywords and identifiers, 4-space
indent, `V_` for local variables, `P_` for parameters, `C_` for cursors. Use Db2 idioms naturally
(the point is that they need converting later): `VALUES ... INTO`, `SELECT ... FROM FINAL TABLE (INSERT ...)`,
`FETCH FIRST n ROWS ONLY`, `WITH UR` on read-only lookups, `CURRENT DATE`/`CURRENT TIMESTAMP`,
`DAYS()`, `ADD_MONTHS`, `LAST_DAY`, `VARCHAR_FORMAT`, `GET DIAGNOSTICS`, labelled loops, `LEAVE`/`ITERATE`.
Don't overdo it: each routine should look like working production code, not a feature showcase.

## Money and posting

- Never update `ACCT.ACCOUNT.LEDGER_BALANCE` directly. All money movement goes through
  `UTIL.POST_LEDGER_ENTRY` (see its header). Positive amount = credit to the customer.
- Never update `ACCT.ACCOUNT.HOLD_AMOUNT` directly. Insert into `ACCT.ACCOUNT_HOLD` (status 'A')
  to place a hold; update its STATUS to 'R' released / 'E' expired / 'S' settled to release it.
  Triggers maintain `HOLD_AMOUNT`.
- Online postings pass `P_BUSINESS_DATE => NULL` (uses `UTIL.POSTING_DATE()`); batch jobs pass
  `UTIL.CURRENT_BUSINESS_DATE()`.
- `P_ALLOW_OVERDRAW = 'Y'` only for bank-initiated debits (fees, interest, settled card auths).
- Both legs of an internal transfer share one correlation id (`NEXT VALUE FOR TXN.SEQ_CORRELATION`)
  and use contra GL 1900 (suspense), which must net to zero.
- Amounts: `DECIMAL(15,2)`; interest accruals `DECIMAL(15,6)`. Round with `ROUND(x, 2)`.

### Contra GL codes

| Movement | TXN_TYPE | Contra GL |
|---|---|---|
| Cash deposit / withdrawal | CASH | 1100 |
| Internal transfer, loan disbursement/repayment | XFR / LOAN | 1900 |
| Faster Payment out / in, standing order | FPO / FPI / SO | 1510 |
| Card settlement | CARD | 1520 |
| Direct debit | DD | 1530 |
| CHAPS | FPO | 1540 |
| Fee | FEE | 4100 |
| Credit interest capitalised | INT | 2210 |
| Overdraft interest capitalised | INT | 1210 |
| Loan interest | INT | 1220 |
| Write-off / fraud refund | ADJ | 5200 |

Interest accrual (no customer posting yet): credit interest `UTIL.POST_GL_PAIR('5100', '2210', amt, ...)`;
overdraft interest `UTIL.POST_GL_PAIR('1210', '4210', amt, ...)`; loan interest `('1220', '4220')`.

## Errors

Custom SQLSTATEs (the Java app maps these to HTTP responses, so keep them exact):

| SQLSTATE | Meaning |
|---|---|
| 75001 | Insufficient funds |
| 75002 | Account not found |
| 75003 | Account not active (closed / frozen) |
| 75004 | Customer not found |
| 75005 | Card not found or not active |
| 75006 | Limit exceeded (card daily limit, payment limit) |
| 75007 | Duplicate request |
| 75008 | Invalid amount or argument |
| 75009 | Business rule violation (message says which) |
| 75010 | Posted transactions are immutable (trigger) |
| 75011 | Sort code / account number failed validation |
| 75012 | Payee / mandate / standing order not found |
| 75013 | Loan not found or not active |
| 75014 | Account balance not zero |
| 75015 | Not allowed in current business day status |

Error-handling pattern for anything that modifies data:

```sql
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE CHAR(5);
    DECLARE V_SQLCODE  INTEGER;
    DECLARE V_MSG      VARCHAR(1000);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        -- GET DIAGNOSTICS must come first: any other statement resets the diagnostics area
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.LOG_ERROR('PAY.TRANSFER_FUNDS', V_SQLSTATE, V_SQLCODE, V_MSG, '<key params>');
        RESIGNAL;
    END;
```

Business-rule failures use `SIGNAL SQLSTATE '750xx' SET MESSAGE_TEXT = ...` (the message text
must be a variable or literal of at most 70 bytes).

## Result sets

Procedures returning data to the app use `DYNAMIC RESULT SETS n` and
`DECLARE C_x CURSOR WITH RETURN TO CLIENT FOR ...`, opened and left open. Scalar results come
back as OUT parameters.

## Batch jobs (BATCH schema)

- Signature: `BATCH.<NAME> (OUT P_ROWS_PROCESSED INTEGER)`. The three Db2-scheduled tasks
  (`PURGE_AUDIT_LOG`, `REFRESH_REPORTING_MQTS`, `RUNSTATS`) take no parameters instead.
- Each job records its own run: `CALL UTIL.START_JOB_RUN('<JOB_NAME>', V_RUN_ID)` at the start,
  `CALL UTIL.END_JOB_RUN(V_RUN_ID, 'S', V_ROWS, '<summary>')` at the end, and in the EXIT
  handler `END_JOB_RUN(..., 'F', ...)` then `LOG_ERROR` then `RESIGNAL`. Both are autonomous.
- Long jobs commit every 500–1000 rows (cursor `WITH HOLD`).
- Jobs use `UTIL.CURRENT_BUSINESS_DATE()` as "today" and are safe to re-run for the same date.

## Session context

The app sets `UTIL.GV_CHANNEL` ('WEB', 'MOB', 'BRN', 'API', 'SYS') and `UTIL.GV_OPERATOR` per
request. Batch leaves the default 'SYS'. Don't set them inside routines.

## Domain codes

- Customer STATUS A/D/C; KYC_STATUS P/V/F; SEGMENT MAS/AFF/PRM/STU/SME.
- Account STATUS A active, F frozen, D dormant, C closed. Product types CUR/SAV/LON.
- Card STATUS A active, B blocked, L lost, S stolen, E expired.
- Authorisation STATUS A approved-open, S settled, R reversed, X expired, D declined.
  RESPONSE_CODE: 00 approved, 05 do not honour, 14 invalid card, 43 stolen, 51 insufficient
  funds, 54 expired, 59 suspected fraud, 61 exceeds limit.
- Payment DIRECTION I/O, SCHEME FPS/BAC/CHP, STATUS P pending, C completed, R rejected, H held.
- Standing order FREQUENCY W/M/Q/A, STATUS A/C cancelled/S suspended/E ended.
- Customer numbers `'C' || 7 digits` from `CUST.SEQ_CUSTOMER_NO`. Account numbers: 7 digits from
  `ACCT.SEQ_ACCOUNT_NO` plus `UTIL.ACCOUNT_CHECK_DIGIT`. Sort code = the branch's sort code.

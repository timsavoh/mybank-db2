# Db2 admin tasks (ATS)

Three housekeeping jobs are scheduled *inside* Db2 with the Administrative Task Scheduler
(`SYSPROC.ADMIN_TASK_ADD`), not by the external scheduler. `OPS.BATCH_JOB` lists them with
`SCHEDULE_TYPE = 'DB2TASK'` so the external scheduler knows to leave them alone.

| Task name                       | Procedure                        | Cron (server time, UTC) |
|---------------------------------|----------------------------------|-------------------------|
| `MYBANK_PURGE_AUDIT_LOG`        | `BATCH.PURGE_AUDIT_LOG()`        | `0 * * * *` hourly      |
| `MYBANK_REFRESH_REPORTING_MQTS` | `BATCH.REFRESH_REPORTING_MQTS()` | `0,15,30,45 * * * *`    |
| `MYBANK_RUNSTATS`               | `BATCH.RUNSTATS()`               | `5,35 * * * *`          |

`admin_tasks.sql` registers them and is safe to re-run (it removes the old registrations first).
`deploy.sh` runs it as its final step.

## Enabling the scheduler

Registering a task needs only the `SYSTOOLSPACE` tablespace, which already exists in the
`icr.io/db2_community/db2` image. **Running** the tasks also needs the instance registry
variable `DB2_ATS_ENABLE`:

```bash
docker exec -u db2inst1 mybank-db2-1 bash -lc 'db2set DB2_ATS_ENABLE=YES'
```

- Tested 2026-09-28 on Db2 12.1: after `db2set DB2_ATS_ENABLE=YES`, with **no** instance
  restart, `MYBANK_REFRESH_REPORTING_MQTS` ran on schedule at 15:45 (`SYSTOOLS.ADMIN_TASK_STATUS`
  COMPLETE, SQLCODE 0, plus an `OPS.BATCH_JOB_RUN` row). No `db2acd` process was visible; on this
  version the scheduler picks the variable up while running.
- If a task does not fire within about 10 minutes of its cron time, fall back to a restart
  (the documented requirement on older releases):
  `su - db2inst1 -c 'db2stop force; db2start; db2 activate db MYBANK'`.
- The registry lives in the instance home, which persists on the `db2data` volume
  (`PERSISTENT_HOME=true`). A fresh volume needs the `db2set` again. To automate it, add the
  command to `deploy.sh`, or to a script mounted into the image's `/var/custom` directory.
- ATS only runs tasks for an **active** database. App/deploy connections keep it active;
  `db2 activate db MYBANK` makes sure of it.
- Tasks run under the authorisation ID that registered them (`db2inst1`).
- If `SYSTOOLSPACE` were ever missing:
  `CREATE TABLESPACE SYSTOOLSPACE IN IBMCATGROUP MANAGED BY AUTOMATIC STORAGE EXTENTSIZE 4`.

## Checking it works

```sql
SELECT NAME, SCHEDULE, PROCEDURE_SCHEMA, PROCEDURE_NAME FROM SYSTOOLS.ADMIN_TASK_LIST;
SELECT NAME, STATUS, BEGIN_TIME, END_TIME, SQLCODE, SQLERRMC FROM SYSTOOLS.ADMIN_TASK_STATUS;
SELECT * FROM OPS.V_BATCH_STATUS WHERE SCHEDULE_TYPE = 'DB2TASK';
```

The ATS polls for due tasks
about every five minutes, so the first run can start a few minutes after the cron time.
Each procedure also writes its own `OPS.BATCH_JOB_RUN` row. To run one by hand:
`CALL BATCH.REFRESH_REPORTING_MQTS()`.

## Migration note

PostgreSQL has no ATS. On the target these become `pg_cron` jobs (or move to the external
scheduler). `REFRESH TABLE` maps to `REFRESH MATERIALIZED VIEW`, and `ADMIN_CMD('RUNSTATS ...')`
maps to `ANALYZE`.

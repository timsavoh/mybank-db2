# MyBank

A fictional UK retail bank running on IBM Db2, built to be migrated to PostgreSQL.
It is deliberately a realistic legacy estate: ~100 SQL PL routines, triggers that write
to other tables, materialized query tables, two schedulers, Db2-specific SQL stored in
data rows, and a dozen routines nobody calls any more.

See [docs/design.md](docs/design.md) for the domain, the routine inventory and the
Db2 features each routine exercises.

## Run it

Needs Docker with about 6 GB of memory available. On Apple Silicon, Db2 runs under
x86 emulation, which works but is slower.

```sh
cd mybank
cp .env.example .env
docker compose up -d db2          # first start takes a few minutes
db2/deploy.sh                     # schema, routines, reference data, seed data
docker compose up -d --build app scheduler loadgen
```

Then open http://localhost:8080.

- **Operations**: the business date, end-of-day chain, load generator and ledger checks.
- **Customers**: search, customer view, transfers, freezing accounts.
- **Reports**: the ten reporting procedures.

Day to day:

```sh
docker compose stop        # stop everything, keep the data
docker compose up -d       # start again where it left off
docker compose down -v     # delete everything, including the database
```

After a restart the scheduler runs one catch-up end of day, then carries on. It does not
replay every business day missed while the stack was down.

## How it runs

- **Compressed time.** One business day lasts 5 minutes of wall clock (change it on the
  Operations page). At the end of each day the scheduler runs the end-of-day chain, which
  ends by rolling the business date. Month-end runs on the last business day of each
  month, or on demand with "Force month-end".
- **Two schedulers.** `scheduler` (the Control-M stand-in) runs the jobs in
  `OPS.BATCH_JOB`. Three housekeeping jobs are scheduled inside Db2 with
  `SYSPROC.ADMIN_TASK_ADD`.
- **Load.** `loadgen` sends card authorisations, inbound and outbound payments, transfers,
  cash and new customers through the HTTP API at a configurable rate (default 10 a second),
  and injects fraud patterns every few minutes.
- **Bounded size.** The archive-and-purge job keeps 60 business days of transactions, so
  the database stays under 1 GB locally.

## Layout

```
docs/design.md            domain, routine inventory, Db2 feature coverage
db2/ddl/                  storage, tables, views/MQTs, triggers, legacy tables
db2/routines/<SCHEMA>/    one SQL PL routine per file (see CONVENTIONS.md)
db2/seed/                 reference data, seed generator (Python) and LOAD script
db2/tasks/                Db2 Administrative Task Scheduler registrations
db2/deploy.sh             build the database from scratch
db2/sql.sh                run SQL against the container
app/                      Spring Boot app: api, scheduler and loadgen profiles
```

## Checking the ledger

Every posting writes a balanced pair of GL entries, so these hold at all times:

```sh
db2/sql.sh -f db2/seed/20_post_load.sql   # the last query shows each check; all should be 0.00
```

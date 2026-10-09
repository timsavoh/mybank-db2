package uk.co.mybank.batch;

import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import uk.co.mybank.db.BankException;
import uk.co.mybank.db.Db2Client;
import uk.co.mybank.db.Db2Client.Out;

/**
 * Batch scheduler: the stand-in for the bank's enterprise scheduler (Control-M).
 *
 * Job definitions live in OPS.BATCH_JOB. INTRADAY jobs run every minute of wall
 * clock. When the business day has been open for MINUTES_PER_BUSINESS_DAY, the
 * end-of-day chain runs in CHAIN_SEQ order (MONTHEND jobs only on month-end),
 * finishing with ROLL_BUSINESS_DATE. If a job fails the chain halts and is
 * resumed from that job on the next tick. DB2TASK jobs are run by Db2's own
 * Administrative Task Scheduler, not here.
 */
@Component
@Profile("scheduler")
public class BatchScheduler {

    private static final Logger log = LoggerFactory.getLogger(BatchScheduler.class);
    private static final String OPERATOR = "SCHEDULER";

    private final Db2Client db;
    private final Duration intradayEvery;
    private Instant lastIntraday = Instant.EPOCH;

    public BatchScheduler(Db2Client db, @Value("${mybank.scheduler.intraday-seconds}") long intradaySeconds) {
        this.db = db;
        this.intradayEvery = Duration.ofSeconds(intradaySeconds);
    }

    @Scheduled(initialDelay = 5_000, fixedDelayString = "#{${mybank.scheduler.tick-seconds} * 1000}")
    public void tick() {
        try {
            if (Instant.now().isAfter(lastIntraday.plus(intradayEvery))) {
                lastIntraday = Instant.now();
                runJobs(jobs("SCHEDULE_TYPE = 'INTRADAY'"), null);
            }
            Map<String, Object> ctl = db.query("""
                    SELECT BUSINESS_DATE, DAY_STATUS, MINUTES_PER_BUSINESS_DAY,
                           TIMESTAMPDIFF(2, CHAR(CURRENT TIMESTAMP - DAY_OPENED_TS)) AS SECONDS_OPEN
                      FROM REF.BANK_CONTROL WHERE CONTROL_ID = 1""").get(0);
            LocalDate businessDate = (LocalDate) ctl.get("BUSINESS_DATE");
            boolean cutOff = "C".equals(ctl.get("DAY_STATUS"));
            long secondsOpen = ((Number) ctl.get("SECONDS_OPEN")).longValue();
            long dayLength = ((Number) ctl.get("MINUTES_PER_BUSINESS_DAY")).longValue() * 60;
            if (cutOff || secondsOpen >= dayLength) {
                runEndOfDay(businessDate);
            }
        } catch (Exception e) {
            log.error("Scheduler tick failed: {}", e.getMessage());
        }
    }

    private void runEndOfDay(LocalDate businessDate) {
        boolean monthEnd = "Y".equals(db.query("VALUES BATCH.IS_MONTH_END()").get(0).values().iterator().next());
        String filter = monthEnd
                ? "SCHEDULE_TYPE IN ('EOD', 'NIGHTLY', 'MONTHEND')"
                : "SCHEDULE_TYPE IN ('EOD', 'NIGHTLY')";
        log.info("End of day for {}{}", businessDate, monthEnd ? " (month-end)" : "");
        long started = System.currentTimeMillis();
        if (runJobs(jobs(filter), businessDate)) {
            log.info("End of day for {} complete in {} ms", businessDate, System.currentTimeMillis() - started);
        }
    }

    private List<Map<String, Object>> jobs(String filter) {
        return db.query("SELECT JOB_NAME, PROC_NAME FROM OPS.BATCH_JOB WHERE ENABLED = 'Y' AND "
                + filter + " ORDER BY CHAIN_SEQ, JOB_NAME");
    }

    /**
     * Runs jobs in order. For a chain (businessDate != null) jobs that already
     * succeeded for that business date are skipped, so a halted chain resumes.
     * Returns false if a job failed.
     */
    private boolean runJobs(List<Map<String, Object>> jobs, LocalDate businessDate) {
        for (Map<String, Object> job : jobs) {
            String name = (String) job.get("JOB_NAME");
            String proc = (String) job.get("PROC_NAME");
            if (businessDate != null && alreadySucceeded(name, businessDate)) {
                continue;
            }
            long t0 = System.currentTimeMillis();
            try {
                Object rows = db.call("SYS", OPERATOR, proc, Out.integer()).out(1);
                log.info("  {} ok: {} rows in {} ms", name, rows, System.currentTimeMillis() - t0);
            } catch (BankException e) {
                log.error("  {} FAILED SQLSTATE={}: {}", name, e.getSqlState(), e.getMessage());
                if (businessDate != null) {
                    return false;
                }
            }
        }
        return true;
    }

    private boolean alreadySucceeded(String jobName, LocalDate businessDate) {
        return !db.query("""
                SELECT 1 FROM OPS.BATCH_JOB_RUN
                 WHERE JOB_NAME = ? AND BUSINESS_DATE = ? AND STATUS = 'S'
                 FETCH FIRST 1 ROW ONLY""", jobName, java.sql.Date.valueOf(businessDate)).isEmpty();
    }
}

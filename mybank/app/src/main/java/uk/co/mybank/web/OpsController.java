package uk.co.mybank.web;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import uk.co.mybank.db.Db2Client;

/** Operations console: business date, batch, ledger checks and load generator control. */
@RestController
@RequestMapping("/api/ops")
@Profile("api")
public class OpsController {

    private final Db2Client db;
    private final String loadgenUrl;
    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build();
    private final ObjectMapper json = new ObjectMapper();

    private volatile List<Map<String, Object>> ledgerCache = List.of();
    private volatile long ledgerCachedAt;

    public OpsController(Db2Client db, @Value("${mybank.loadgen-url}") String loadgenUrl) {
        this.db = db;
        this.loadgenUrl = loadgenUrl;
    }

    // UTIL.POSTING_DATE() is NOT DETERMINISTIC, so in a WHERE clause Db2 calls it for every row
    // and scans the table. Evaluating it once in a CTE lets the BUSINESS_DATE index do the work.
    @GetMapping("/status")
    public Map<String, Object> status() {
        Map<String, Object> s = new LinkedHashMap<>();
        s.put("control", db.query("""
                SELECT BUSINESS_DATE AS "businessDate", PREV_BUSINESS_DATE AS "previousBusinessDate",
                       DAY_STATUS AS "dayStatus", MINUTES_PER_BUSINESS_DAY AS "minutesPerDay",
                       TIMESTAMPDIFF(2, CHAR(CURRENT TIMESTAMP - DAY_OPENED_TS)) AS "secondsOpen",
                       FORCE_MONTH_END AS "forceMonthEnd", LAST_EOD_TS AS "lastEod",
                       RETENTION_BUSINESS_DAYS AS "retentionDays", BATCH.IS_MONTH_END() AS "isMonthEnd"
                  FROM REF.BANK_CONTROL WHERE CONTROL_ID = 1""").get(0));
        s.put("jobs", db.query("""
                SELECT JOB_NAME AS "job", SCHEDULE_TYPE AS "type", CHAIN_SEQ AS "seq", ENABLED AS "enabled",
                       BUSINESS_DATE AS "businessDate", STARTED_TS AS "started", ENDED_TS AS "ended",
                       STATUS AS "status", ROWS_PROCESSED AS "rows", MESSAGE AS "message",
                       CASE WHEN ENDED_TS IS NOT NULL
                            THEN TIMESTAMPDIFF(1, CHAR(ENDED_TS - STARTED_TS)) / 1000 END AS "ms"
                  FROM OPS.V_BATCH_STATUS
                 ORDER BY CASE SCHEDULE_TYPE WHEN 'INTRADAY' THEN 0 WHEN 'DB2TASK' THEN 2 ELSE 1 END,
                          CHAIN_SEQ, JOB_NAME
                  WITH UR"""));
        s.put("activity", db.query("""
                WITH D (BUSINESS_DATE) AS (VALUES UTIL.POSTING_DATE())
                SELECT T.TXN_TYPE AS "type", COUNT(*) AS "count", SUM(T.AMOUNT) AS "net"
                  FROM D JOIN TXN.POSTED_TXN T ON T.BUSINESS_DATE = D.BUSINESS_DATE
                 GROUP BY T.TXN_TYPE
                 ORDER BY 2 DESC
                  WITH UR"""));
        s.put("cardAuths", db.query("""
                WITH D (BUSINESS_DATE) AS (VALUES UTIL.POSTING_DATE())
                SELECT A.RESPONSE_CODE AS "code", COUNT(*) AS "count"
                  FROM D JOIN CARD.AUTHORISATION A ON A.BUSINESS_DATE = D.BUSINESS_DATE
                 GROUP BY A.RESPONSE_CODE
                 ORDER BY 2 DESC
                  WITH UR"""));
        s.put("openAlerts", db.query("SELECT COUNT(*) AS \"count\" FROM RISK.FRAUD_ALERT WHERE STATUS = 'O' WITH UR")
                .get(0).get("count"));
        s.put("errors", db.query("""
                SELECT LOGGED_TS AS "at", PROC_NAME AS "proc", SQL_STATE AS "sqlState", MESSAGE AS "message"
                  FROM OPS.ERROR_LOG
                 ORDER BY ERROR_ID DESC
                 FETCH FIRST 12 ROWS ONLY
                  WITH UR"""));
        s.put("ledger", ledgerChecks());
        s.put("reconBreaks", db.query("""
                SELECT BUSINESS_DATE AS "businessDate", CHECK_NAME AS "check", EXPECTED AS "expected",
                       ACTUAL AS "actual"
                  FROM GL.RECON_BREAK
                 ORDER BY BREAK_ID DESC
                 FETCH FIRST 5 ROWS ONLY
                  WITH UR"""));
        s.put("loadgen", loadgen("GET", "/loadgen/status", null));
        return s;
    }

    /** Live ledger invariants. Read uncommitted, so in-flight postings can show briefly. */
    private List<Map<String, Object>> ledgerChecks() {
        if (System.currentTimeMillis() - ledgerCachedAt > 20_000) {
            ledgerCache = db.query("""
                    SELECT 'All GL entries' AS "check", SUM(AMOUNT) AS "difference" FROM GL.GL_ENTRY
                    UNION ALL
                    SELECT G.NAME || ' vs accounts',
                           (SELECT COALESCE(SUM(A.LEDGER_BALANCE), 0)
                              FROM ACCT.ACCOUNT A JOIN REF.PRODUCT P ON P.PRODUCT_CODE = A.PRODUCT_CODE
                             WHERE P.CONTROL_GL_CODE = G.GL_CODE)
                         + (SELECT COALESCE(SUM(E.AMOUNT), 0) FROM GL.GL_ENTRY E WHERE E.GL_CODE = G.GL_CODE)
                      FROM REF.GL_ACCOUNT G
                     WHERE G.GL_CODE IN (SELECT CONTROL_GL_CODE FROM REF.PRODUCT)
                    UNION ALL
                    SELECT 'Transfer suspense', COALESCE(SUM(AMOUNT), 0) FROM GL.GL_ENTRY WHERE GL_CODE = '1900'
                    WITH UR""");
            ledgerCachedAt = System.currentTimeMillis();
        }
        return ledgerCache;
    }

    @PostMapping("/run-eod-now")
    public Map<String, Object> runEodNow() {
        int n = db.update("""
                UPDATE REF.BANK_CONTROL
                   SET DAY_OPENED_TS = CURRENT TIMESTAMP - MINUTES_PER_BUSINESS_DAY MINUTES
                 WHERE CONTROL_ID = 1 AND DAY_STATUS = 'O'""");
        return Map.of("requested", n == 1);
    }

    @PostMapping("/force-month-end")
    public Map<String, Object> forceMonthEnd() {
        db.update("UPDATE REF.BANK_CONTROL SET FORCE_MONTH_END = 'Y' WHERE CONTROL_ID = 1");
        return Map.of("forceMonthEnd", "Y");
    }

    @PostMapping("/day-length")
    public Map<String, Object> dayLength(@RequestBody Map<String, Object> body) {
        int minutes = Math.max(1, Math.min(60, new Body(body).integer("minutes")));
        db.update("UPDATE REF.BANK_CONTROL SET MINUTES_PER_BUSINESS_DAY = ? WHERE CONTROL_ID = 1", minutes);
        return Map.of("minutesPerDay", minutes);
    }

    @PostMapping("/loadgen/rate")
    public Object loadgenRate(@RequestBody Map<String, Object> body) {
        return loadgen("POST", "/loadgen/rate", body);
    }

    @PostMapping("/loadgen/scenario/{name}")
    public Object loadgenScenario(@PathVariable String name) {
        return loadgen("POST", "/loadgen/scenario/" + name, Map.of());
    }

    private Object loadgen(String method, String path, Object body) {
        try {
            HttpRequest.Builder b = HttpRequest.newBuilder(URI.create(loadgenUrl + path))
                    .timeout(Duration.ofSeconds(3)).header("Content-Type", "application/json");
            b = body == null ? b.GET() : b.method(method, HttpRequest.BodyPublishers.ofString(json.writeValueAsString(body)));
            HttpResponse<String> r = http.send(b.build(), HttpResponse.BodyHandlers.ofString());
            return json.readValue(r.body(), Map.class);
        } catch (Exception e) {
            return Map.of("unavailable", true);
        }
    }
}

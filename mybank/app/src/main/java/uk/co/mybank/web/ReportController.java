package uk.co.mybank.web;

import jakarta.servlet.http.HttpServletRequest;
import java.math.BigDecimal;
import java.sql.Date;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import uk.co.mybank.db.Db2Client;

/** The reports page: a fixed catalogue of RPT procedures and their parameters. */
@RestController
@RequestMapping("/api/reports")
@Profile("api")
public class ReportController {

    record Param(String name, String label, String type, Object defaultValue) {}

    record Report(String id, String proc, String title, String description, List<Param> params) {}

    private static final List<Report> REPORTS = List.of(
            new Report("daily-transactions", "RPT.DAILY_TXN_SUMMARY", "Daily transactions",
                    "Posted transactions by business date and type, with daily subtotals.",
                    List.of(new Param("fromDate", "From", "date", null), new Param("toDate", "To", "date", null),
                            new Param("channel", "Channel", "text", null))),
            new Report("top-merchants", "RPT.TOP_MERCHANTS", "Top merchants",
                    "Merchants ranked by settled card spend, and spend by merchant category.",
                    List.of(new Param("fromDate", "From", "date", null), new Param("toDate", "To", "date", null),
                            new Param("topN", "How many", "int", 20))),
            new Report("branch-performance", "RPT.BRANCH_PERFORMANCE", "Branch performance",
                    "Accounts, balances and activity by branch and region.",
                    List.of(new Param("fromDate", "From", "date", null), new Param("toDate", "To", "date", null))),
            new Report("overdrawn", "RPT.OVERDRAWN_ACCOUNTS", "Overdrawn accounts",
                    "Accounts below zero, worst unarranged overdrafts first.",
                    List.of(new Param("minOverdrawn", "Overdrawn by at least", "money", 0),
                            new Param("unarrangedOnly", "Unarranged only (Y/N)", "text", "N"),
                            new Param("branchId", "Branch", "int", null))),
            new Report("liquidity", "RPT.LIQUIDITY_POSITION", "Liquidity position",
                    "Daily money in and out by product type, with a running net.",
                    List.of(new Param("fromDate", "From", "date", null), new Param("toDate", "To", "date", null),
                            new Param("productType", "Product type (CUR/SAV/LON)", "text", null))),
            new Report("segmentation", "RPT.CUSTOMER_SEGMENTATION", "Customer segmentation",
                    "Active customers ranked into value bands by relationship balance.",
                    List.of(new Param("segment", "Segment", "text", null), new Param("buckets", "Bands", "int", 10))),
            new Report("fraud-trends", "RPT.FRAUD_ALERT_TRENDS", "Fraud alert trends",
                    "Alerts by ISO week and rule, and by day of week.",
                    List.of(new Param("fromDate", "From", "text", null), new Param("toDate", "To", "text", null))),
            new Report("loan-book", "RPT.LOAN_BOOK_AGEING", "Loan book ageing",
                    "Personal loans by months on book and by arrears.",
                    List.of(new Param("asOf", "As at", "date", null))),
            new Report("trial-balance", "RPT.GL_TRIAL_BALANCE", "Trial balance",
                    "General ledger balances rolled up the chart of accounts.",
                    List.of(new Param("asOf", "As at", "date", null),
                            new Param("postableOnly", "Postable accounts only (Y/N)", "text", "N"))),
            new Report("dormant", "RPT.DORMANT_ACCOUNTS", "Dormant accounts",
                    "Accounts with no customer activity for a period.",
                    List.of(new Param("minDaysInactive", "Days inactive", "int", 365),
                            new Param("branchId", "Branch", "int", null))));

    private final Db2Client db;

    public ReportController(Db2Client db) {
        this.db = db;
    }

    @GetMapping
    public List<Report> catalogue() {
        return REPORTS;
    }

    @GetMapping("/{id}")
    public Map<String, Object> run(@PathVariable String id, @RequestParam Map<String, String> query,
                                   HttpServletRequest req) {
        Report report = REPORTS.stream().filter(r -> r.id().equals(id)).findFirst()
                .orElseThrow(() -> new IllegalArgumentException("Unknown report " + id));
        List<Object> args = new ArrayList<>();
        for (Param p : report.params()) {
            String v = query.get(p.name());
            Object value = v == null || v.isBlank() ? p.defaultValue() : switch (p.type()) {
                case "date" -> Date.valueOf(v);
                case "int" -> Integer.valueOf(v);
                case "money" -> new BigDecimal(v);
                default -> v.trim().toUpperCase();
            };
            args.add(value);
        }
        long t0 = System.currentTimeMillis();
        var result = db.call(Channel.of(req), Channel.operator(req), report.proc(), args.toArray());
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("report", report);
        m.put("resultSets", result.resultSets());
        m.put("elapsedMs", System.currentTimeMillis() - t0);
        return m;
    }
}

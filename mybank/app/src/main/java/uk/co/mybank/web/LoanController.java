package uk.co.mybank.web;

import jakarta.servlet.http.HttpServletRequest;
import java.util.Map;
import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import uk.co.mybank.db.Db2Client;
import uk.co.mybank.db.Db2Client.Out;
import uk.co.mybank.db.Db2Client.ProcResult;

@RestController
@RequestMapping("/api/loans")
@Profile("api")
public class LoanController {

    private final Db2Client db;

    public LoanController(Db2Client db) {
        this.db = db;
    }

    @PostMapping("/quote")
    public Map<String, Object> quote(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "LOAN.QUOTE_LOAN",
                b.money("principal"), b.money("annualRate"), b.integer("termMonths"), Out.decimal(), Out.decimal());
        return Map.of("monthlyPayment", r.out(4), "totalInterest", r.out(5), "schedule", r.resultSet(0));
    }

    @PostMapping
    public Map<String, Object> originate(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "LOAN.ORIGINATE_LOAN",
                b.lng("customerId"), b.lng("repaymentAccountId"), b.money("principal"), b.money("annualRate"),
                b.integer("termMonths"), Out.bigint(), Out.bigint(), Out.decimal());
        return Map.of("loanId", r.outLong(6), "loanAccountId", r.outLong(7), "monthlyPayment", r.out(8));
    }

    @GetMapping("/{id}")
    public Map<String, Object> summary(@PathVariable long id, HttpServletRequest req) {
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "LOAN.GET_LOAN_SUMMARY", id);
        return Map.of("loan", r.resultSet(0), "schedule", r.resultSet(1));
    }

    @PostMapping("/{id}/repayments")
    public Map<String, Object> repay(@PathVariable long id, @RequestBody Map<String, Object> json,
                                     HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "LOAN.MAKE_REPAYMENT", id,
                b.money("amount"), Out.decimal(), Out.bigint());
        return Map.of("outstanding", r.out(3), "repaymentId", r.outLong(4));
    }
}

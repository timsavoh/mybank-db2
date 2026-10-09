package uk.co.mybank.web;

import jakarta.servlet.http.HttpServletRequest;
import java.sql.Date;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import uk.co.mybank.db.Db2Client;
import uk.co.mybank.db.Db2Client.Out;
import uk.co.mybank.db.Db2Client.ProcResult;

@RestController
@RequestMapping("/api/accounts")
@Profile("api")
public class AccountController {

    private final Db2Client db;

    public AccountController(Db2Client db) {
        this.db = db;
    }

    @PostMapping
    public Map<String, Object> open(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "ACCT.OPEN_ACCOUNT",
                b.lng("customerId"), b.req("productCode"), b.integer("branchId"), b.str("accountName"),
                b.money("openingDeposit"), Out.bigint(), Out.chr(), Out.chr());
        return Map.of("accountId", r.outLong(6), "sortCode", r.out(7), "accountNo", r.out(8));
    }

    @GetMapping("/{id}/balance")
    public Map<String, Object> balance(@PathVariable long id, HttpServletRequest req) {
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "ACCT.GET_BALANCE", id,
                Out.decimal(), Out.decimal(), Out.decimal(), Out.decimal(), Out.chr(), Out.timestamp());
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("accountId", id);
        m.put("ledgerBalance", r.out(2));
        m.put("availableBalance", r.out(3));
        m.put("holdAmount", r.out(4));
        m.put("overdraftLimit", r.out(5));
        m.put("status", r.out(6));
        m.put("asOf", r.out(7));
        return m;
    }

    @GetMapping("/{id}/transactions")
    public Map<String, Object> transactions(@PathVariable long id,
                                            @RequestParam(required = false) String from,
                                            @RequestParam(required = false) String to,
                                            @RequestParam(defaultValue = "1") int page,
                                            @RequestParam(defaultValue = "25") int pageSize,
                                            HttpServletRequest req) {
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "ACCT.GET_TRANSACTIONS", id,
                from == null ? null : Date.valueOf(from), to == null ? null : Date.valueOf(to),
                page, pageSize, Out.decimal(), Out.integer());
        return Map.of("openingBalance", r.out(6) == null ? 0 : r.out(6), "totalRows", r.out(7),
                "transactions", r.resultSet(0));
    }

    @PostMapping("/{id}/freeze")
    public Map<String, Object> freeze(@PathVariable long id, @RequestBody Map<String, Object> json,
                                      HttpServletRequest req) {
        Body b = new Body(json);
        String action = "UNFREEZE".equalsIgnoreCase(b.str("action")) ? "U" : "F";
        db.call(Channel.of(req), Channel.operator(req), "ACCT.FREEZE_ACCOUNT", id, action, b.str("reason"));
        return Map.of("accountId", id, "action", action);
    }

    @PostMapping("/{id}/overdraft")
    public Map<String, Object> overdraft(@PathVariable long id, @RequestBody Map<String, Object> json,
                                         HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "ACCT.SET_OVERDRAFT_LIMIT", id,
                b.money("limit"), b.str("reason"), Out.decimal());
        return Map.of("accountId", id, "oldLimit", r.out(4), "newLimit", b.money("limit"));
    }

    @PostMapping("/{id}/joint-holders")
    public Map<String, Object> addJointHolder(@PathVariable long id, @RequestBody Map<String, Object> json,
                                              HttpServletRequest req) {
        Body b = new Body(json);
        db.call(Channel.of(req), Channel.operator(req), "ACCT.ADD_JOINT_HOLDER", id, b.lng("customerId"));
        return Map.of("accountId", id, "customerId", b.lng("customerId"));
    }

    @PostMapping("/{id}/close")
    public Map<String, Object> close(@PathVariable long id, @RequestBody Map<String, Object> json,
                                     HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "ACCT.CLOSE_ACCOUNT", id,
                b.lng("sweepToAccountId"), b.str("reason"), Out.decimal());
        return Map.of("accountId", id, "sweptAmount", r.out(4));
    }
}

package uk.co.mybank.web;

import jakarta.servlet.http.HttpServletRequest;
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
@RequestMapping("/api/alerts")
@Profile("api")
public class RiskController {

    private final Db2Client db;

    public RiskController(Db2Client db) {
        this.db = db;
    }

    @GetMapping
    public Object open(@RequestParam(defaultValue = "0") int minScore,
                       @RequestParam(required = false) Long accountId,
                       @RequestParam(defaultValue = "100") int maxRows, HttpServletRequest req) {
        return db.call(Channel.of(req), Channel.operator(req), "RISK.GET_OPEN_ALERTS",
                minScore, accountId, maxRows).resultSet(0);
    }

    @PostMapping("/{id}/resolve")
    public Map<String, Object> resolve(@PathVariable long id, @RequestBody Map<String, Object> json,
                                       HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "RISK.RESOLVE_ALERT", id,
                b.req("outcome").toUpperCase(), b.str("notes"), Out.integer());
        return Map.of("alertId", id, "paymentsActed", r.out(4));
    }
}

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
@RequestMapping("/api/cards")
@Profile("api")
public class CardController {

    private final Db2Client db;

    public CardController(Db2Client db) {
        this.db = db;
    }

    /** Card network authorisation request. Declines are normal responses, not errors. */
    @PostMapping("/authorise")
    public Map<String, Object> authorise(@RequestBody Map<String, Object> json) {
        Body b = new Body(json);
        ProcResult r = db.call("API", "CARD-NETWORK", "CARD.AUTHORISE",
                b.req("pan"), b.integer("merchantId"), b.money("amount"), b.req("externalRef"),
                Out.chr(), Out.bigint());
        return Map.of("responseCode", r.out(5), "authId", r.outLong(6) == null ? -1 : r.outLong(6));
    }

    @PostMapping("/authorisations/{authId}/reverse")
    public Map<String, Object> reverse(@PathVariable long authId) {
        ProcResult r = db.call("API", "CARD-NETWORK", "CARD.REVERSE_AUTH", authId, null, Out.chr());
        return Map.of("authId", authId, "status", r.out(3));
    }

    @PostMapping
    public Map<String, Object> issue(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "CARD.ISSUE_CARD",
                b.lng("accountId"), b.lng("customerId"), b.str("cardType") == null ? "D" : b.str("cardType"),
                Out.bigint(), Out.chr());
        return Map.of("cardId", r.outLong(4), "maskedPan", r.out(5));
    }

    @PostMapping("/{id}/block")
    public Map<String, Object> block(@PathVariable long id, @RequestBody Map<String, Object> json,
                                     HttpServletRequest req) {
        Body b = new Body(json);
        String reason = b.str("reason") == null ? "BLOCKED" : b.str("reason").toUpperCase();
        String status = switch (reason) {
            case "LOST" -> "L";
            case "STOLEN" -> "S";
            case "UNBLOCK" -> "A";
            default -> "B";
        };
        db.call(Channel.of(req), Channel.operator(req), "CARD.BLOCK_CARD", id, status, reason);
        return Map.of("cardId", id, "status", status);
    }

    @GetMapping("/{id}/activity")
    public Object activity(@PathVariable long id, @RequestParam(defaultValue = "7") int days,
                           HttpServletRequest req) {
        return db.call(Channel.of(req), Channel.operator(req), "CARD.GET_CARD_ACTIVITY", id, days).resultSet(0);
    }

    @PostMapping("/disputes")
    public Map<String, Object> dispute(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "CARD.RAISE_DISPUTE",
                b.lng("txnId"), b.req("reason"), b.money("amount"), Out.bigint());
        return Map.of("disputeId", r.outLong(4));
    }
}

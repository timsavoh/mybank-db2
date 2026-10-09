package uk.co.mybank.web;

import jakarta.servlet.http.HttpServletRequest;
import java.util.Map;
import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import uk.co.mybank.db.BankException;
import uk.co.mybank.db.Db2Client;
import uk.co.mybank.db.Db2Client.Out;
import uk.co.mybank.db.Db2Client.ProcResult;

@RestController
@Profile("api")
public class PaymentController {

    private final Db2Client db;

    public PaymentController(Db2Client db) {
        this.db = db;
    }

    @PostMapping("/api/transfers")
    public Map<String, Object> transfer(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "PAY.TRANSFER_FUNDS",
                b.lng("fromAccountId"), b.lng("toAccountId"), b.money("amount"), b.str("reference"),
                Out.bigint(), Out.decimal());
        return Map.of("correlationId", r.outLong(5), "fromBalance", r.out(6));
    }

    @PostMapping("/api/payments/faster")
    public Map<String, Object> fasterPayment(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "PAY.SEND_FASTER_PAYMENT",
                b.lng("accountId"), b.money("amount"), b.lng("payeeId"), b.str("sortCode"), b.str("accountNo"),
                b.str("name"), b.str("reference"), b.str("idempotencyKey"), Out.bigint(), Out.chr());
        return Map.of("paymentId", r.outLong(9), "status", r.out(10));
    }

    /** Inbound payments arrive from the payment scheme, not a customer channel. */
    @PostMapping("/api/scheme/inbound")
    public Map<String, Object> inbound(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call("API", "FPS-GATEWAY", "PAY.RECEIVE_INBOUND_PAYMENT",
                b.req("sortCode"), b.req("accountNo"), b.money("amount"), b.str("remitterName"),
                b.str("remitterSort"), b.str("remitterAccount"), b.str("reference"), b.req("schemeRef"),
                Out.bigint(), Out.chr());
        return Map.of("paymentId", r.outLong(9), "status", r.out(10));
    }

    @PostMapping("/api/cash/deposit")
    public Map<String, Object> deposit(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call("BRN", Channel.operator(req), "PAY.DEPOSIT_CASH",
                b.lng("accountId"), b.money("amount"), b.integer("branchId"), b.str("reference"),
                Out.bigint(), Out.decimal());
        return Map.of("txnId", r.outLong(5), "balanceAfter", r.out(6));
    }

    @PostMapping("/api/cash/withdraw")
    public Map<String, Object> withdraw(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call("BRN", Channel.operator(req), "PAY.WITHDRAW_CASH",
                b.lng("accountId"), b.money("amount"), b.integer("branchId"), b.str("atmId"),
                Out.bigint(), Out.decimal());
        return Map.of("txnId", r.outLong(5), "balanceAfter", r.out(6));
    }

    @PostMapping("/api/payees")
    public Map<String, Object> createPayee(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        try {
            ProcResult r = db.call(Channel.of(req), Channel.operator(req), "PAY.CREATE_PAYEE",
                    b.lng("customerId"), b.req("name"), b.req("sortCode"), b.req("accountNo"),
                    b.str("reference"), Out.bigint());
            return Map.of("payeeId", r.outLong(6));
        } catch (BankException e) {
            // Older behaviour kept for the mobile app: a duplicate payee is not an error.
            if (e.getSqlCode() == Db2Client.SQLCODE_DUPLICATE_KEY || "75007".equals(e.getSqlState())) {
                return Map.of("payeeId", -1, "duplicate", true);
            }
            throw e;
        }
    }

    /** Creates the payee then the standing order, as the web journey does. */
    @PostMapping("/api/standing-orders")
    public Map<String, Object> createStandingOrder(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        String channel = Channel.of(req);
        String operator = Channel.operator(req);
        return db.withConnection(channel, operator, conn -> {
            Long payeeId = b.lng("payeeId");
            if (payeeId == null) {
                payeeId = createPayeeFor(conn, b);
            }
            ProcResult so = db.call(conn, "PAY.CREATE_STANDING_ORDER", b.lng("accountId"), payeeId,
                    b.money("amount"), b.str("frequency") == null ? "M" : b.str("frequency"),
                    b.date("firstDate"), b.date("endDate"), Out.bigint());
            return Map.of("standingOrderId", so.outLong(7), "payeeId", payeeId);
        });
    }

    private Long createPayeeFor(java.sql.Connection conn, Body b) throws java.sql.SQLException {
        long customerId;
        try (var ps = conn.prepareStatement("SELECT PRIMARY_CUSTOMER_ID FROM ACCT.ACCOUNT WHERE ACCOUNT_ID = ?")) {
            ps.setLong(1, b.lng("accountId"));
            try (var rs = ps.executeQuery()) {
                if (!rs.next()) {
                    throw new BankException("75002", -438, "Account not found", null);
                }
                customerId = rs.getLong(1);
            }
        }
        ProcResult p = db.call(conn, "PAY.CREATE_PAYEE", customerId, b.req("name"), b.req("sortCode"),
                b.req("accountNo"), b.str("reference"), Out.bigint());
        return p.outLong(6);
    }

    @PostMapping("/api/standing-orders/{id}/cancel")
    public Map<String, Object> cancelStandingOrder(@PathVariable long id, HttpServletRequest req) {
        db.call(Channel.of(req), Channel.operator(req), "PAY.CANCEL_STANDING_ORDER", id);
        return Map.of("standingOrderId", id, "status", "C");
    }

    @PostMapping("/api/mandates")
    public Map<String, Object> createMandate(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        String ref = b.str("mandateRef") != null ? b.str("mandateRef")
                : "MB" + Long.toString(System.nanoTime() % 10_000_000_000L);
        ProcResult r = db.call("API", "BACS-GATEWAY", "PAY.CREATE_DD_MANDATE",
                b.lng("accountId"), b.req("originatorId"), b.req("originatorName"), ref,
                b.money("amount"), b.integer("collectionDay"), Out.bigint());
        return Map.of("mandateId", r.outLong(7));
    }

    @PostMapping("/api/mandates/{id}/cancel")
    public Map<String, Object> cancelMandate(@PathVariable long id, HttpServletRequest req) {
        db.call(Channel.of(req), Channel.operator(req), "PAY.CANCEL_DD_MANDATE", id);
        return Map.of("mandateId", id, "status", "C");
    }
}

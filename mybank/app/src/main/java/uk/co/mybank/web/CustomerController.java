package uk.co.mybank.web;

import jakarta.servlet.http.HttpServletRequest;
import java.sql.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import uk.co.mybank.db.BankException;
import uk.co.mybank.db.Db2Client;
import uk.co.mybank.db.Db2Client.Out;
import uk.co.mybank.db.Db2Client.ProcResult;

@RestController
@RequestMapping("/api/customers")
@Profile("api")
public class CustomerController {

    private final Db2Client db;

    public CustomerController(Db2Client db) {
        this.db = db;
    }

    @PostMapping
    public Map<String, Object> create(@RequestBody Map<String, Object> json, HttpServletRequest req) {
        Body b = new Body(json);
        try {
            ProcResult r = db.call(Channel.of(req), Channel.operator(req), "CUST.CREATE_CUSTOMER",
                    b.str("title"), b.req("firstName"), b.req("lastName"), Date.valueOf(b.req("dateOfBirth")),
                    b.str("niNumber"), b.integer("branchId"), b.str("email"), b.str("mobile"),
                    b.str("addressLine1"), b.str("town"), b.str("postcode"), Out.bigint(), Out.chr());
            return Map.of("customerId", r.outLong(12), "customerNo", r.out(13));
        } catch (BankException e) {
            // The onboarding screen predates the 75007 check and still looks for SQLCODE -803.
            if (e.getSqlCode() == Db2Client.SQLCODE_DUPLICATE_KEY) {
                throw new BankException("75007", e.getSqlCode(), "Customer already exists", e);
            }
            throw e;
        }
    }

    /** Every customer, paged, in the same shape as search. CUST.SEARCH_CUSTOMERS insists on a filter. */
    @GetMapping
    public Map<String, Object> list(@RequestParam(defaultValue = "1") int page,
                                    @RequestParam(defaultValue = "50") int pageSize) {
        int size = Math.max(1, Math.min(100, pageSize));
        int offset = (Math.max(1, page) - 1) * size;
        List<Map<String, Object>> rows = db.query("""
                SELECT C.CUSTOMER_ID, C.CUSTOMER_NO, C.TITLE, C.FIRST_NAME, C.LAST_NAME, C.DATE_OF_BIRTH,
                       (SELECT MAX(A.POSTCODE) FROM CUST.ADDRESS A
                         WHERE A.CUSTOMER_ID = C.CUSTOMER_ID AND A.ADDRESS_TYPE = 'H'
                           AND A.VALID_TO IS NULL) AS POSTCODE,
                       C.STATUS, C.KYC_STATUS, C.SEGMENT, C.HOME_BRANCH_ID
                  FROM CUST.CUSTOMER C
                 ORDER BY C.LAST_NAME, C.FIRST_NAME, C.CUSTOMER_ID
                OFFSET ? ROWS FETCH NEXT ? ROWS ONLY
                  WITH UR""", offset, size);
        Object total = db.query("SELECT COUNT(*) AS N FROM CUST.CUSTOMER WITH UR").get(0).get("N");
        return Map.of("totalRows", total, "customers", rows);
    }

    @GetMapping("/search")
    public Map<String, Object> search(@RequestParam(required = false) String lastName,
                                      @RequestParam(required = false) String firstName,
                                      @RequestParam(required = false) String postcode,
                                      @RequestParam(required = false) String customerNo,
                                      @RequestParam(required = false) String dateOfBirth,
                                      @RequestParam(defaultValue = "1") int page,
                                      @RequestParam(defaultValue = "25") int pageSize,
                                      HttpServletRequest req) {
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "CUST.SEARCH_CUSTOMERS",
                blank(lastName), blank(firstName), blank(postcode), blank(customerNo),
                dateOfBirth == null || dateOfBirth.isBlank() ? null : Date.valueOf(dateOfBirth),
                null, page, pageSize, Out.integer());
        return Map.of("totalRows", r.out(9), "customers", r.resultSet(0));
    }

    @GetMapping("/{id}")
    public Map<String, Object> customer360(@PathVariable long id,
                                           @RequestParam(defaultValue = "15") int txnRows,
                                           HttpServletRequest req) {
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "CUST.GET_CUSTOMER_360", id, txnRows);
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("customer", r.resultSet(0).isEmpty() ? null : r.resultSet(0).get(0));
        m.put("accounts", r.resultSet(1));
        m.put("recentTransactions", r.resultSet(2));
        return m;
    }

    @PostMapping("/{id}/contact")
    public Map<String, Object> updateContact(@PathVariable long id, @RequestBody Map<String, Object> json,
                                             HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "CUST.UPDATE_CONTACT", id,
                b.str("email"), b.str("mobile"), b.str("homePhone"), b.str("addressLine1"),
                b.str("addressLine2"), b.str("town"), b.str("postcode"), Out.integer());
        return Map.of("customerId", id, "rowsChanged", r.out(9));
    }

    @PostMapping("/{id}/kyc")
    public Map<String, Object> kyc(@PathVariable long id, @RequestBody Map<String, Object> json,
                                   HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "CUST.RECORD_KYC_CHECK", id,
                b.req("checkType"), b.req("result"), b.integer("score"), b.req("provider"), b.str("notes"),
                Out.bigint(), Out.chr());
        return Map.of("kycId", r.outLong(7), "kycStatus", r.out(8));
    }

    @PostMapping("/{id}/close")
    public Map<String, Object> close(@PathVariable long id, @RequestBody Map<String, Object> json,
                                     HttpServletRequest req) {
        Body b = new Body(json);
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "CUST.CLOSE_CUSTOMER", id,
                b.lng("sweepToAccountId"), b.str("reason"), Out.integer());
        return Map.of("customerId", id, "accountsClosed", r.out(4));
    }

    @GetMapping("/statements")
    public Map<String, Object> statement(@RequestParam long accountId,
                                         @RequestParam(required = false) Long statementId,
                                         HttpServletRequest req) {
        ProcResult r = db.call(Channel.of(req), Channel.operator(req), "CUST.GET_STATEMENT",
                accountId, statementId, Out.bigint());
        return Map.of("statementId", r.out(3) == null ? "" : r.out(3),
                "header", r.resultSet(0), "lines", r.resultSet(1));
    }

    private static String blank(String s) {
        return s == null || s.isBlank() ? null : s.trim();
    }
}

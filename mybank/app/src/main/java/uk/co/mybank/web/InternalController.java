package uk.co.mybank.web;

import java.util.List;
import java.util.Map;
import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import uk.co.mybank.db.Db2Client;

/** Random samples of live cards and accounts, used by the load generator. */
@RestController
@RequestMapping("/api/internal/sample")
@Profile("api")
public class InternalController {

    private final Db2Client db;

    public InternalController(Db2Client db) {
        this.db = db;
    }

    @GetMapping("/cards")
    public List<Map<String, Object>> cards(@RequestParam(defaultValue = "1000") int n) {
        return db.query("""
                SELECT C.CARD_ID AS "cardId", C.PAN AS "pan", C.ACCOUNT_ID AS "accountId",
                       C.CUSTOMER_ID AS "customerId"
                  FROM CARD.CARD C
                  JOIN ACCT.ACCOUNT A ON A.ACCOUNT_ID = C.ACCOUNT_ID
                 WHERE C.STATUS = 'A' AND A.STATUS = 'A'
                   AND C.EXPIRY_DATE >= (SELECT BUSINESS_DATE FROM REF.BANK_CONTROL)
                 ORDER BY RAND()
                 FETCH FIRST ? ROWS ONLY
                  WITH UR""", Math.min(n, 5000));
    }

    @GetMapping("/accounts")
    public List<Map<String, Object>> accounts(@RequestParam(defaultValue = "1000") int n) {
        return db.query("""
                SELECT A.ACCOUNT_ID AS "accountId", A.SORT_CODE AS "sortCode", A.ACCOUNT_NO AS "accountNo",
                       A.PRIMARY_CUSTOMER_ID AS "customerId", P.PRODUCT_TYPE AS "productType"
                  FROM ACCT.ACCOUNT A
                  JOIN REF.PRODUCT P ON P.PRODUCT_CODE = A.PRODUCT_CODE
                 WHERE A.STATUS = 'A' AND P.PRODUCT_TYPE IN ('CUR', 'SAV')
                 ORDER BY RAND()
                 FETCH FIRST ? ROWS ONLY
                  WITH UR""", Math.min(n, 5000));
    }

    @GetMapping("/merchants")
    public List<Map<String, Object>> merchants() {
        return db.query("""
                SELECT M.MERCHANT_ID AS "merchantId", M.MCC AS "mcc", C.RISK_WEIGHT AS "riskWeight"
                  FROM CARD.MERCHANT M
                  JOIN REF.MERCHANT_CATEGORY C ON C.MCC = M.MCC
                  WITH UR""");
    }
}

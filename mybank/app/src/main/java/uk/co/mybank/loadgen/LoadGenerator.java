package uk.co.mybank.loadgen;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Simulated traffic: card network authorisations, inbound Faster Payments from
 * other banks, and customers using web/mobile/branch channels. Everything goes
 * through the MyBank HTTP API, never the database.
 *
 * The target rate (transactions per second) can be changed at runtime from the
 * ops console. Fraud scenarios (card velocity, gambling spend, large payment to
 * a new payee) are injected occasionally, or on demand.
 */
@Component
@Profile("loadgen")
public class LoadGenerator {

    private static final Logger log = LoggerFactory.getLogger(LoadGenerator.class);

    /** Action mix, weights sum to ~100. */
    private static final List<Map.Entry<String, Double>> MIX = List.of(
            Map.entry("card_auth", 55.0),
            Map.entry("inbound_payment", 10.0),
            Map.entry("faster_payment", 7.0),
            Map.entry("transfer", 5.0),
            Map.entry("cash_withdrawal", 5.0),
            Map.entry("cash_deposit", 2.0),
            Map.entry("balance_enquiry", 9.0),
            Map.entry("statement_view", 3.0),
            Map.entry("new_customer", 1.2),
            Map.entry("new_payee", 1.0),
            Map.entry("standing_order", 0.5),
            Map.entry("dd_mandate", 0.5),
            Map.entry("block_card", 0.3),
            Map.entry("reverse_auth", 0.5));

    private final ObjectMapper json = new ObjectMapper();
    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
    private final ExecutorService workers = Executors.newVirtualThreadPerTaskExecutor();
    private final String baseUrl;
    private final double maxTps;

    private volatile double tps;
    private double carry;
    private final AtomicReference<List<JsonNode>> cards = new AtomicReference<>(List.of());
    private final AtomicReference<List<JsonNode>> accounts = new AtomicReference<>(List.of());
    private final AtomicReference<List<JsonNode>> merchants = new AtomicReference<>(List.of());
    private final List<Long> recentAuths = new java.util.concurrent.CopyOnWriteArrayList<>();
    private final Map<String, AtomicLong> counters = new ConcurrentHashMap<>();
    private final AtomicLong inFlight = new AtomicLong();

    public LoadGenerator(@Value("${mybank.loadgen.base-url}") String baseUrl,
                         @Value("${mybank.loadgen.initial-tps}") double initialTps,
                         @Value("${mybank.loadgen.max-tps}") double maxTps) {
        this.baseUrl = baseUrl;
        this.tps = initialTps;
        this.maxTps = maxTps;
    }

    public double getTps() { return tps; }

    public void setTps(double tps) {
        this.tps = Math.max(0, Math.min(maxTps, tps));
        log.info("Target rate set to {} tps", this.tps);
    }

    public Map<String, Object> status() {
        Map<String, Object> s = new LinkedHashMap<>();
        s.put("targetTps", tps);
        s.put("maxTps", maxTps);
        s.put("inFlight", inFlight.get());
        s.put("sampleCards", cards.get().size());
        s.put("sampleAccounts", accounts.get().size());
        Map<String, Long> c = new java.util.TreeMap<>();
        counters.forEach((k, v) -> c.put(k, v.get()));
        s.put("counters", c);
        return s;
    }

    /** Refresh the pool of cards/accounts/merchants to act on. */
    @Scheduled(initialDelay = 1_000, fixedDelay = 120_000)
    public void refreshSamples() {
        try {
            cards.set(list(get("/api/internal/sample/cards?n=3000")));
            accounts.set(list(get("/api/internal/sample/accounts?n=3000")));
            merchants.set(list(get("/api/internal/sample/merchants")));
            log.info("Samples: {} cards, {} accounts, {} merchants",
                    cards.get().size(), accounts.get().size(), merchants.get().size());
        } catch (Exception e) {
            log.warn("Could not refresh samples (is the API up?): {}", e.getMessage());
        }
    }

    @Scheduled(fixedRate = 100)
    public void tick() {
        if (cards.get().isEmpty() || accounts.get().isEmpty() || merchants.get().isEmpty()) {
            return;
        }
        carry += tps / 10.0;
        int n = (int) carry;
        carry -= n;
        if (inFlight.get() > Math.max(50, tps * 5)) {
            count("skipped_backpressure", n);
            return;
        }
        for (int i = 0; i < n; i++) {
            String action = pick();
            inFlight.incrementAndGet();
            workers.submit(() -> {
                try {
                    run(action);
                } catch (Exception e) {
                    count(action + ".error", 1);
                } finally {
                    inFlight.decrementAndGet();
                }
            });
        }
    }

    /** Roughly every three minutes, inject a fraud pattern. */
    @Scheduled(initialDelay = 60_000, fixedDelay = 180_000)
    public void randomScenario() {
        if (tps > 0 && !cards.get().isEmpty()) {
            String[] names = {"velocity", "gambling", "new_payee_large", "declines"};
            scenario(names[rnd().nextInt(names.length)]);
        }
    }

    public void scenario(String name) {
        log.info("Injecting fraud scenario: {}", name);
        count("scenario." + name, 1);
        workers.submit(() -> {
            try {
                switch (name) {
                    case "velocity" -> {
                        JsonNode card = any(cards.get());
                        for (int i = 0; i < 20; i++) {
                            authorise(card, any(merchants.get()), amount(2, 30));
                        }
                    }
                    case "gambling" -> {
                        JsonNode card = any(cards.get());
                        List<JsonNode> risky = merchants.get().stream()
                                .filter(m -> m.path("riskWeight").asInt() >= 5).toList();
                        for (int i = 0; i < 6 && !risky.isEmpty(); i++) {
                            authorise(card, any(risky), amount(80, 200));
                        }
                    }
                    case "new_payee_large" -> {
                        JsonNode acct = any(accounts.get());
                        post("/api/payments/faster", Map.of(
                                "accountId", acct.path("accountId").asLong(),
                                "amount", amount(2500, 9000),
                                "sortCode", randomSortCode(),
                                "accountNo", randomAccountNo(),
                                "name", "NEW PAYEE " + rnd().nextInt(1000),
                                "reference", "INVOICE",
                                "idempotencyKey", UUID.randomUUID().toString()));
                    }
                    case "declines" -> {
                        JsonNode card = any(cards.get());
                        for (int i = 0; i < 7; i++) {
                            authorise(card, any(merchants.get()), amount(3000, 6000));
                        }
                    }
                    default -> log.warn("Unknown scenario {}", name);
                }
            } catch (Exception e) {
                log.warn("Scenario {} failed: {}", name, e.getMessage());
            }
        });
    }

    private void run(String action) throws Exception {
        JsonNode acct = any(accounts.get());
        long accountId = acct.path("accountId").asLong();
        int status = switch (action) {
            case "card_auth" -> authorise(any(cards.get()), any(merchants.get()), cardAmount());
            case "inbound_payment" -> post("/api/scheme/inbound", Map.of(
                    "sortCode", acct.path("sortCode").asText(),
                    "accountNo", acct.path("accountNo").asText(),
                    "amount", amount(5, 400),
                    "remitterName", "SENDER " + rnd().nextInt(5000),
                    "remitterSort", randomSortCode(),
                    "remitterAccount", randomAccountNo(),
                    "reference", "FP" + rnd().nextInt(100000),
                    "schemeRef", "FPS" + UUID.randomUUID().toString().replace("-", "").substring(0, 20)));
            case "faster_payment" -> post("/api/payments/faster", Map.of(
                    "accountId", accountId,
                    "amount", amount(10, 350),
                    "sortCode", randomSortCode(),
                    "accountNo", randomAccountNo(),
                    "name", "PAYEE " + rnd().nextInt(5000),
                    "reference", "REF" + rnd().nextInt(10000),
                    "idempotencyKey", UUID.randomUUID().toString()));
            case "transfer" -> {
                JsonNode other = any(accounts.get());
                yield post("/api/transfers", Map.of(
                        "fromAccountId", accountId,
                        "toAccountId", other.path("accountId").asLong(),
                        "amount", amount(5, 200),
                        "reference", "TRANSFER"));
            }
            case "cash_withdrawal" -> post("/api/cash/withdraw", Map.of(
                    "accountId", accountId, "amount", (rnd().nextInt(10) + 1) * 20,
                    "branchId", branch(), "atmId", "ATM" + (1000 + rnd().nextInt(400))));
            case "cash_deposit" -> post("/api/cash/deposit", Map.of(
                    "accountId", accountId, "amount", amount(20, 800), "branchId", branch()));
            case "balance_enquiry" -> get("/api/accounts/" + accountId + "/balance").statusCode();
            case "statement_view" -> get("/api/accounts/" + accountId + "/transactions?pageSize=20").statusCode();
            case "new_customer" -> newCustomer();
            case "new_payee" -> post("/api/payees", Map.of(
                    "customerId", acct.path("customerId").asLong(),
                    "name", "PAYEE " + rnd().nextInt(5000),
                    "sortCode", randomSortCode(),
                    "accountNo", randomAccountNo(),
                    "reference", "REF" + rnd().nextInt(1000)));
            case "standing_order" -> post("/api/standing-orders", Map.of(
                    "accountId", accountId,
                    "name", "SO PAYEE " + rnd().nextInt(500),
                    "sortCode", randomSortCode(),
                    "accountNo", randomAccountNo(),
                    "amount", amount(10, 300),
                    "frequency", rnd().nextInt(10) < 8 ? "M" : "W"));
            case "dd_mandate" -> post("/api/mandates", Map.of(
                    "accountId", accountId,
                    "originatorId", String.valueOf(200000 + rnd().nextInt(800000)),
                    "originatorName", "ORIGINATOR " + rnd().nextInt(200),
                    "amount", amount(8, 120),
                    "collectionDay", rnd().nextInt(28) + 1));
            case "block_card" -> post("/api/cards/" + any(cards.get()).path("cardId").asLong() + "/block",
                    Map.of("reason", rnd().nextBoolean() ? "LOST" : "STOLEN"));
            case "reverse_auth" -> {
                Long authId = recentAuths.isEmpty() ? null : recentAuths.get(rnd().nextInt(recentAuths.size()));
                yield authId == null ? 0 : post("/api/cards/authorisations/" + authId + "/reverse", Map.of());
            }
            default -> 0;
        };
        count(action + "." + (status / 100) + "xx", 1);
    }

    private int authorise(JsonNode card, JsonNode merchant, double amount) throws Exception {
        HttpResponse<String> r = send("POST", "/api/cards/authorise", Map.of(
                "pan", card.path("pan").asText(),
                "merchantId", merchant.path("merchantId").asLong(),
                "amount", amount,
                "externalRef", "AUTH" + UUID.randomUUID().toString().replace("-", "").substring(0, 24)));
        if (r.statusCode() == 200) {
            JsonNode body = json.readTree(r.body());
            count("card_auth.response_" + body.path("responseCode").asText("??"), 1);
            if ("00".equals(body.path("responseCode").asText())) {
                recentAuths.add(body.path("authId").asLong());
                if (recentAuths.size() > 500) {
                    recentAuths.remove(0);
                }
            }
        }
        return r.statusCode();
    }

    private int newCustomer() throws Exception {
        String[] first = {"Amelia", "Oliver", "Isla", "Noah", "Ava", "Leo", "Mia", "Arthur", "Freya", "Jack"};
        String[] last = {"Smith", "Jones", "Patel", "Brown", "Taylor", "Khan", "Evans", "Wilson", "Hughes", "Wood"};
        String f = first[rnd().nextInt(first.length)];
        String l = last[rnd().nextInt(last.length)];
        int age = 18 + rnd().nextInt(60);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("title", rnd().nextBoolean() ? "Mr" : "Ms");
        body.put("firstName", f);
        body.put("lastName", l);
        body.put("dateOfBirth", java.time.LocalDate.now().minusYears(age).minusDays(rnd().nextInt(360)).toString());
        body.put("branchId", 12);
        body.put("email", f.toLowerCase() + "." + l.toLowerCase() + rnd().nextInt(100000) + "@example.com");
        body.put("mobile", "07700" + (900000 + rnd().nextInt(99999)));
        body.put("addressLine1", (rnd().nextInt(200) + 1) + " High Street");
        body.put("town", "London");
        body.put("postcode", "E" + (rnd().nextInt(20) + 1) + " " + (rnd().nextInt(9) + 1) + "AB");
        HttpResponse<String> r = send("POST", "/api/customers", body);
        if (r.statusCode() != 200) {
            return r.statusCode();
        }
        long customerId = json.readTree(r.body()).path("customerId").asLong();
        HttpResponse<String> a = send("POST", "/api/accounts", Map.of(
                "customerId", customerId, "productCode", "CUR001", "branchId", 12,
                "openingDeposit", amount(50, 1500)));
        if (a.statusCode() == 200) {
            long accountId = json.readTree(a.body()).path("accountId").asLong();
            send("POST", "/api/cards", Map.of("accountId", accountId, "customerId", customerId));
        }
        return a.statusCode();
    }

    // ---- helpers

    private String pick() {
        double total = MIX.stream().mapToDouble(Map.Entry::getValue).sum();
        double r = rnd().nextDouble() * total;
        for (Map.Entry<String, Double> e : MIX) {
            r -= e.getValue();
            if (r <= 0) {
                return e.getKey();
            }
        }
        return MIX.get(0).getKey();
    }

    private double cardAmount() {
        double r = rnd().nextDouble();
        return r < 0.6 ? amount(2, 25) : r < 0.9 ? amount(25, 90) : amount(90, 450);
    }

    private static double amount(double lo, double hi) {
        return Math.round((lo + rnd().nextDouble() * (hi - lo)) * 100) / 100.0;
    }

    /** A branch with a counter (not the closed Sheffield branch or Digital). */
    private static int branch() {
        int[] open = {1, 2, 3, 4, 5, 7, 8, 9, 10, 11};
        return open[rnd().nextInt(open.length)];
    }

    private static String randomSortCode() {
        return String.format("%02d%02d%02d", 10 + rnd().nextInt(89), rnd().nextInt(100), rnd().nextInt(100));
    }

    /** Must match UTIL.ACCOUNT_CHECK_DIGIT: weights 7..1, modulus 10. */
    static String randomAccountNo() {
        String base = String.valueOf(1_000_000 + rnd().nextInt(9_000_000));
        int sum = 0;
        for (int i = 0; i < 7; i++) {
            sum += (base.charAt(i) - '0') * (7 - i);
        }
        return base + (sum % 10);
    }

    private static ThreadLocalRandom rnd() {
        return ThreadLocalRandom.current();
    }

    private static <T> T any(List<T> list) {
        return list.get(rnd().nextInt(list.size()));
    }

    private void count(String key, long n) {
        counters.computeIfAbsent(key, k -> new AtomicLong()).addAndGet(n);
    }

    private List<JsonNode> list(HttpResponse<String> r) throws Exception {
        List<JsonNode> out = new ArrayList<>();
        json.readTree(r.body()).forEach(out::add);
        return out;
    }

    private HttpResponse<String> get(String path) throws Exception {
        return http.send(HttpRequest.newBuilder(URI.create(baseUrl + path))
                .header("X-Channel", "API").timeout(Duration.ofSeconds(30)).GET().build(),
                HttpResponse.BodyHandlers.ofString());
    }

    private int post(String path, Map<String, ?> body) throws Exception {
        return send("POST", path, body).statusCode();
    }

    private HttpResponse<String> send(String method, String path, Map<String, ?> body) throws Exception {
        String channel = path.startsWith("/api/cards/authorise") || path.startsWith("/api/scheme") ? "API"
                : path.startsWith("/api/cash") ? "BRN" : rnd().nextBoolean() ? "MOB" : "WEB";
        return http.send(HttpRequest.newBuilder(URI.create(baseUrl + path))
                        .header("Content-Type", "application/json")
                        .header("X-Channel", channel)
                        .header("X-Operator", "LOADGEN")
                        .timeout(Duration.ofSeconds(30))
                        .method(method, HttpRequest.BodyPublishers.ofString(json.writeValueAsString(body)))
                        .build(),
                HttpResponse.BodyHandlers.ofString());
    }
}

package uk.co.mybank.web;

import jakarta.servlet.http.HttpServletRequest;
import java.util.Set;

/** Resolves the Db2 session channel/operator from request headers. */
final class Channel {
    private static final Set<String> CHANNELS = Set.of("WEB", "MOB", "BRN", "API", "SYS");

    private Channel() {}

    static String of(HttpServletRequest req) {
        String c = req.getHeader("X-Channel");
        return c != null && CHANNELS.contains(c.toUpperCase()) ? c.toUpperCase() : "WEB";
    }

    static String operator(HttpServletRequest req) {
        String o = req.getHeader("X-Operator");
        return o == null || o.isBlank() ? "WEBUSER" : o.length() > 30 ? o.substring(0, 30) : o;
    }
}

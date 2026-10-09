package uk.co.mybank.web;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Map;

/** Small helpers for reading loosely typed JSON request bodies. */
final class Body {
    private final Map<String, Object> m;

    Body(Map<String, Object> m) {
        this.m = m == null ? Map.of() : m;
    }

    String str(String key) {
        Object v = m.get(key);
        return v == null ? null : v.toString();
    }

    String req(String key) {
        String v = str(key);
        if (v == null || v.isBlank()) {
            throw new IllegalArgumentException(key + " is required");
        }
        return v;
    }

    Long lng(String key) {
        Object v = m.get(key);
        return v == null ? null : v instanceof Number n ? n.longValue() : Long.valueOf(v.toString());
    }

    Integer integer(String key) {
        Long v = lng(key);
        return v == null ? null : v.intValue();
    }

    BigDecimal money(String key) {
        Object v = m.get(key);
        return v == null ? null : new BigDecimal(v.toString()).setScale(2, java.math.RoundingMode.HALF_UP);
    }

    LocalDate date(String key) {
        String v = str(key);
        return v == null || v.isBlank() ? null : LocalDate.parse(v);
    }
}

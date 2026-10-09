package uk.co.mybank.db;

import java.math.BigDecimal;
import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Types;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import javax.sql.DataSource;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;

/**
 * Thin JDBC layer over the MYBANK stored procedures.
 *
 * Every unit of work runs on one pooled connection with the Db2 session global
 * variables UTIL.GV_CHANNEL and UTIL.GV_OPERATOR set first (triggers and the
 * audit log read them). Each unit of work is committed on success and rolled
 * back on failure; batch procedures also commit internally.
 */
@Component
@Profile("api | scheduler")
public class Db2Client {

    /** SQLCODE -803: duplicate key. Some legacy code paths check for this explicitly. */
    public static final int SQLCODE_DUPLICATE_KEY = -803;
    /** SQLCODE -438: application raised error (SIGNAL). */
    public static final int SQLCODE_SIGNAL = -438;

    private static final Pattern ERRMC = Pattern.compile("SQLERRMC=([^,]*)");

    private final DataSource dataSource;

    public Db2Client(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @FunctionalInterface
    public interface Work<T> {
        T run(Connection conn) throws SQLException;
    }

    public <T> T withConnection(String channel, String operator, Work<T> work) {
        try (Connection conn = dataSource.getConnection()) {
            // A failed CALL is not atomic in Db2: work the procedure did before the
            // error stays in the unit of work. Commit or roll back explicitly.
            conn.setAutoCommit(false);
            try {
                try (PreparedStatement ps = conn.prepareStatement("SET UTIL.GV_CHANNEL = ?")) {
                    ps.setString(1, channel);
                    ps.execute();
                }
                try (PreparedStatement ps = conn.prepareStatement("SET UTIL.GV_OPERATOR = ?")) {
                    ps.setString(1, operator);
                    ps.execute();
                }
                T result = work.run(conn);
                conn.commit();
                return result;
            } catch (SQLException | RuntimeException e) {
                conn.rollback();
                throw e;
            }
        } catch (SQLException e) {
            throw translate(e);
        }
    }

    /** Calls a procedure and returns OUT parameters plus any result sets. */
    public ProcResult call(String channel, String operator, String procName, Object... params) {
        return withConnection(channel, operator, conn -> call(conn, procName, params));
    }

    public ProcResult call(Connection conn, String procName, Object... params) throws SQLException {
        String placeholders = String.join(", ", java.util.Collections.nCopies(params.length, "?"));
        try (CallableStatement cs = conn.prepareCall("CALL " + procName + "(" + placeholders + ")")) {
            List<Integer> outIndexes = new ArrayList<>();
            java.sql.ParameterMetaData pmd = null;
            for (int i = 0; i < params.length; i++) {
                Object p = params[i];
                int idx = i + 1;
                if (p instanceof Out out) {
                    cs.registerOutParameter(idx, out.sqlType());
                    outIndexes.add(idx);
                } else if (p == null) {
                    if (pmd == null) {
                        pmd = cs.getParameterMetaData();
                    }
                    cs.setNull(idx, pmd.getParameterType(idx));
                } else {
                    cs.setObject(idx, p);
                }
            }
            boolean hasResults = cs.execute();
            List<List<Map<String, Object>>> resultSets = new ArrayList<>();
            while (true) {
                if (hasResults) {
                    try (ResultSet rs = cs.getResultSet()) {
                        resultSets.add(rows(rs));
                    }
                } else if (cs.getUpdateCount() == -1) {
                    break;
                }
                hasResults = cs.getMoreResults();
            }
            Map<Integer, Object> outs = new LinkedHashMap<>();
            for (int idx : outIndexes) {
                outs.put(idx, cs.getObject(idx));
            }
            return new ProcResult(outs, resultSets);
        }
    }

    public List<Map<String, Object>> query(String sql, Object... params) {
        return withConnection("SYS", "SYSTEM", conn -> {
            try (PreparedStatement ps = conn.prepareStatement(sql)) {
                for (int i = 0; i < params.length; i++) {
                    ps.setObject(i + 1, params[i]);
                }
                try (ResultSet rs = ps.executeQuery()) {
                    return rows(rs);
                }
            }
        });
    }

    public int update(String sql, Object... params) {
        return withConnection("SYS", "SYSTEM", conn -> {
            try (PreparedStatement ps = conn.prepareStatement(sql)) {
                for (int i = 0; i < params.length; i++) {
                    ps.setObject(i + 1, params[i]);
                }
                return ps.executeUpdate();
            }
        });
    }

    static List<Map<String, Object>> rows(ResultSet rs) throws SQLException {
        ResultSetMetaData md = rs.getMetaData();
        List<Map<String, Object>> rows = new ArrayList<>();
        while (rs.next()) {
            Map<String, Object> row = new LinkedHashMap<>();
            for (int c = 1; c <= md.getColumnCount(); c++) {
                Object v = rs.getObject(c);
                if (v instanceof java.sql.Date d) {
                    v = d.toLocalDate();
                } else if (v instanceof java.sql.Timestamp t) {
                    v = t.toLocalDateTime();
                } else if (v instanceof String s) {
                    v = s.stripTrailing();
                } else if (v instanceof java.sql.SQLXML x) {
                    v = x.getString();
                } else if (v instanceof java.sql.Clob clob) {
                    v = clob.getSubString(1, (int) clob.length());
                }
                row.put(md.getColumnLabel(c), v);
            }
            rows.add(row);
        }
        return rows;
    }

    /**
     * Maps a Db2 SQLException to a BankException. SIGNALled business errors carry
     * SQLSTATE 75xxx and the message text in SQLERRMC.
     */
    public static BankException translate(SQLException e) {
        SQLException root = e;
        while (root.getNextException() != null && root.getSQLState() == null) {
            root = root.getNextException();
        }
        String state = root.getSQLState();
        int code = root.getErrorCode();
        String msg = root.getMessage();
        Matcher m = ERRMC.matcher(msg == null ? "" : msg);
        if (m.find() && !m.group(1).isBlank()) {
            msg = m.group(1);
        } else if (msg != null && msg.contains("\"")) {
            int a = msg.indexOf('"');
            int b = msg.indexOf('"', a + 1);
            if (b > a) {
                msg = msg.substring(a + 1, b);
            }
        }
        return new BankException(state, code, msg, e);
    }

    /** Marker for an OUT parameter. */
    public record Out(int sqlType) {
        public static Out bigint() { return new Out(Types.BIGINT); }
        public static Out integer() { return new Out(Types.INTEGER); }
        public static Out decimal() { return new Out(Types.DECIMAL); }
        public static Out varchar() { return new Out(Types.VARCHAR); }
        public static Out chr() { return new Out(Types.CHAR); }
        public static Out date() { return new Out(Types.DATE); }
        public static Out timestamp() { return new Out(Types.TIMESTAMP); }
    }

    public record ProcResult(Map<Integer, Object> outs, List<List<Map<String, Object>>> resultSets) {
        public Object out(int index) {
            Object v = outs.get(index);
            return v instanceof String s ? s.stripTrailing() : v;
        }
        public Long outLong(int index) {
            Object v = outs.get(index);
            return v == null ? null : ((Number) v).longValue();
        }
        public BigDecimal outDecimal(int index) {
            return (BigDecimal) outs.get(index);
        }
        public List<Map<String, Object>> resultSet(int i) {
            return i < resultSets.size() ? resultSets.get(i) : List.of();
        }
    }
}

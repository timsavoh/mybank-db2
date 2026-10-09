package uk.co.mybank.db;

/**
 * A business error raised by a stored procedure via SIGNAL SQLSTATE '75xxx',
 * or a database error we could not map.
 */
public class BankException extends RuntimeException {
    private final String sqlState;
    private final int sqlCode;

    public BankException(String sqlState, int sqlCode, String message, Throwable cause) {
        super(message, cause);
        this.sqlState = sqlState;
        this.sqlCode = sqlCode;
    }

    public String getSqlState() { return sqlState; }
    public int getSqlCode() { return sqlCode; }

    public boolean isBusinessError() {
        return sqlState != null && sqlState.startsWith("75");
    }
}

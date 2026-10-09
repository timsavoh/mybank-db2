package uk.co.mybank.web;

import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import uk.co.mybank.db.BankException;
import uk.co.mybank.db.Db2Client;

/** Maps procedure SQLSTATEs to HTTP responses. The API contract depends on these codes. */
@RestControllerAdvice
@Profile("api")
public class ApiExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(ApiExceptionHandler.class);

    @ExceptionHandler(BankException.class)
    public ResponseEntity<Map<String, Object>> handle(BankException e) {
        HttpStatus status = switch (e.getSqlState() == null ? "" : e.getSqlState()) {
            case "75002", "75004", "75005", "75012", "75013" -> HttpStatus.NOT_FOUND;
            case "75007" -> HttpStatus.CONFLICT;
            case "75008", "75011" -> HttpStatus.BAD_REQUEST;
            case "75001", "75003", "75006", "75009", "75010", "75014", "75015" -> HttpStatus.UNPROCESSABLE_ENTITY;
            default -> e.getSqlCode() == Db2Client.SQLCODE_DUPLICATE_KEY
                    ? HttpStatus.CONFLICT : HttpStatus.INTERNAL_SERVER_ERROR;
        };
        if (status == HttpStatus.INTERNAL_SERVER_ERROR) {
            log.error("Database error SQLSTATE={} SQLCODE={}", e.getSqlState(), e.getSqlCode(), e);
        }
        return ResponseEntity.status(status).body(Map.of(
                "error", e.getMessage() == null ? "" : e.getMessage(),
                "sqlState", e.getSqlState() == null ? "" : e.getSqlState(),
                "sqlCode", e.getSqlCode()));
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<Map<String, Object>> badRequest(IllegalArgumentException e) {
        return ResponseEntity.badRequest().body(Map.of("error", e.getMessage()));
    }
}

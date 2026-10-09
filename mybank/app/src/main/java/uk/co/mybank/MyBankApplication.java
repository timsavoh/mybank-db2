package uk.co.mybank;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * MyBank core application. One jar, three roles selected by Spring profile:
 * <ul>
 *   <li>{@code api} - REST API and web UI over the Db2 stored procedures</li>
 *   <li>{@code scheduler} - batch scheduler (stands in for Control-M)</li>
 *   <li>{@code loadgen} - simulated customers, card network and payment scheme</li>
 * </ul>
 */
@SpringBootApplication
@EnableScheduling
public class MyBankApplication {
    public static void main(String[] args) {
        SpringApplication.run(MyBankApplication.class, args);
    }
}

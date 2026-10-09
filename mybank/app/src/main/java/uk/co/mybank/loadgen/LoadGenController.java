package uk.co.mybank.loadgen;

import java.util.Map;
import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** Control surface for the load generator, used by the ops console. */
@RestController
@RequestMapping("/loadgen")
@Profile("loadgen")
public class LoadGenController {

    private final LoadGenerator generator;

    public LoadGenController(LoadGenerator generator) {
        this.generator = generator;
    }

    @GetMapping("/status")
    public Map<String, Object> status() {
        return generator.status();
    }

    @PostMapping("/rate")
    public Map<String, Object> rate(@RequestBody Map<String, Number> body) {
        generator.setTps(body.getOrDefault("tps", 0).doubleValue());
        return generator.status();
    }

    @PostMapping("/scenario/{name}")
    public Map<String, Object> scenario(@PathVariable String name) {
        generator.scenario(name);
        return Map.of("injected", name);
    }
}

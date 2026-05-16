package main.features.search.api;

import main.features.config.api.ConfigProvider;
import main.features.config.core.DefaultProjectScanner;

/** Searches for projects with optional text search. */
public interface Searcher {
    void run(DefaultProjectScanner ctx, String[] profileKeys, ConfigProvider config, String text);
}

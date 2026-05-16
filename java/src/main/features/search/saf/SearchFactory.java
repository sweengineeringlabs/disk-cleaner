package main.features.search.saf;

import main.features.search.core.DefaultSearcher;
import main.features.config.api.ConfigProvider;
import main.features.config.core.DefaultProjectScanner;

/** Factory entry point for the search feature. */
public class SearchFactory {
    public static void run(DefaultProjectScanner ctx, String[] profileKeys, ConfigProvider config, String text) {
        var searcher = new DefaultSearcher();
        searcher.run(ctx, profileKeys, config, text);
    }
}

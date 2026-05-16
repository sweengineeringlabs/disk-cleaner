package main.features.config.api;

/** Provides access to TOML configuration values. */
public interface ConfigProvider {
    String getValue(String key);
    String[] getArray(String key);
    String[] profileKeys();
}

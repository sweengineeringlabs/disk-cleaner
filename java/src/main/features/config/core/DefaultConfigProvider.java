package main.features.config.core;

import main.features.config.api.ConfigProvider;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.IOException;

/** Pure-Java TOML config parser. Supports single-line key=value and inline arrays. */
public class DefaultConfigProvider implements ConfigProvider {

    private String[] keys;
    private String[] values;
    private int size;
    private String[] profiles;
    private int profileCount;

    DefaultConfigProvider() {
        keys = new String[256];
        values = new String[256];
        size = 0;
        profiles = new String[32];
        profileCount = 0;
    }

    public static DefaultConfigProvider load(String path) {
        var file = new File(path);
        if (!file.exists()) {
            System.err.println("Config file not found: " + path);
            return null;
        }

        var config = new DefaultConfigProvider();
        var currentSection = "";

        try {
            var reader = new BufferedReader(new FileReader(file));
            String rawLine;
            while ((rawLine = reader.readLine()) != null) {
                var line = stripComment(rawLine).trim();
                if (line.isEmpty()) continue;

                if (line.startsWith("[") && line.endsWith("]")) {
                    currentSection = line.substring(1, line.length() - 1);
                    if (currentSection.startsWith("profiles.")) {
                        var profileKey = currentSection.substring("profiles.".length());
                        config.profiles[config.profileCount] = profileKey;
                        config.profileCount++;
                    }
                    continue;
                }

                int eq = line.indexOf('=');
                if (eq > 0) {
                    var key = line.substring(0, eq).trim();
                    var value = line.substring(eq + 1).trim();
                    var fullKey = currentSection.isEmpty() ? key : currentSection + "." + key;
                    config.keys[config.size] = fullKey;
                    config.values[config.size] = value;
                    config.size++;
                }
            }
            reader.close();
        } catch (IOException e) {
            System.err.println("Error reading config: " + e.getMessage());
            return null;
        }

        return config;
    }

    public String getValue(String key) {
        for (int i = 0; i < size; i++) {
            if (keys[i].equals(key)) {
                return stripQuotes(values[i]);
            }
        }
        return "";
    }

    public String[] getArray(String key) {
        for (int i = 0; i < size; i++) {
            if (keys[i].equals(key)) {
                var raw = values[i].trim();
                if (raw.startsWith("[")) raw = raw.substring(1);
                if (raw.endsWith("]")) raw = raw.substring(0, raw.length() - 1);
                raw = raw.trim();
                if (raw.isEmpty()) return new String[0];

                var parts = raw.split(",");
                var result = new String[parts.length];
                int count = 0;
                for (int j = 0; j < parts.length; j++) {
                    var item = stripQuotes(parts[j].trim());
                    if (!item.isEmpty()) {
                        result[count] = item;
                        count++;
                    }
                }
                var trimmed = new String[count];
                for (int j = 0; j < count; j++) trimmed[j] = result[j];
                return trimmed;
            }
        }
        return new String[0];
    }

    public String[] profileKeys() {
        var result = new String[profileCount];
        for (int i = 0; i < profileCount; i++) {
            result[i] = profiles[i];
        }
        return result;
    }

    /** Strip inline comments, respecting quoted strings. */
    private static String stripComment(String line) {
        boolean inSingle = false;
        boolean inDouble = false;
        for (int i = 0; i < line.length(); i++) {
            char ch = line.charAt(i);
            if (ch == '\'' && !inDouble) inSingle = !inSingle;
            else if (ch == '"' && !inSingle) inDouble = !inDouble;
            else if (ch == '#' && !inSingle && !inDouble) return line.substring(0, i);
        }
        return line;
    }

    private static String stripQuotes(String s) {
        s = s.trim();
        if ((s.startsWith("\"") && s.endsWith("\"")) || (s.startsWith("'") && s.endsWith("'"))) {
            return s.substring(1, s.length() - 1);
        }
        return s;
    }
}

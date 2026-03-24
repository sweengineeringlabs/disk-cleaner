package config;

import java.io.File;
import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;

/**
 * Pure-Java TOML config parser matching the PowerShell/Rust TomlConfig.
 * Supports single-line key=value pairs and inline arrays.
 */
class TomlConfig {

    private String[] keys;
    private String[] values;
    private int size;
    private String[] profiles;
    private int profileCount;

    TomlConfig() {
        keys = new String[256];
        values = new String[256];
        size = 0;
        profiles = new String[32];
        profileCount = 0;
    }

    static TomlConfig load(String path) {
        var file = new File(path);
        if (!file.exists()) {
            System.err.println("Config file not found: " + path);
            return null;
        }

        var config = new TomlConfig();
        var currentSection = "";

        try {
            var reader = new BufferedReader(new FileReader(file));
            String rawLine;
            while ((rawLine = reader.readLine()) != null) {
                var line = stripComment(rawLine).trim();
                if (line.isEmpty()) continue;

                // Section header
                if (line.startsWith("[") && line.endsWith("]")) {
                    currentSection = line.substring(1, line.length() - 1);
                    if (currentSection.startsWith("profiles.")) {
                        var profileKey = currentSection.substring("profiles.".length());
                        config.profiles[config.profileCount] = profileKey;
                        config.profileCount++;
                    }
                    continue;
                }

                // Key = value
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

    String getValue(String key) {
        for (int i = 0; i < size; i++) {
            if (keys[i].equals(key)) {
                return stripQuotes(values[i]);
            }
        }
        return "";
    }

    String[] getArray(String key) {
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
                    var item = parts[j].trim();
                    item = stripQuotes(item);
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

    String[] profileKeys() {
        var result = new String[profileCount];
        for (int i = 0; i < profileCount; i++) {
            result[i] = profiles[i];
        }
        return result;
    }

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

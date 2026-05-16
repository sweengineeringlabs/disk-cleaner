package main.features.monitor.core;

import main.features.monitor.api.HistoryEntry;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.IOException;
import java.nio.file.Path;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;

/** JSON file-backed history store. Keeps last 100 entries. */
public class DefaultHistoryStore {

    private static final int MAX_ENTRIES = 100;
    private String filePath;

    public DefaultHistoryStore(String configDir) {
        this.filePath = Path.of(configDir, "history.json").toString();
    }

    public void record(HistoryEntry entry) {
        if (entry.timestamp == null || entry.timestamp.isEmpty()) {
            entry.timestamp = OffsetDateTime.now().format(DateTimeFormatter.ISO_OFFSET_DATE_TIME);
        }

        var entries = load();
        entries = append(entries, entry);

        // Keep last MAX_ENTRIES
        if (entries.length > MAX_ENTRIES) {
            var trimmed = new HistoryEntry[MAX_ENTRIES];
            int start = entries.length - MAX_ENTRIES;
            for (int i = 0; i < MAX_ENTRIES; i++) trimmed[i] = entries[start + i];
            entries = trimmed;
        }

        // Write as JSON
        var sb = new StringBuilder();
        sb.append("[\n");
        for (int i = 0; i < entries.length; i++) {
            var e = entries[i];
            sb.append("  {");
            sb.append("\"timestamp\":\"").append(escape(e.timestamp)).append("\",");
            sb.append("\"command\":\"").append(escape(e.command)).append("\",");
            sb.append("\"profiles\":\"").append(escape(e.profiles)).append("\",");
            sb.append("\"projects\":").append(e.projects).append(",");
            sb.append("\"size_bytes\":").append(e.sizeBytes).append(",");
            sb.append("\"size_formatted\":\"").append(escape(e.sizeFormatted)).append("\",");
            sb.append("\"path\":\"").append(escape(e.path)).append("\"");
            sb.append("}");
            if (i < entries.length - 1) sb.append(",");
            sb.append("\n");
        }
        sb.append("]");

        try {
            var writer = new java.io.FileWriter(filePath);
            writer.write(sb.toString());
            writer.close();
        } catch (IOException e) { /* ignore */ }
    }

    public HistoryEntry[] load() {
        var file = new File(filePath);
        if (!file.exists()) return new HistoryEntry[0];

        try {
            var reader = new BufferedReader(new FileReader(file));
            var sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) sb.append(line);
            reader.close();
            var raw = sb.toString().trim();
            if (raw.isEmpty() || !raw.startsWith("[")) return new HistoryEntry[0];

            return parseEntries(raw);
        } catch (IOException e) {
            return new HistoryEntry[0];
        }
    }

    /** Minimal JSON array parser for history entries. */
    private HistoryEntry[] parseEntries(String json) {
        var entries = new HistoryEntry[0];
        int pos = 0;
        while (pos < json.length()) {
            int objStart = json.indexOf('{', pos);
            if (objStart < 0) break;
            int objEnd = json.indexOf('}', objStart);
            if (objEnd < 0) break;

            var obj = json.substring(objStart + 1, objEnd);
            var entry = new HistoryEntry();
            entry.timestamp = extractJsonString(obj, "timestamp");
            entry.command = extractJsonString(obj, "command");
            entry.profiles = extractJsonString(obj, "profiles");
            entry.projects = extractJsonInt(obj, "projects");
            entry.sizeBytes = extractJsonLong(obj, "size_bytes");
            entry.sizeFormatted = extractJsonString(obj, "size_formatted");
            entry.path = extractJsonString(obj, "path");
            entries = append(entries, entry);

            pos = objEnd + 1;
        }
        return entries;
    }

    private String extractJsonString(String obj, String key) {
        var search = "\"" + key + "\":\"";
        int start = obj.indexOf(search);
        if (start < 0) return "";
        start += search.length();
        int end = obj.indexOf("\"", start);
        if (end < 0) return "";
        return obj.substring(start, end);
    }

    private int extractJsonInt(String obj, String key) {
        var val = extractJsonNumber(obj, key);
        if (val.isEmpty()) return 0;
        try { return Integer.parseInt(val); } catch (NumberFormatException e) { return 0; }
    }

    private long extractJsonLong(String obj, String key) {
        var val = extractJsonNumber(obj, key);
        if (val.isEmpty()) return 0;
        try { return Long.parseLong(val); } catch (NumberFormatException e) { return 0; }
    }

    private String extractJsonNumber(String obj, String key) {
        var search = "\"" + key + "\":";
        int start = obj.indexOf(search);
        if (start < 0) return "";
        start += search.length();
        var sb = new StringBuilder();
        while (start < obj.length()) {
            char ch = obj.charAt(start);
            if (ch == ',' || ch == '}' || ch == ' ') break;
            sb.append(ch);
            start++;
        }
        return sb.toString().trim();
    }

    private String escape(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private HistoryEntry[] append(HistoryEntry[] arr, HistoryEntry item) {
        var result = new HistoryEntry[arr.length + 1];
        for (int i = 0; i < arr.length; i++) result[i] = arr[i];
        result[arr.length] = item;
        return result;
    }
}

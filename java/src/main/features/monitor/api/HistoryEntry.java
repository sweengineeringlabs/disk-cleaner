package main.features.monitor.api;

/** A single run history entry. */
public class HistoryEntry {
    public String timestamp;
    public String command;
    public String profiles;
    public int projects;
    public long sizeBytes;
    public String sizeFormatted;
    public String path;
}

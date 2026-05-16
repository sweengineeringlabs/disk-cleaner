package main.features.config.api;

/** Represents a language profile loaded from TOML config. */
public class CleanProfile {
    public String key;
    public String name;
    public String marker;
    public String[] altMarkers;
    public String profileType;
    public String command;
    public String wrapper;
    public String wrapperWindows;
    public String cleanDir;
    public String[] targets;
    public String[] optionalTargets;
    public String[] recursiveTargets;
    public String[] sourceExtensions;
    public String[] searchExclude;
    public String buildCommand;
    public String outputPattern;

    /** All marker files: primary + alternates. */
    public String[] allMarkers() {
        var result = new String[1 + altMarkers.length];
        result[0] = marker;
        for (int i = 0; i < altMarkers.length; i++) {
            result[i + 1] = altMarkers[i];
        }
        return result;
    }
}

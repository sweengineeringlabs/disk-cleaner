package model;

import config.TomlConfig;

/**
 * Represents a language profile loaded from TOML config.
 */
class CleanProfile {
    String key;
    String name;
    String marker;
    String[] altMarkers;
    String profileType;
    String command;
    String wrapper;
    String wrapperWindows;
    String cleanDir;
    String[] targets;
    String[] optionalTargets;
    String[] recursiveTargets;
    String[] sourceExtensions;
    String[] searchExclude;
    String buildCommand;
    String outputPattern;

    static CleanProfile fromToml(String key, TomlConfig toml) {
        var p = new CleanProfile();
        var prefix = "profiles." + key;

        p.key = key;
        p.name = toml.getValue(prefix + ".name");
        p.marker = toml.getValue(prefix + ".marker");
        p.altMarkers = toml.getArray(prefix + ".alt_markers");
        p.profileType = toml.getValue(prefix + ".type");
        p.command = toml.getValue(prefix + ".command");
        p.wrapper = toml.getValue(prefix + ".wrapper");
        p.wrapperWindows = toml.getValue(prefix + ".wrapper_windows");
        p.cleanDir = toml.getValue(prefix + ".clean_dir");
        p.targets = toml.getArray(prefix + ".targets");
        p.optionalTargets = toml.getArray(prefix + ".optional_targets");
        p.recursiveTargets = toml.getArray(prefix + ".recursive_targets");
        p.sourceExtensions = toml.getArray(prefix + ".source_extensions");
        p.searchExclude = toml.getArray(prefix + ".search_exclude");
        p.buildCommand = toml.getValue(prefix + ".build_command");
        p.outputPattern = toml.getValue(prefix + ".output_pattern");

        return p;
    }

    /** All marker files: primary + alternates. */
    String[] allMarkers() {
        var result = new String[1 + altMarkers.length];
        result[0] = marker;
        for (int i = 0; i < altMarkers.length; i++) {
            result[i + 1] = altMarkers[i];
        }
        return result;
    }
}

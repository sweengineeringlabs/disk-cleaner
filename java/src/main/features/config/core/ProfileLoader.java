package main.features.config.core;

import main.features.config.api.CleanProfile;
import main.features.config.api.ConfigProvider;

/** Loads a CleanProfile from config by key. */
public class ProfileLoader {

    public static CleanProfile load(String key, ConfigProvider config) {
        var p = new CleanProfile();
        var prefix = "profiles." + key;

        p.key = key;
        p.name = config.getValue(prefix + ".name");
        p.marker = config.getValue(prefix + ".marker");
        p.altMarkers = config.getArray(prefix + ".alt_markers");
        p.profileType = config.getValue(prefix + ".type");
        p.command = config.getValue(prefix + ".command");
        p.wrapper = config.getValue(prefix + ".wrapper");
        p.wrapperWindows = config.getValue(prefix + ".wrapper_windows");
        p.cleanDir = config.getValue(prefix + ".clean_dir");
        p.targets = config.getArray(prefix + ".targets");
        p.optionalTargets = config.getArray(prefix + ".optional_targets");
        p.recursiveTargets = config.getArray(prefix + ".recursive_targets");
        p.sourceExtensions = config.getArray(prefix + ".source_extensions");
        p.searchExclude = config.getArray(prefix + ".search_exclude");
        p.buildCommand = config.getValue(prefix + ".build_command");
        p.outputPattern = config.getValue(prefix + ".output_pattern");

        return p;
    }
}

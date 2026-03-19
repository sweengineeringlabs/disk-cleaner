# CleanProfile.ps1 - Profile data model for disk-cleaner

class CleanProfile {
    [string]   $Key
    [string]   $Name
    [string]   $Marker
    [string[]] $AltMarkers
    [string]   $Type
    [string]   $Command
    [string]   $CleanDir
    [string]   $OutputPattern
    [string]   $Wrapper
    [string[]] $Targets
    [string[]] $OptionalTargets
    [string[]] $RecursiveTargets
    [string[]] $SourceExtensions
    [string[]] $SearchExclude

    CleanProfile([string]$key, [TomlConfig]$config) {
        $this.Key            = $key
        $this.Name           = $config.GetValue("profiles.$key.name")
        $this.Marker         = $config.GetValue("profiles.$key.marker")
        $this.Type           = $config.GetValue("profiles.$key.type")
        $this.Command        = $config.GetValue("profiles.$key.command")
        $this.CleanDir       = $config.GetValue("profiles.$key.clean_dir")
        $this.OutputPattern  = $config.GetValue("profiles.$key.output_pattern")

        $this.Wrapper = $config.GetValue("profiles.$key.wrapper_windows")
        if ([string]::IsNullOrEmpty($this.Wrapper)) {
            $this.Wrapper = $config.GetValue("profiles.$key.wrapper")
        }

        $this.AltMarkers       = $config.GetArray("profiles.$key.alt_markers")
        $this.Targets          = $config.GetArray("profiles.$key.targets")
        $this.OptionalTargets  = $config.GetArray("profiles.$key.optional_targets")
        $this.RecursiveTargets = $config.GetArray("profiles.$key.recursive_targets")
        $this.SourceExtensions = $config.GetArray("profiles.$key.source_extensions")
        $this.SearchExclude    = $config.GetArray("profiles.$key.search_exclude")
    }

    [string[]] AllMarkers() {
        return @($this.Marker) + $this.AltMarkers
    }
}

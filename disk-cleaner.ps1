<#
.SYNOPSIS
    Multi-language project workspace tool.

.DESCRIPTION
    Configurable tool that uses profiles.toml to define language profiles.
    Supports multiple commands: clean (remove build artifacts) and search (find projects).
    Extensible without script changes — just add profiles to the TOML config.

.PARAMETER Command
    Subcommand to run: clean, search, list-profiles, help.
    Defaults to "clean" for backward compatibility.

.PARAMETER Lang
    Language profile(s) to target. Repeatable. Use "all" for everything.

.PARAMETER Config
    Path to TOML config file. Defaults to main/config/profiles.toml next to script.

.PARAMETER ListProfiles
    Show available profiles and exit (shortcut for "list-profiles" command).

.PARAMETER Exclude
    Array of patterns to exclude from results.

.PARAMETER Include
    Array of patterns to include in results.

.PARAMETER DryRun
    (clean only) Show what would be cleaned without actually cleaning.

.PARAMETER Path
    Root path to search for projects.

.PARAMETER Parallel
    (clean only) Run clean operations in parallel.

.PARAMETER All
    Process all projects, ignoring Exclude/Include filters.

.PARAMETER JsonOutput
    Emit structured JSON lines (one per event) instead of colored text.

.PARAMETER Help
    Show usage information and exit.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" clean -Lang rust
    Clean Rust projects.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" search -Lang all -Path "C:\projects"
    Find all projects across all languages.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" search -Lang rust -JsonOutput
    Find Rust projects with JSON output.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang rust
    Clean Rust projects (backward compatible — clean is the default command).
#>

param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter()]
    [string[]]$Lang = @(),

    [Parameter()]
    [string]$Config,

    [Parameter()]
    [switch]$ListProfiles,

    [Parameter()]
    [string[]]$Exclude = @(),

    [Parameter()]
    [string[]]$Include = @(),

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [string]$Path,

    [Parameter()]
    [switch]$Parallel,

    [Parameter()]
    [switch]$All,

    [Parameter()]
    [switch]$JsonOutput,

    [Parameter()]
    [string]$Text,

    [Parameter()]
    [switch]$History,

    [Parameter()]
    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = "Continue"

# ─── Script Directory ────────────────────────────────────────────────────────────

if ($PSScriptRoot) {
    $ScriptDir = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $ScriptDir = Get-Location
}

# ─── Source Shared Libraries ─────────────────────────────────────────────────────
# Order matters: classes must be defined before dependent classes

. (Join-Path $ScriptDir "main\src\lib\TomlConfig.ps1")
. (Join-Path $ScriptDir "main\src\lib\Spinner.ps1")
. (Join-Path $ScriptDir "main\src\lib\OutputWriter.ps1")
. (Join-Path $ScriptDir "main\src\lib\CleanProfile.ps1")
. (Join-Path $ScriptDir "main\src\lib\CleanerContext.ps1")

# ─── Source Features ─────────────────────────────────────────────────────────────

. (Join-Path $ScriptDir "main\features\clean\clean.ps1")
. (Join-Path $ScriptDir "main\features\search\search.ps1")
. (Join-Path $ScriptDir "main\features\analyze\analyze.ps1")
. (Join-Path $ScriptDir "main\features\monitor\monitor.ps1")

# ─── Help ────────────────────────────────────────────────────────────────────────

function Show-Usage {
    $usage = @"
disk-cleaner - Multi-language project workspace tool

USAGE:
    disk-cleaner.ps1 <command> [OPTIONS]

COMMANDS:
    clean             Remove build artifacts from detected projects (default)
    search            Find and report projects without modifying them
    analyze           Report disk space consumption by build artifacts
    monitor           Show build process resources and run history
    list-profiles     Show available language profiles
    help              Show this help message

OPTIONS (shared):
    -Lang <profile>       Language profile to target (repeatable, or "all")
    -Config <file>        Path to TOML config (default: main/config/profiles.toml)
    -Exclude <pattern>    Exclude projects matching pattern (can specify multiple)
    -Include <pattern>    Only include projects matching pattern (can specify multiple)
    -Path <path>          Root path to search (defaults to config default or script dir)
    -All                  Process all projects, ignoring Exclude/Include filters
    -JsonOutput           Emit structured JSON lines instead of colored text
    -Help, -h             Show this help message

OPTIONS (clean only):
    -DryRun               Show what would be cleaned without cleaning
    -Parallel             Run clean operations in parallel

OPTIONS (monitor only):
    -History              Show run history (past cleans/analyses)

Press Ctrl+C at any time to cancel instantly. A partial summary is printed on exit.

EXAMPLES:
    disk-cleaner.ps1 clean -Lang rust
    disk-cleaner.ps1 clean -Lang rust, node -DryRun
    disk-cleaner.ps1 search -Lang all -Path "C:\projects"
    disk-cleaner.ps1 search -Lang rust -JsonOutput
    disk-cleaner.ps1 analyze -Lang rust -Path "C:\projects" # space report
    disk-cleaner.ps1 monitor                              # process resources + history
    disk-cleaner.ps1 monitor -History                     # history only
    disk-cleaner.ps1 -Lang rust                           # clean is default
    disk-cleaner.ps1 list-profiles

"@
    Write-Host $usage
    exit 0
}

if ($Help) { Show-Usage }

# ─── Resolve Command ────────────────────────────────────────────────────────────

# Handle -ListProfiles switch as shortcut
if ($ListProfiles) {
    $Command = "list-profiles"
}

# Default command is "clean" for backward compatibility
if (-not $Command -or $Command -notin @("clean", "search", "analyze", "monitor", "list-profiles", "help")) {
    # If Command looks like a profile name (not a known command), treat as Lang for backward compat
    if ($Command -and $Command -notin @("clean", "search", "analyze", "monitor", "list-profiles", "help")) {
        $Lang = @($Command) + $Lang
    }
    $Command = "clean"
}

if ($Command -eq "help") { Show-Usage }

# ─── Load Config ─────────────────────────────────────────────────────────────────

if (-not $Config) {
    $Config = Join-Path $ScriptDir "main\config\profiles.toml"
    # Fallback to legacy location
    if (-not (Test-Path $Config)) {
        $Config = Join-Path $ScriptDir "disk-cleaner.toml"
    }
}

try {
    $toml = [TomlConfig]::new($Config)
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# ─── List Profiles ───────────────────────────────────────────────────────────────

if ($Command -eq "list-profiles") {
    Write-Host "Available profiles (from $Config):" -ForegroundColor Cyan
    Write-Host ""
    foreach ($profileKey in $toml.Profiles) {
        $p = [CleanProfile]::new($profileKey, $toml)
        Write-Host "  $profileKey" -ForegroundColor White -NoNewline
        Write-Host " - $($p.Name)"
        Write-Host "    marker: $($p.Marker)  |  type: $($p.Type)" -ForegroundColor DarkGray
    }
    Write-Host ""
    exit 0
}

# ─── Resolve Profiles (skip for monitor) ─────────────────────────────────────

$resolvedProfiles = @()
if ($Command -ne "monitor") {
    if ($Lang.Count -eq 0) {
        $Lang = $toml.GetArray("settings.default_profiles")
    }

    foreach ($lp in $Lang) {
        if ($lp -eq "all") {
            $resolvedProfiles = $toml.Profiles
            break
        } else {
            $pName = $toml.GetValue("profiles.$lp.name")
            if ([string]::IsNullOrEmpty($pName)) {
                Write-Host "Unknown profile: $lp" -ForegroundColor Red
                Write-Host "Use list-profiles or -ListProfiles to see available profiles"
                exit 1
            }
            $resolvedProfiles += $lp
        }
    }

    if ($resolvedProfiles.Count -eq 0) {
        Write-Host "No profiles selected. Use -Lang or set default_profiles in config." -ForegroundColor Red
        exit 1
    }
}

# ─── Resolve Search Path ────────────────────────────────────────────────────────

if (-not $Path) {
    $defaultPath = $toml.GetValue("settings.default_path")
    if ($defaultPath -and $defaultPath.Length -gt 0) {
        $Path = $defaultPath
    } else {
        $Path = $ScriptDir
    }
}

# ─── Create Context ─────────────────────────────────────────────────────────────

$script:ctx = [CleanerContext]::new($Path, $Exclude, $Include, [bool]$All, [bool]$DryRun, [bool]$Parallel, [bool]$JsonOutput, $Text)

# ─── Cancel Support ──────────────────────────────────────────────────────────────

$script:cancelHandler = [System.ConsoleCancelEventHandler]{
    param($sender, $e)
    $e.Cancel = $true
    $script:ctx.Cancelled = $true
}
[Console]::add_CancelKeyPress($script:cancelHandler)

Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    try { [Console]::remove_CancelKeyPress($script:cancelHandler) } catch {}
} | Out-Null

# ─── Dispatch Command ───────────────────────────────────────────────────────────

$configDir = Join-Path $ScriptDir "main\config"

switch ($Command) {
    "clean" {
        Invoke-Clean -Ctx $script:ctx -ProfileKeys $resolvedProfiles -Toml $toml
        if (-not $script:ctx.Cancelled -and -not $DryRun) {
            Save-RunHistory -ConfigDir $configDir -Command "clean" `
                -Profiles ($resolvedProfiles -join ", ") `
                -Projects $script:ctx.TotalCleaned `
                -SizeBytes $script:ctx.TotalSizeBytes `
                -Path $Path
        }
    }
    "search" {
        Invoke-Search -Ctx $script:ctx -ProfileKeys $resolvedProfiles -Toml $toml
    }
    "analyze" {
        Invoke-Analyze -Ctx $script:ctx -ProfileKeys $resolvedProfiles -Toml $toml
        if (-not $script:ctx.Cancelled) {
            Save-RunHistory -ConfigDir $configDir -Command "analyze" `
                -Profiles ($resolvedProfiles -join ", ") `
                -Projects $script:ctx.TotalCleaned `
                -SizeBytes $script:ctx.TotalSizeBytes `
                -Path $Path
        }
    }
    "monitor" {
        Invoke-Monitor -Ctx $script:ctx -ConfigDir $configDir -ShowHistory ([bool]$History)
    }
}

# ─── Handle Cancellation ────────────────────────────────────────────────────────

if ($script:ctx.Cancelled) {
    $script:ctx.Spinner.Stop()
    Write-Host ""
    $w = $script:ctx.Writer
    $w.Json(@{ event = "cancelled" })
    if (-not $w.JsonMode) {
        Write-Host "Cancelled by user." -ForegroundColor Yellow
        if ($script:ctx.TotalCleaned -gt 0 -or $script:ctx.TotalSizeBytes -gt 0) {
            Write-Host "  Progress so far: $($script:ctx.TotalCleaned) projects, $([CleanerContext]::FormatSize($script:ctx.TotalSizeBytes))" -ForegroundColor DarkGray
        }
    }
    Write-Progress -Id 1 -Activity " " -Completed
    try { [Console]::remove_CancelKeyPress($script:cancelHandler) } catch {}
    exit 130
}

# Cleanup cancel handler
try { [Console]::remove_CancelKeyPress($script:cancelHandler) } catch {}

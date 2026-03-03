<#
.SYNOPSIS
    Multi-language project cleaner.

.DESCRIPTION
    Configurable cleaning tool that uses disk-cleaner.toml to define language profiles.
    Supports Rust, Node.js, Java (Maven/Gradle), Python, and more.
    Extensible without script changes — just add profiles to the TOML config.

.PARAMETER Lang
    Language profile(s) to clean. Repeatable. Use "all" for everything.

.PARAMETER Config
    Path to TOML config file. Defaults to disk-cleaner.toml next to script.

.PARAMETER ListProfiles
    Show available profiles and exit.

.PARAMETER Exclude
    Array of patterns to exclude from cleaning.

.PARAMETER Include
    Array of patterns to include for cleaning.

.PARAMETER DryRun
    Show what would be cleaned without actually cleaning.

.PARAMETER Path
    Root path to search for projects.

.PARAMETER Parallel
    Run clean operations in parallel.

.PARAMETER All
    Clean all projects, ignoring Exclude/Include filters.

.PARAMETER Help
    Show usage information and exit.

.EXAMPLE
    .\disk-cleaner.ps1 -Lang rust
    Clean Rust projects.

.EXAMPLE
    .\disk-cleaner.ps1 -Lang rust, node -DryRun
    Dry run Rust and Node.js projects.

.EXAMPLE
    .\disk-cleaner.ps1 -Lang all -DryRun -Path C:\projects
    Dry run all languages in C:\projects.

.EXAMPLE
    .\disk-cleaner.ps1 -ListProfiles
    Show available profiles.
#>

param(
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
    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = "Continue"

# ─── Script Directory & Config ───────────────────────────────────────────────────

if ($PSScriptRoot) {
    $ScriptDir = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $ScriptDir = Get-Location
}

if (-not $Config) {
    $Config = Join-Path $ScriptDir "disk-cleaner.toml"
}

# ─── TOML Parser ─────────────────────────────────────────────────────────────────

function Read-Toml {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) {
        Write-Host "Config file not found: $FilePath" -ForegroundColor Red
        exit 1
    }

    $data = @{}
    $profiles = [System.Collections.ArrayList]::new()
    $currentSection = ""

    foreach ($rawLine in Get-Content $FilePath) {
        # Strip comments and trim
        $line = ($rawLine -replace '#.*$', '').Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Section header
        if ($line -match '^\[(.+)\]$') {
            $currentSection = $Matches[1]
            if ($currentSection -match '^profiles\.(.+)$') {
                [void]$profiles.Add($Matches[1])
            }
            continue
        }

        # Key = value
        if ($line -match '^([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(.+)$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()

            $fullKey = "$currentSection.$key"
            $data[$fullKey] = $value
        }
    }

    return @{ Data = $data; Profiles = $profiles }
}

function Get-TomlValue {
    param([hashtable]$Data, [string]$Key)
    $raw = $Data[$Key]
    if ($null -eq $raw) { return "" }

    # Strip quotes from simple strings
    if ($raw -match '^"(.*)"$') { return $Matches[1] }
    if ($raw -match "^'(.*)'$") { return $Matches[1] }
    return $raw
}

function Get-TomlArray {
    param([hashtable]$Data, [string]$Key)
    $raw = $Data[$Key]
    if ($null -eq $raw) { return @() }

    # Strip brackets
    $raw = $raw -replace '^\[', '' -replace '\]$', ''
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    $items = $raw -split ','
    $result = @()
    foreach ($item in $items) {
        $item = $item.Trim().Trim('"').Trim("'")
        if ($item.Length -gt 0) {
            $result += $item
        }
    }
    return $result
}

# ─── Help ─────────────────────────────────────────────────────────────────────────

function Show-Usage {
    $usage = @"
disk-cleaner.ps1 - Multi-language project cleaner

USAGE:
    .\disk-cleaner.ps1 [OPTIONS]

OPTIONS:
    -Lang <profile>       Language profile to clean (repeatable, or "all")
    -Config <file>        Path to TOML config (default: disk-cleaner.toml next to script)
    -ListProfiles         Show available profiles and exit
    -Exclude <pattern>    Exclude projects matching pattern (can specify multiple)
    -Include <pattern>    Only include projects matching pattern (can specify multiple)
    -DryRun               Show what would be cleaned without cleaning
    -Path <path>          Root path to search (defaults to config default or script dir)
    -Parallel             Run clean operations in parallel
    -All                  Clean all projects, ignoring Exclude/Include filters
    -Help, -h             Show this help message

EXAMPLES:
    .\disk-cleaner.ps1 -Lang rust                              # Clean Rust projects
    .\disk-cleaner.ps1 -Lang rust, node -DryRun                # Dry run Rust + Node
    .\disk-cleaner.ps1 -Lang all -DryRun -Path C:\projects     # Dry run all languages
    .\disk-cleaner.ps1 -Lang node -Exclude myapp               # Node except myapp
    .\disk-cleaner.ps1 -ListProfiles                           # List profiles

"@
    Write-Host $usage
    exit 0
}

if ($Help) { Show-Usage }

# ─── Load Config ──────────────────────────────────────────────────────────────────

$toml = Read-Toml -FilePath $Config
$tomlData = $toml.Data
$tomlProfiles = $toml.Profiles

# ─── List Profiles ────────────────────────────────────────────────────────────────

if ($ListProfiles) {
    Write-Host "Available profiles (from $Config):" -ForegroundColor Cyan
    Write-Host ""
    foreach ($profile in $tomlProfiles) {
        $pName = Get-TomlValue -Data $tomlData -Key "profiles.$profile.name"
        $pMarker = Get-TomlValue -Data $tomlData -Key "profiles.$profile.marker"
        $pType = Get-TomlValue -Data $tomlData -Key "profiles.$profile.type"
        Write-Host "  $profile" -ForegroundColor White -NoNewline
        Write-Host " - $pName"
        Write-Host "    marker: $pMarker  |  type: $pType" -ForegroundColor DarkGray
    }
    Write-Host ""
    exit 0
}

# ─── Resolve Profiles ────────────────────────────────────────────────────────────

if ($Lang.Count -eq 0) {
    $Lang = Get-TomlArray -Data $tomlData -Key "settings.default_profiles"
}

$resolvedProfiles = @()
foreach ($lp in $Lang) {
    if ($lp -eq "all") {
        $resolvedProfiles = $tomlProfiles
        break
    } else {
        $pName = Get-TomlValue -Data $tomlData -Key "profiles.$lp.name"
        if ([string]::IsNullOrEmpty($pName)) {
            Write-Host "Unknown profile: $lp" -ForegroundColor Red
            Write-Host "Use -ListProfiles to see available profiles"
            exit 1
        }
        $resolvedProfiles += $lp
    }
}

if ($resolvedProfiles.Count -eq 0) {
    Write-Host "No profiles selected. Use -Lang or set default_profiles in config." -ForegroundColor Red
    exit 1
}

# ─── Resolve Search Path ─────────────────────────────────────────────────────────

if (-not $Path) {
    $defaultPath = Get-TomlValue -Data $tomlData -Key "settings.default_path"
    if ($defaultPath -and $defaultPath.Length -gt 0) {
        $Path = $defaultPath
    } else {
        $Path = $ScriptDir
    }
}

# ─── Utility Functions ───────────────────────────────────────────────────────────

function Get-RelativePath {
    param([string]$FullPath)
    if ($Path -and $Path.Length -gt 0) {
        return $FullPath.Replace($Path, "").TrimStart("\", "/")
    }
    return $FullPath
}

function Test-ShouldClean {
    param([string]$ProjectPath)

    if ($All) { return $true }

    $relativePath = Get-RelativePath -FullPath $ProjectPath

    foreach ($pattern in $Exclude) {
        if ($relativePath -like "*$pattern*") {
            return $false
        }
    }

    if ($Include.Count -gt 0) {
        foreach ($pattern in $Include) {
            if ($relativePath -like "*$pattern*") {
                return $true
            }
        }
        return $false
    }

    return $true
}

function Get-DirSizeFormatted {
    param([string]$DirPath)
    if (Test-Path $DirPath) {
        try {
            $size = (Get-ChildItem -Path $DirPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($null -eq $size) { $size = 0 }
            if ($size -ge 1GB) { return "$([math]::Round($size / 1GB, 2)) GiB" }
            if ($size -ge 1MB) { return "$([math]::Round($size / 1MB, 2)) MiB" }
            if ($size -ge 1KB) { return "$([math]::Round($size / 1KB, 2)) KiB" }
            return "$size B"
        } catch {
            return "unknown size"
        }
    }
    return "0 B"
}

# ─── Per-Profile Cleaning ────────────────────────────────────────────────────────

$grandTotalProjects = 0
$grandTotalCleaned = 0
$grandTotalSkipped = 0
$grandTotalRemovedFiles = 0
$grandTotalSizeMiB = 0

function Invoke-CleanProfile {
    param([string]$Profile)

    $pName = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.name"
    $pMarker = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.marker"
    $pType = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.type"
    $pCommand = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.command"
    $pOutputPattern = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.output_pattern"
    $pWrapper = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.wrapper_windows"
    if ([string]::IsNullOrEmpty($pWrapper)) {
        $pWrapper = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.wrapper"
    }

    $pAltMarkers = Get-TomlArray -Data $tomlData -Key "profiles.$Profile.alt_markers"
    $pTargets = Get-TomlArray -Data $tomlData -Key "profiles.$Profile.targets"
    $pOptionalTargets = Get-TomlArray -Data $tomlData -Key "profiles.$Profile.optional_targets"
    $pRecursiveTargets = Get-TomlArray -Data $tomlData -Key "profiles.$Profile.recursive_targets"

    Write-Host ""
    Write-Host "--- $pName ---" -ForegroundColor Cyan
    Write-Host "Scanning for $pName projects in: $Path" -ForegroundColor Cyan

    if ($All) {
        Write-Host "Mode: ALL (ignoring Exclude/Include filters)" -ForegroundColor Magenta
    }

    # Find projects by marker files
    $allMarkers = @($pMarker) + $pAltMarkers
    $foundDirs = [System.Collections.ArrayList]::new()

    foreach ($marker in $allMarkers) {
        $files = Get-ChildItem -Path $Path -Recurse -Filter $marker -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $dir = $f.DirectoryName
            if (-not $foundDirs.Contains($dir)) {
                [void]$foundDirs.Add($dir)
            }
        }
    }

    $foundDirs = $foundDirs | Sort-Object

    # Apply include/exclude filters
    $toClean = @()
    $skipped = @()

    foreach ($dir in $foundDirs) {
        if (Test-ShouldClean -ProjectPath $dir) {
            $toClean += $dir
        } else {
            $skipped += $dir
        }
    }

    Write-Host ""
    Write-Host "Found $($foundDirs.Count) $pName projects" -ForegroundColor Cyan
    Write-Host "  To clean: $($toClean.Count)" -ForegroundColor Green
    Write-Host "  Skipped:  $($skipped.Count)" -ForegroundColor Yellow

    $script:grandTotalProjects += $foundDirs.Count
    $script:grandTotalCleaned += $toClean.Count
    $script:grandTotalSkipped += $skipped.Count

    # Show skipped
    if ($skipped.Count -gt 0 -and -not $All -and ($Exclude.Count -gt 0 -or $Include.Count -gt 0)) {
        Write-Host ""
        Write-Host "Skipped projects:" -ForegroundColor Yellow
        foreach ($s in $skipped) {
            $rel = Get-RelativePath -FullPath $s
            Write-Host "  - $rel" -ForegroundColor DarkYellow
        }
    }

    # Nothing to clean
    if ($toClean.Count -eq 0) { return }

    # Dry run
    if ($DryRun) {
        Write-Host ""
        Write-Host "[DRY RUN] Would clean:" -ForegroundColor Magenta
        foreach ($dir in $toClean) {
            $rel = Get-RelativePath -FullPath $dir
            Write-Host "  - $rel" -ForegroundColor White
            if ($pType -eq "remove") {
                foreach ($t in $pTargets) {
                    $tp = Join-Path $dir $t
                    if (Test-Path $tp) {
                        $sz = Get-DirSizeFormatted -DirPath $tp
                        Write-Host "    remove: $t ($sz)" -ForegroundColor DarkGray
                    }
                }
                foreach ($t in $pOptionalTargets) {
                    $tp = Join-Path $dir $t
                    if (Test-Path $tp) {
                        $sz = Get-DirSizeFormatted -DirPath $tp
                        Write-Host "    remove: $t ($sz)" -ForegroundColor DarkGray
                    }
                }
                foreach ($t in $pRecursiveTargets) {
                    $count = (Get-ChildItem -Path $dir -Recurse -Directory -Filter $t -ErrorAction SilentlyContinue).Count
                    if ($count -gt 0) {
                        Write-Host "    remove recursive: $t ($count found)" -ForegroundColor DarkGray
                    }
                }
            } elseif ($pType -eq "command") {
                $cmd = $pCommand
                if ($pWrapper -and (Test-Path (Join-Path $dir $pWrapper))) {
                    $cmd = "$pWrapper clean"
                }
                Write-Host "    would run: $cmd" -ForegroundColor DarkGray
            }
        }
        return
    }

    Write-Host ""
    Write-Host "Cleaning $pName projects..." -ForegroundColor Cyan
    Write-Host ""

    if ($Parallel -and $toClean.Count -gt 1 -and $pType -eq "command") {
        $jobs = @()
        foreach ($dir in $toClean) {
            $jobs += Start-Job -ScriptBlock {
                param($d, $cmd, $wrapper)
                Set-Location $d
                if ($wrapper -and (Test-Path $wrapper)) {
                    $cmd = "$wrapper clean"
                }
                $result = Invoke-Expression $cmd 2>&1 | Out-String
                return @{ Dir = $d; Result = $result.Trim() }
            } -ArgumentList $dir, $pCommand, $pWrapper
        }

        $results = $jobs | Wait-Job | Receive-Job
        $jobs | Remove-Job

        foreach ($r in $results) {
            $rel = Get-RelativePath -FullPath $r.Dir
            Write-Host "Cleaned: $rel" -ForegroundColor Green
            if ($r.Result) {
                Write-Host "  $($r.Result)" -ForegroundColor DarkGray
            }
        }
    } else {
        foreach ($dir in $toClean) {
            $rel = Get-RelativePath -FullPath $dir

            if ($pType -eq "command") {
                Write-Host "Cleaning: $rel" -ForegroundColor White -NoNewline

                Push-Location $dir
                $cmd = $pCommand
                if ($pWrapper -and (Test-Path $pWrapper)) {
                    $cmd = "$pWrapper clean"
                }
                $result = Invoke-Expression $cmd 2>&1 | Out-String
                Pop-Location

                if ($result -match "Removed (\d+) files") {
                    $files = [int]$Matches[1]
                    $script:grandTotalRemovedFiles += $files
                    if ($result -match "([\d.]+)\s*(GiB|MiB|KiB)") {
                        $size = [double]$Matches[1]
                        $unit = $Matches[2]
                        switch ($unit) {
                            "GiB" { $script:grandTotalSizeMiB += $size * 1024 }
                            "MiB" { $script:grandTotalSizeMiB += $size }
                            "KiB" { $script:grandTotalSizeMiB += $size / 1024 }
                        }
                    }
                    Write-Host " - $($result.Trim())" -ForegroundColor DarkGray
                } elseif ($result -match "error:") {
                    Write-Host " - Error" -ForegroundColor Red
                    Write-Host "  $($result.Trim())" -ForegroundColor DarkRed
                } else {
                    Write-Host " - Done" -ForegroundColor DarkGray
                }

            } elseif ($pType -eq "remove") {
                Write-Host "Cleaning: $rel" -ForegroundColor White

                foreach ($t in $pTargets) {
                    $tp = Join-Path $dir $t
                    if (Test-Path $tp) {
                        $sz = Get-DirSizeFormatted -DirPath $tp
                        Remove-Item -Path $tp -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Host "  removed: $t ($sz)" -ForegroundColor DarkGray
                    }
                }

                foreach ($t in $pOptionalTargets) {
                    $tp = Join-Path $dir $t
                    if (Test-Path $tp) {
                        $sz = Get-DirSizeFormatted -DirPath $tp
                        Remove-Item -Path $tp -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Host "  removed: $t ($sz)" -ForegroundColor DarkGray
                    }
                }

                foreach ($t in $pRecursiveTargets) {
                    $count = 0
                    $dirs = Get-ChildItem -Path $dir -Recurse -Directory -Filter $t -ErrorAction SilentlyContinue
                    foreach ($rd in $dirs) {
                        Remove-Item -Path $rd.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        $count++
                    }
                    if ($count -gt 0) {
                        Write-Host "  removed recursive: $t ($count directories)" -ForegroundColor DarkGray
                    }
                }
            }
        }
    }
}

# ─── Main Execution ──────────────────────────────────────────────────────────────

Write-Host "disk-cleaner - Multi-language project cleaner" -ForegroundColor Cyan
Write-Host "Config: $Config" -ForegroundColor DarkGray
Write-Host "Profiles: $($resolvedProfiles -join ', ')" -ForegroundColor DarkGray

foreach ($profile in $resolvedProfiles) {
    Invoke-CleanProfile -Profile $profile
}

# ─── Grand Summary ────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 50) -ForegroundColor Cyan
Write-Host "Cleaning complete!" -ForegroundColor Green
Write-Host "  Profiles run:       $($resolvedProfiles.Count) ($($resolvedProfiles -join ', '))" -ForegroundColor White
Write-Host "  Projects found:     $grandTotalProjects" -ForegroundColor White
Write-Host "  Projects cleaned:   $grandTotalCleaned" -ForegroundColor White
Write-Host "  Projects skipped:   $grandTotalSkipped" -ForegroundColor White

if ($grandTotalRemovedFiles -gt 0) {
    Write-Host "  Total files removed: $grandTotalRemovedFiles" -ForegroundColor White
}

if ($grandTotalSizeMiB -gt 0) {
    if ($grandTotalSizeMiB -ge 1024) {
        Write-Host "  Total space freed:  $([math]::Round($grandTotalSizeMiB / 1024, 2)) GiB" -ForegroundColor White
    } else {
        Write-Host "  Total space freed:  $([math]::Round($grandTotalSizeMiB, 2)) MiB" -ForegroundColor White
    }
}

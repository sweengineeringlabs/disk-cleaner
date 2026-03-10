<#
.SYNOPSIS
    Multi-language project cleaner.

.DESCRIPTION
    Configurable cleaning tool that uses disk-cleaner.toml to define language profiles.
    Supports Rust, Node.js, Java (Maven/Gradle), Python, and more.
    Extensible without script changes — just add profiles to the TOML config.
    Shows a progress indicator while scanning. Press Ctrl+C to cancel gracefully.

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

.PARAMETER JsonOutput
    Emit structured JSON lines (one per event) instead of colored text.

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

.EXAMPLE
    .\disk-cleaner.ps1 -Lang all -JsonOutput -Path C:\projects
    Clean all languages and emit JSON events.
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
    [switch]$JsonOutput,

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
    -JsonOutput           Emit structured JSON lines instead of colored text
    -Help, -h             Show this help message

Press Ctrl+C at any time to cancel. A partial summary is printed on exit.

EXAMPLES:
    .\disk-cleaner.ps1 -Lang rust                              # Clean Rust projects
    .\disk-cleaner.ps1 -Lang rust, node -DryRun                # Dry run Rust + Node
    .\disk-cleaner.ps1 -Lang all -DryRun -Path C:\projects     # Dry run all languages
    .\disk-cleaner.ps1 -Lang node -Exclude myapp               # Node except myapp
    .\disk-cleaner.ps1 -Lang all -JsonOutput                   # JSON event stream
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

function Get-DirSizeBytes {
    param([string]$DirPath)
    if (Test-Path $DirPath) {
        try {
            $size = (Get-ChildItem -Path $DirPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($null -eq $size) { return [long]0 }
            return [long]$size
        } catch {
            return [long]0
        }
    }
    return [long]0
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "$([math]::Round($Bytes / 1GB, 2)) GiB" }
    if ($Bytes -ge 1MB) { return "$([math]::Round($Bytes / 1MB, 2)) MiB" }
    if ($Bytes -ge 1KB) { return "$([math]::Round($Bytes / 1KB, 2)) KiB" }
    return "$Bytes B"
}

function Get-DirSizeFormatted {
    param([string]$DirPath)
    return Format-Size -Bytes (Get-DirSizeBytes -DirPath $DirPath)
}

# ─── JSON Output ─────────────────────────────────────────────────────────────────

function Write-JsonEvent {
    param([hashtable]$Event)
    $Event["timestamp"] = (Get-Date -Format "o")
    $json = $Event | ConvertTo-Json -Compress
    Write-Output $json
}

# ─── Per-Profile Cleaning ────────────────────────────────────────────────────────

# ─── Spinner ──────────────────────────────────────────────────────────────────────

function Start-Spinner {
    param([string]$Message)
    if ($JsonOutput) { return }
    Write-Progress -Id 2 -Activity $Message -Status "Please wait..."
}

function Stop-Spinner {
    Write-Progress -Id 2 -Activity " " -Completed
}

# ─── Cancel Support ───────────────────────────────────────────────────────────────

$script:cancelled = $false

trap {
    $script:cancelled = $true
    Stop-Spinner
    Write-Host ""
    if ($JsonOutput) {
        Write-JsonEvent @{ event = "cancelled" }
    } else {
        Write-Host "Cancelled by user." -ForegroundColor Yellow
        if ($grandTotalCleaned -gt 0 -or $grandTotalSizeBytes -gt 0) {
            Write-Host "  Cleaned so far: $grandTotalCleaned projects, $(Format-Size -Bytes $grandTotalSizeBytes) freed" -ForegroundColor DarkGray
        }
    }
    Write-Progress -Id 0 -Activity "disk-cleaner" -Completed
    Write-Progress -Id 1 -Activity " " -Completed
    break
}

# ─── Per-Profile Cleaning ────────────────────────────────────────────────────────

$grandTotalProjects = 0
$grandTotalCleaned = 0
$grandTotalSkipped = 0
$grandTotalSizeBytes = [long]0

function Invoke-CleanProfile {
    param([string]$Profile, [int]$ProfileIndex, [int]$ProfileCount)

    $pName = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.name"
    $pMarker = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.marker"
    $pType = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.type"
    $pCommand = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.command"
    $pOutputPattern = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.output_pattern"
    $pCleanDir = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.clean_dir"
    $pWrapper = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.wrapper_windows"
    if ([string]::IsNullOrEmpty($pWrapper)) {
        $pWrapper = Get-TomlValue -Data $tomlData -Key "profiles.$Profile.wrapper"
    }

    $pAltMarkers = Get-TomlArray -Data $tomlData -Key "profiles.$Profile.alt_markers"
    $pTargets = Get-TomlArray -Data $tomlData -Key "profiles.$Profile.targets"
    $pOptionalTargets = Get-TomlArray -Data $tomlData -Key "profiles.$Profile.optional_targets"
    $pRecursiveTargets = Get-TomlArray -Data $tomlData -Key "profiles.$Profile.recursive_targets"

    if ($JsonOutput) {
        Write-JsonEvent @{ event = "scan_start"; profile = $Profile; name = $pName; path = $Path }
    } else {
        Write-Host ""
        Write-Host "--- $pName [$ProfileIndex/$ProfileCount] ---" -ForegroundColor Cyan
        Write-Host "Scanning for $pName projects in: $Path" -ForegroundColor Cyan

        if ($All) {
            Write-Host "Mode: ALL (ignoring Exclude/Include filters)" -ForegroundColor Magenta
        }
    }

    # Update overall progress
    Write-Progress -Id 0 -Activity "disk-cleaner" `
        -Status "Profile $ProfileIndex/$ProfileCount : $pName" `
        -PercentComplete (($ProfileIndex - 1) / $ProfileCount * 100)

    # Find projects by marker files
    $allMarkers = @($pMarker) + $pAltMarkers
    $foundDirs = [System.Collections.ArrayList]::new()

    Start-Spinner -Message "Scanning for $pName projects..."

    foreach ($marker in $allMarkers) {
        if ($script:cancelled) { Stop-Spinner; return }
        $files = Get-ChildItem -Path $Path -Recurse -Filter $marker -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $dir = $f.DirectoryName
            if (-not $foundDirs.Contains($dir)) {
                [void]$foundDirs.Add($dir)
            }
        }
    }

    Stop-Spinner

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

    if ($JsonOutput) {
        Write-JsonEvent @{ event = "scan_complete"; profile = $Profile; found = $foundDirs.Count; to_clean = $toClean.Count; skipped = $skipped.Count }
    } else {
        Write-Host ""
        Write-Host "Found $($foundDirs.Count) $pName projects" -ForegroundColor Cyan
        Write-Host "  To clean: $($toClean.Count)" -ForegroundColor Green
        Write-Host "  Skipped:  $($skipped.Count)" -ForegroundColor Yellow
    }

    $script:grandTotalProjects += $foundDirs.Count
    $script:grandTotalCleaned += $toClean.Count
    $script:grandTotalSkipped += $skipped.Count

    # Show skipped
    if (-not $JsonOutput -and $skipped.Count -gt 0 -and -not $All -and ($Exclude.Count -gt 0 -or $Include.Count -gt 0)) {
        Write-Host ""
        Write-Host "Skipped projects:" -ForegroundColor Yellow
        foreach ($s in $skipped) {
            $rel = Get-RelativePath -FullPath $s
            Write-Host "  - $rel" -ForegroundColor DarkYellow
        }
    }

    # Nothing to clean
    if ($toClean.Count -eq 0) { return }
    if ($script:cancelled) { return }

    # Dry run
    if ($DryRun) {
        if ($JsonOutput) {
            foreach ($dir in $toClean) {
                $rel = Get-RelativePath -FullPath $dir
                $dryInfo = @{ event = "dry_run"; profile = $Profile; project = $rel }
                if ($pType -eq "remove") {
                    $targets = @()
                    foreach ($t in ($pTargets + $pOptionalTargets)) {
                        $tp = Join-Path $dir $t
                        if (Test-Path $tp) {
                            $sz = Get-DirSizeBytes -DirPath $tp
                            $targets += @{ name = $t; size_bytes = $sz }
                        }
                    }
                    $dryInfo["targets"] = $targets
                } elseif ($pType -eq "command") {
                    $cmd = $pCommand
                    if ($pWrapper -and (Test-Path (Join-Path $dir $pWrapper))) { $cmd = "$pWrapper clean" }
                    $dryInfo["command"] = $cmd
                    if ($pCleanDir) {
                        $cdp = Join-Path $dir $pCleanDir
                        if (Test-Path $cdp) {
                            $dryInfo["estimated_size_bytes"] = (Get-DirSizeBytes -DirPath $cdp)
                        }
                    }
                }
                Write-JsonEvent $dryInfo
            }
        } else {
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
                    if ($pCleanDir) {
                        $cdp = Join-Path $dir $pCleanDir
                        if (Test-Path $cdp) {
                            $sz = Get-DirSizeFormatted -DirPath $cdp
                            Write-Host "    $pCleanDir/ size: $sz" -ForegroundColor DarkGray
                        }
                    }
                }
            }
        }
        return
    }

    if (-not $JsonOutput) {
        Write-Host ""
        Write-Host "Cleaning $pName projects..." -ForegroundColor Cyan
        Write-Host ""
    }

    $profileSizeBytes = [long]0
    $projectIndex = 0

    if ($Parallel -and $toClean.Count -gt 1 -and $pType -eq "command") {
        # Measure sizes before parallel clean
        $preSizes = @{}
        if ($pCleanDir) {
            foreach ($dir in $toClean) {
                $cdp = Join-Path $dir $pCleanDir
                if (Test-Path $cdp) {
                    $preSizes[$dir] = Get-DirSizeBytes -DirPath $cdp
                } else {
                    $preSizes[$dir] = [long]0
                }
            }
        }

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

        # Poll jobs for progress
        $completedCount = 0
        while ($completedCount -lt $jobs.Count) {
            $doneJobs = $jobs | Where-Object { $_.State -eq "Completed" -or $_.State -eq "Failed" }
            $newCompleted = $doneJobs.Count
            if ($newCompleted -gt $completedCount) {
                $completedCount = $newCompleted
                $pct = [math]::Min(100, [int]($completedCount / $toClean.Count * 100))
                Write-Progress -Id 1 -ParentId 0 -Activity "$pName" `
                    -Status "$completedCount/$($toClean.Count) projects" `
                    -PercentComplete $pct
            }
            if ($completedCount -lt $jobs.Count) {
                Start-Sleep -Milliseconds 200
            }
        }

        $results = $jobs | Wait-Job | Receive-Job
        $jobs | Remove-Job

        foreach ($r in $results) {
            $rel = Get-RelativePath -FullPath $r.Dir
            $sizeFreed = $preSizes[$r.Dir]
            if ($null -eq $sizeFreed) { $sizeFreed = [long]0 }
            $profileSizeBytes += $sizeFreed

            if ($JsonOutput) {
                Write-JsonEvent @{
                    event = "clean_complete"; profile = $Profile; project = $rel
                    size_bytes = $sizeFreed; cumulative_bytes = $profileSizeBytes
                }
            } else {
                $szFmt = Format-Size -Bytes $sizeFreed
                $cumFmt = Format-Size -Bytes $profileSizeBytes
                Write-Host "Cleaned: $rel" -ForegroundColor Green -NoNewline
                Write-Host " | freed: $szFmt | total: $cumFmt" -ForegroundColor DarkGray
            }
        }

        Write-Progress -Id 1 -ParentId 0 -Activity "$pName" -Completed
    } else {
        foreach ($dir in $toClean) {
            if ($script:cancelled) { break }
            $projectIndex++
            $rel = Get-RelativePath -FullPath $dir
            $pct = [math]::Min(100, [int]($projectIndex / $toClean.Count * 100))

            Write-Progress -Id 1 -ParentId 0 -Activity "$pName" `
                -Status "[$projectIndex/$($toClean.Count)] $rel" `
                -PercentComplete $pct

            if ($pType -eq "command") {
                # Measure build dir size before cleaning
                $sizeFreed = [long]0
                if ($pCleanDir) {
                    $cdp = Join-Path $dir $pCleanDir
                    if (Test-Path $cdp) {
                        $sizeFreed = Get-DirSizeBytes -DirPath $cdp
                    }
                }

                if (-not $JsonOutput) {
                    Write-Host "[$projectIndex/$($toClean.Count)] " -ForegroundColor DarkGray -NoNewline
                    Write-Host "Cleaning: $rel" -ForegroundColor White -NoNewline
                }

                Push-Location $dir
                $cmd = $pCommand
                if ($pWrapper -and (Test-Path $pWrapper)) {
                    $cmd = "$pWrapper clean"
                }
                $result = Invoke-Expression $cmd 2>&1 | Out-String
                Pop-Location

                $profileSizeBytes += $sizeFreed

                if ($JsonOutput) {
                    $evt = @{
                        event = "clean_complete"; profile = $Profile; project = $rel
                        size_bytes = $sizeFreed; cumulative_bytes = $profileSizeBytes
                    }
                    if ($result -match "error:") { $evt["error"] = $result.Trim() }
                    Write-JsonEvent $evt
                } else {
                    $szFmt = Format-Size -Bytes $sizeFreed
                    $cumFmt = Format-Size -Bytes $profileSizeBytes
                    if ($result -match "error:") {
                        Write-Host " - Error" -ForegroundColor Red
                        Write-Host "  $($result.Trim())" -ForegroundColor DarkRed
                    } else {
                        Write-Host " | freed: $szFmt | total: $cumFmt" -ForegroundColor DarkGray
                    }
                }

            } elseif ($pType -eq "remove") {
                if (-not $JsonOutput) {
                    Write-Host "[$projectIndex/$($toClean.Count)] " -ForegroundColor DarkGray -NoNewline
                    Write-Host "Cleaning: $rel" -ForegroundColor White
                }

                $projectSizeBytes = [long]0

                foreach ($t in $pTargets) {
                    $tp = Join-Path $dir $t
                    if (Test-Path $tp) {
                        $sz = Get-DirSizeBytes -DirPath $tp
                        $projectSizeBytes += $sz
                        Remove-Item -Path $tp -Recurse -Force -ErrorAction SilentlyContinue
                        if (-not $JsonOutput) {
                            Write-Host "  removed: $t ($(Format-Size -Bytes $sz))" -ForegroundColor DarkGray
                        }
                    }
                }

                foreach ($t in $pOptionalTargets) {
                    $tp = Join-Path $dir $t
                    if (Test-Path $tp) {
                        $sz = Get-DirSizeBytes -DirPath $tp
                        $projectSizeBytes += $sz
                        Remove-Item -Path $tp -Recurse -Force -ErrorAction SilentlyContinue
                        if (-not $JsonOutput) {
                            Write-Host "  removed: $t ($(Format-Size -Bytes $sz))" -ForegroundColor DarkGray
                        }
                    }
                }

                foreach ($t in $pRecursiveTargets) {
                    $count = 0
                    $dirs = Get-ChildItem -Path $dir -Recurse -Directory -Filter $t -ErrorAction SilentlyContinue
                    foreach ($rd in $dirs) {
                        $sz = Get-DirSizeBytes -DirPath $rd.FullName
                        $projectSizeBytes += $sz
                        Remove-Item -Path $rd.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        $count++
                    }
                    if ($count -gt 0 -and -not $JsonOutput) {
                        Write-Host "  removed recursive: $t ($count directories)" -ForegroundColor DarkGray
                    }
                }

                $profileSizeBytes += $projectSizeBytes

                if ($JsonOutput) {
                    Write-JsonEvent @{
                        event = "clean_complete"; profile = $Profile; project = $rel
                        size_bytes = $projectSizeBytes; cumulative_bytes = $profileSizeBytes
                    }
                } else {
                    $cumFmt = Format-Size -Bytes $profileSizeBytes
                    Write-Host "  project freed: $(Format-Size -Bytes $projectSizeBytes) | profile total: $cumFmt" -ForegroundColor Cyan
                }
            }
        }

        Write-Progress -Id 1 -ParentId 0 -Activity "$pName" -Completed
    }

    $script:grandTotalSizeBytes += $profileSizeBytes

    if ($JsonOutput) {
        Write-JsonEvent @{
            event = "profile_complete"; profile = $Profile; name = $pName
            cleaned = $toClean.Count; freed_bytes = $profileSizeBytes
            cumulative_total_bytes = $script:grandTotalSizeBytes
        }
    } else {
        Write-Host ""
        Write-Host "$pName complete: $(Format-Size -Bytes $profileSizeBytes) freed" -ForegroundColor Green
    }
}

# ─── Main Execution ──────────────────────────────────────────────────────────────

if ($JsonOutput) {
    Write-JsonEvent @{
        event = "start"; config = $Config
        profiles = @($resolvedProfiles); path = $Path
        dry_run = [bool]$DryRun; parallel = [bool]$Parallel
    }
} else {
    Write-Host "disk-cleaner - Multi-language project cleaner" -ForegroundColor Cyan
    Write-Host "Config: $Config" -ForegroundColor DarkGray
    Write-Host "Profiles: $($resolvedProfiles -join ', ')" -ForegroundColor DarkGray
}

$profileIdx = 0
foreach ($profile in $resolvedProfiles) {
    if ($script:cancelled) { break }
    $profileIdx++
    Invoke-CleanProfile -Profile $profile -ProfileIndex $profileIdx -ProfileCount $resolvedProfiles.Count
}

Write-Progress -Id 0 -Activity "disk-cleaner" -Completed

# ─── Grand Summary ────────────────────────────────────────────────────────────────

if ($JsonOutput) {
    Write-JsonEvent @{
        event = "summary"
        profiles_run = $resolvedProfiles.Count
        profile_names = @($resolvedProfiles)
        projects_found = $grandTotalProjects
        projects_cleaned = $grandTotalCleaned
        projects_skipped = $grandTotalSkipped
        total_freed_bytes = $grandTotalSizeBytes
        total_freed_formatted = (Format-Size -Bytes $grandTotalSizeBytes)
    }
} else {
    Write-Host ""
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "Cleaning complete!" -ForegroundColor Green
    Write-Host "  Profiles run:       $($resolvedProfiles.Count) ($($resolvedProfiles -join ', '))" -ForegroundColor White
    Write-Host "  Projects found:     $grandTotalProjects" -ForegroundColor White
    Write-Host "  Projects cleaned:   $grandTotalCleaned" -ForegroundColor White
    Write-Host "  Projects skipped:   $grandTotalSkipped" -ForegroundColor White
    Write-Host "  Total space freed:  $(Format-Size -Bytes $grandTotalSizeBytes)" -ForegroundColor Green
}

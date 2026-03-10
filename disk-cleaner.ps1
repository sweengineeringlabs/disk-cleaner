<#
.SYNOPSIS
    Multi-language project cleaner.

.DESCRIPTION
    Configurable cleaning tool that uses disk-cleaner.toml to define language profiles.
    Supports Rust, Node.js, Java (Maven/Gradle), Python, and more.
    Extensible without script changes — just add profiles to the TOML config.
    Shows an animated text spinner while scanning. Press Ctrl+C to cancel instantly,
    even during a scan. A partial summary is printed on cancellation.

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
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang rust
    Clean Rust projects.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang rust, node -DryRun
    Dry run Rust and Node.js projects.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang all -DryRun -Path "C:\projects"
    Dry run all languages in C:\projects.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -ListProfiles
    Show available profiles.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang all -JsonOutput -Path "C:\projects"
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

# ─── Classes ─────────────────────────────────────────────────────────────────────

class TomlConfig {
    [hashtable] $Data
    [string[]]  $Profiles

    TomlConfig([string]$filePath) {
        if (-not (Test-Path $filePath)) {
            throw "Config file not found: $filePath"
        }

        $this.Data = @{}
        $profileList = [System.Collections.ArrayList]::new()
        $currentSection = ""

        foreach ($rawLine in Get-Content $filePath) {
            $line = ($rawLine -replace '#.*$', '').Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            if ($line -match '^\[(.+)\]$') {
                $currentSection = $Matches[1]
                if ($currentSection -match '^profiles\.(.+)$') {
                    [void]$profileList.Add($Matches[1])
                }
                continue
            }

            if ($line -match '^([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(.+)$') {
                $key = $Matches[1]
                $value = $Matches[2].Trim()
                $this.Data["$currentSection.$key"] = $value
            }
        }

        $this.Profiles = @($profileList)
    }

    [string] GetValue([string]$key) {
        $raw = $this.Data[$key]
        if ($null -eq $raw) { return "" }
        if ($raw -match '^"(.*)"$') { return $Matches[1] }
        if ($raw -match "^'(.*)'$") { return $Matches[1] }
        return $raw
    }

    [string[]] GetArray([string]$key) {
        $raw = $this.Data[$key]
        if ($null -eq $raw) { return @() }

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
}

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
    }

    [string[]] AllMarkers() {
        return @($this.Marker) + $this.AltMarkers
    }
}

class Spinner {
    hidden [powershell] $PS
    hidden [runspace]   $Runspace
    [bool] $Suppressed

    Spinner([bool]$suppressed) {
        $this.Suppressed = $suppressed
    }

    [void] Start([string]$message) {
        if ($this.Suppressed) { return }

        $this.Runspace = [runspacefactory]::CreateRunspace()
        $this.Runspace.Open()

        $this.PS = [powershell]::Create()
        $this.PS.Runspace = $this.Runspace
        [void]$this.PS.AddScript({
            param($msg)
            $chars = @('|', '/', '-', '\')
            $i = 0
            try {
                while ($true) {
                    $c = $chars[$i % 4]
                    [Console]::Write("`r  $c $msg  ")
                    $i++
                    Start-Sleep -Milliseconds 120
                }
            } catch {}
        })
        [void]$this.PS.AddArgument($message)
        [void]$this.PS.BeginInvoke()
    }

    [void] Stop() {
        if ($this.PS) {
            try { $this.PS.Stop() } catch {}
            try { $this.PS.Dispose() } catch {}
            $this.PS = $null
        }
        if ($this.Runspace) {
            try { $this.Runspace.Close() } catch {}
            try { $this.Runspace.Dispose() } catch {}
            $this.Runspace = $null
        }
        if (-not $this.Suppressed) {
            [Console]::Write("`r" + (" " * 80) + "`r")
        }
    }
}

class OutputWriter {
    [bool] $JsonMode

    OutputWriter([bool]$jsonMode) {
        $this.JsonMode = $jsonMode
    }

    [void] Text([string]$message, [string]$color) {
        if ($this.JsonMode) { return }
        Write-Host $message -ForegroundColor $color
    }

    [void] TextNoNewline([string]$message, [string]$color) {
        if ($this.JsonMode) { return }
        Write-Host $message -ForegroundColor $color -NoNewline
    }

    [void] PlainText([string]$message) {
        if ($this.JsonMode) { return }
        Write-Host $message
    }

    [void] BlankLine() {
        if ($this.JsonMode) { return }
        Write-Host ""
    }

    [void] Json([hashtable]$event) {
        if (-not $this.JsonMode) { return }
        $event["timestamp"] = (Get-Date -Format "o")
        $json = $event | ConvertTo-Json -Compress
        [Console]::Out.WriteLine($json)
    }
}

class CleanerContext {
    [string]       $SearchPath
    [string[]]     $ExcludePatterns
    [string[]]     $IncludePatterns
    [bool]         $CleanAll
    [bool]         $DryRun
    [bool]         $Parallel
    [bool]         $Cancelled
    [Spinner]      $Spinner
    [OutputWriter] $Writer

    # Grand totals
    [int]  $TotalProjects
    [int]  $TotalCleaned
    [int]  $TotalSkipped
    [long] $TotalSizeBytes

    CleanerContext([string]$searchPath, [string[]]$exclude, [string[]]$include,
                   [bool]$all, [bool]$dryRun, [bool]$parallel, [bool]$jsonOutput) {
        $this.SearchPath      = $searchPath
        $this.ExcludePatterns = $exclude
        $this.IncludePatterns = $include
        $this.CleanAll        = $all
        $this.DryRun          = $dryRun
        $this.Parallel        = $parallel
        $this.Cancelled       = $false
        $this.Spinner         = [Spinner]::new($jsonOutput)
        $this.Writer          = [OutputWriter]::new($jsonOutput)
        $this.TotalProjects   = 0
        $this.TotalCleaned    = 0
        $this.TotalSkipped    = 0
        $this.TotalSizeBytes  = [long]0
    }

    [string] RelativePath([string]$fullPath) {
        if ($this.SearchPath -and $this.SearchPath.Length -gt 0) {
            return $fullPath.Replace($this.SearchPath, "").TrimStart("\", "/")
        }
        return $fullPath
    }

    [bool] ShouldClean([string]$projectPath) {
        if ($this.CleanAll) { return $true }

        $rel = $this.RelativePath($projectPath)

        foreach ($pattern in $this.ExcludePatterns) {
            if ($rel -like "*$pattern*") { return $false }
        }

        if ($this.IncludePatterns.Count -gt 0) {
            foreach ($pattern in $this.IncludePatterns) {
                if ($rel -like "*$pattern*") { return $true }
            }
            return $false
        }

        return $true
    }

    static [long] DirSizeBytes([string]$dirPath) {
        if (Test-Path $dirPath) {
            try {
                $size = (Get-ChildItem -Path $dirPath -Recurse -File -ErrorAction SilentlyContinue |
                         Measure-Object -Property Length -Sum).Sum
                if ($null -eq $size) { return [long]0 }
                return [long]$size
            } catch {
                return [long]0
            }
        }
        return [long]0
    }

    static [string] FormatSize([long]$bytes) {
        if ($bytes -ge 1GB) { return "$([math]::Round($bytes / 1GB, 2)) GiB" }
        if ($bytes -ge 1MB) { return "$([math]::Round($bytes / 1MB, 2)) MiB" }
        if ($bytes -ge 1KB) { return "$([math]::Round($bytes / 1KB, 2)) KiB" }
        return "$bytes B"
    }
}

class ProfileCleaner {
    [CleanProfile]  $Profile
    [CleanerContext] $Ctx
    hidden [long]    $ProfileSizeBytes

    ProfileCleaner([CleanProfile]$profile, [CleanerContext]$ctx) {
        $this.Profile          = $profile
        $this.Ctx              = $ctx
        $this.ProfileSizeBytes = [long]0
    }

    [void] Run([int]$profileIndex, [int]$profileCount) {
        $p = $this.Profile
        $w = $this.Ctx.Writer

        # Announce scan
        $w.Json(@{ event = "scan_start"; profile = $p.Key; name = $p.Name; path = $this.Ctx.SearchPath })
        $w.BlankLine()
        $w.Text("--- $($p.Name) [$profileIndex/$profileCount] ---", "Cyan")
        $w.Text("Scanning for $($p.Name) projects in: $($this.Ctx.SearchPath)", "Cyan")
        if ($this.Ctx.CleanAll) {
            $w.Text("Mode: ALL (ignoring Exclude/Include filters)", "Magenta")
        }

        Write-Progress -Id 0 -Activity "disk-cleaner" `
            -Status "Profile $profileIndex/$profileCount : $($p.Name)" `
            -PercentComplete (($profileIndex - 1) / $profileCount * 100)

        # Scan
        $foundDirs = $this.ScanForProjects()

        $foundDirs = $foundDirs | Sort-Object

        # Filter
        $toClean = @()
        $skipped = @()
        foreach ($dir in $foundDirs) {
            if ($this.Ctx.ShouldClean($dir)) {
                $toClean += $dir
            } else {
                $skipped += $dir
            }
        }

        # Report scan results
        $w.Json(@{ event = "scan_complete"; profile = $p.Key; found = $foundDirs.Count; to_clean = $toClean.Count; skipped = $skipped.Count })
        $w.BlankLine()
        $w.Text("Found $($foundDirs.Count) $($p.Name) projects", "Cyan")
        $w.Text("  To clean: $($toClean.Count)", "Green")
        $w.Text("  Skipped:  $($skipped.Count)", "Yellow")

        $this.Ctx.TotalProjects += $foundDirs.Count
        $this.Ctx.TotalCleaned  += $toClean.Count
        $this.Ctx.TotalSkipped  += $skipped.Count

        # Show skipped details
        if (-not $w.JsonMode -and $skipped.Count -gt 0 -and -not $this.Ctx.CleanAll -and
            ($this.Ctx.ExcludePatterns.Count -gt 0 -or $this.Ctx.IncludePatterns.Count -gt 0)) {
            $w.BlankLine()
            $w.Text("Skipped projects:", "Yellow")
            foreach ($s in $skipped) {
                $rel = $this.Ctx.RelativePath($s)
                $w.Text("  - $rel", "DarkYellow")
            }
        }

        if ($toClean.Count -eq 0) { return }
        if ($this.Ctx.Cancelled) { return }

        # Dry run
        if ($this.Ctx.DryRun) {
            $this.RunDryRun($toClean)
            return
        }

        $w.BlankLine()
        $w.Text("Cleaning $($p.Name) projects...", "Cyan")
        $w.BlankLine()

        # Clean
        if ($this.Ctx.Parallel -and $toClean.Count -gt 1 -and $p.Type -eq "command") {
            $this.RunParallelCommandClean($toClean)
        } else {
            $this.RunSequentialClean($toClean)
        }

        $this.Ctx.TotalSizeBytes += $this.ProfileSizeBytes

        $w.Json(@{
            event = "profile_complete"; profile = $p.Key; name = $p.Name
            cleaned = $toClean.Count; freed_bytes = $this.ProfileSizeBytes
            cumulative_total_bytes = $this.Ctx.TotalSizeBytes
        })
        $w.BlankLine()
        $w.Text("$($p.Name) complete: $([CleanerContext]::FormatSize($this.ProfileSizeBytes)) freed", "Green")
    }

    hidden [System.Collections.ArrayList] ScanForProjects() {
        $foundDirs = [System.Collections.ArrayList]::new()

        $this.Ctx.Spinner.Start("Scanning for $($this.Profile.Name) projects...")

        foreach ($marker in $this.Profile.AllMarkers()) {
            if ($this.Ctx.Cancelled) { $this.Ctx.Spinner.Stop(); return $foundDirs }
            try {
                $enumerator = [System.IO.Directory]::EnumerateFiles(
                    $this.Ctx.SearchPath, $marker, [System.IO.SearchOption]::AllDirectories
                ).GetEnumerator()
                try {
                    while ($enumerator.MoveNext()) {
                        if ($this.Ctx.Cancelled) { break }
                        $dir = [System.IO.Path]::GetDirectoryName($enumerator.Current)
                        if (-not $foundDirs.Contains($dir)) {
                            [void]$foundDirs.Add($dir)
                        }
                    }
                } finally {
                    $enumerator.Dispose()
                }
            } catch [System.IO.DirectoryNotFoundException] {
            } catch [System.UnauthorizedAccessException] {
            }
            if ($this.Ctx.Cancelled) { break }
        }

        $this.Ctx.Spinner.Stop()
        return $foundDirs
    }

    hidden [void] RunDryRun([string[]]$toClean) {
        $p = $this.Profile
        $w = $this.Ctx.Writer

        if ($w.JsonMode) {
            foreach ($dir in $toClean) {
                $rel = $this.Ctx.RelativePath($dir)
                $dryInfo = @{ event = "dry_run"; profile = $p.Key; project = $rel }
                if ($p.Type -eq "remove") {
                    $targets = @()
                    foreach ($t in ($p.Targets + $p.OptionalTargets)) {
                        $tp = Join-Path $dir $t
                        if (Test-Path $tp) {
                            $sz = [CleanerContext]::DirSizeBytes($tp)
                            $targets += @{ name = $t; size_bytes = $sz }
                        }
                    }
                    $dryInfo["targets"] = $targets
                } elseif ($p.Type -eq "command") {
                    $cmd = $p.Command
                    if ($p.Wrapper -and (Test-Path (Join-Path $dir $p.Wrapper))) { $cmd = "$($p.Wrapper) clean" }
                    $dryInfo["command"] = $cmd
                    if ($p.CleanDir) {
                        $cdp = Join-Path $dir $p.CleanDir
                        if (Test-Path $cdp) {
                            $dryInfo["estimated_size_bytes"] = [CleanerContext]::DirSizeBytes($cdp)
                        }
                    }
                }
                $w.Json($dryInfo)
            }
        } else {
            $w.BlankLine()
            $w.Text("[DRY RUN] Would clean:", "Magenta")
            foreach ($dir in $toClean) {
                $rel = $this.Ctx.RelativePath($dir)
                $w.Text("  - $rel", "White")
                if ($p.Type -eq "remove") {
                    foreach ($t in $p.Targets) {
                        $tp = Join-Path $dir $t
                        if (Test-Path $tp) {
                            $sz = [CleanerContext]::FormatSize([CleanerContext]::DirSizeBytes($tp))
                            $w.Text("    remove: $t ($sz)", "DarkGray")
                        }
                    }
                    foreach ($t in $p.OptionalTargets) {
                        $tp = Join-Path $dir $t
                        if (Test-Path $tp) {
                            $sz = [CleanerContext]::FormatSize([CleanerContext]::DirSizeBytes($tp))
                            $w.Text("    remove: $t ($sz)", "DarkGray")
                        }
                    }
                    foreach ($t in $p.RecursiveTargets) {
                        $count = (Get-ChildItem -Path $dir -Recurse -Directory -Filter $t -ErrorAction SilentlyContinue).Count
                        if ($count -gt 0) {
                            $w.Text("    remove recursive: $t ($count found)", "DarkGray")
                        }
                    }
                } elseif ($p.Type -eq "command") {
                    $cmd = $p.Command
                    if ($p.Wrapper -and (Test-Path (Join-Path $dir $p.Wrapper))) {
                        $cmd = "$($p.Wrapper) clean"
                    }
                    $w.Text("    would run: $cmd", "DarkGray")
                    if ($p.CleanDir) {
                        $cdp = Join-Path $dir $p.CleanDir
                        if (Test-Path $cdp) {
                            $sz = [CleanerContext]::FormatSize([CleanerContext]::DirSizeBytes($cdp))
                            $w.Text("    $($p.CleanDir)/ size: $sz", "DarkGray")
                        }
                    }
                }
            }
        }
    }

    hidden [void] RunSequentialClean([string[]]$toClean) {
        $p = $this.Profile
        $w = $this.Ctx.Writer
        $projectIndex = 0

        foreach ($dir in $toClean) {
            if ($this.Ctx.Cancelled) { break }
            $projectIndex++
            $rel = $this.Ctx.RelativePath($dir)
            $pct = [math]::Min(100, [int]($projectIndex / $toClean.Count * 100))

            Write-Progress -Id 1 -ParentId 0 -Activity $p.Name `
                -Status "[$projectIndex/$($toClean.Count)] $rel" `
                -PercentComplete $pct

            if ($p.Type -eq "command") {
                $this.CleanCommandProject($dir, $rel, $projectIndex, $toClean.Count)
            } elseif ($p.Type -eq "remove") {
                $this.CleanRemoveProject($dir, $rel, $projectIndex, $toClean.Count)
            }
        }

        Write-Progress -Id 1 -ParentId 0 -Activity $p.Name -Completed
    }

    hidden [void] CleanCommandProject([string]$dir, [string]$rel, [int]$index, [int]$total) {
        $p = $this.Profile
        $w = $this.Ctx.Writer

        $sizeFreed = [long]0
        if ($p.CleanDir) {
            $cdp = Join-Path $dir $p.CleanDir
            if (Test-Path $cdp) {
                $sizeFreed = [CleanerContext]::DirSizeBytes($cdp)
            }
        }

        $w.TextNoNewline("[$index/$total] ", "DarkGray")
        $w.TextNoNewline("Cleaning: $rel", "White")

        Push-Location $dir
        $cmd = $p.Command
        if ($p.Wrapper -and (Test-Path $p.Wrapper)) {
            $cmd = "$($p.Wrapper) clean"
        }
        $result = Invoke-Expression $cmd 2>&1 | Out-String
        Pop-Location

        $this.ProfileSizeBytes += $sizeFreed

        $w.Json(@{
            event = "clean_complete"; profile = $p.Key; project = $rel
            size_bytes = $sizeFreed; cumulative_bytes = $this.ProfileSizeBytes
        })

        if (-not $w.JsonMode) {
            $szFmt = [CleanerContext]::FormatSize($sizeFreed)
            $cumFmt = [CleanerContext]::FormatSize($this.ProfileSizeBytes)
            if ($result -match "error:") {
                $w.Text(" - Error", "Red")
                $w.Text("  $($result.Trim())", "DarkRed")
            } else {
                $w.Text(" | freed: $szFmt | total: $cumFmt", "DarkGray")
            }
        } else {
            if ($result -match "error:") {
                # Re-emit with error field
                $w.Json(@{
                    event = "clean_error"; profile = $p.Key; project = $rel
                    error = $result.Trim()
                })
            }
        }
    }

    hidden [void] CleanRemoveProject([string]$dir, [string]$rel, [int]$index, [int]$total) {
        $p = $this.Profile
        $w = $this.Ctx.Writer

        $w.TextNoNewline("[$index/$total] ", "DarkGray")
        $w.Text("Cleaning: $rel", "White")

        $projectSizeBytes = [long]0

        foreach ($t in $p.Targets) {
            $tp = Join-Path $dir $t
            if (Test-Path $tp) {
                $sz = [CleanerContext]::DirSizeBytes($tp)
                $projectSizeBytes += $sz
                Remove-Item -Path $tp -Recurse -Force -ErrorAction SilentlyContinue
                $w.Text("  removed: $t ($([CleanerContext]::FormatSize($sz)))", "DarkGray")
            }
        }

        foreach ($t in $p.OptionalTargets) {
            $tp = Join-Path $dir $t
            if (Test-Path $tp) {
                $sz = [CleanerContext]::DirSizeBytes($tp)
                $projectSizeBytes += $sz
                Remove-Item -Path $tp -Recurse -Force -ErrorAction SilentlyContinue
                $w.Text("  removed: $t ($([CleanerContext]::FormatSize($sz)))", "DarkGray")
            }
        }

        foreach ($t in $p.RecursiveTargets) {
            $count = 0
            $dirs = Get-ChildItem -Path $dir -Recurse -Directory -Filter $t -ErrorAction SilentlyContinue
            foreach ($rd in $dirs) {
                $sz = [CleanerContext]::DirSizeBytes($rd.FullName)
                $projectSizeBytes += $sz
                Remove-Item -Path $rd.FullName -Recurse -Force -ErrorAction SilentlyContinue
                $count++
            }
            if ($count -gt 0) {
                $w.Text("  removed recursive: $t ($count directories)", "DarkGray")
            }
        }

        $this.ProfileSizeBytes += $projectSizeBytes

        $w.Json(@{
            event = "clean_complete"; profile = $p.Key; project = $rel
            size_bytes = $projectSizeBytes; cumulative_bytes = $this.ProfileSizeBytes
        })

        if (-not $w.JsonMode) {
            $cumFmt = [CleanerContext]::FormatSize($this.ProfileSizeBytes)
            $w.Text("  project freed: $([CleanerContext]::FormatSize($projectSizeBytes)) | profile total: $cumFmt", "Cyan")
        }
    }

    hidden [void] RunParallelCommandClean([string[]]$toClean) {
        $p = $this.Profile
        $w = $this.Ctx.Writer

        # Measure sizes before parallel clean
        $preSizes = @{}
        if ($p.CleanDir) {
            foreach ($dir in $toClean) {
                $cdp = Join-Path $dir $p.CleanDir
                if (Test-Path $cdp) {
                    $preSizes[$dir] = [CleanerContext]::DirSizeBytes($cdp)
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
            } -ArgumentList $dir, $p.Command, $p.Wrapper
        }

        # Poll jobs for progress
        $completedCount = 0
        while ($completedCount -lt $jobs.Count) {
            $doneJobs = $jobs | Where-Object { $_.State -eq "Completed" -or $_.State -eq "Failed" }
            $newCompleted = $doneJobs.Count
            if ($newCompleted -gt $completedCount) {
                $completedCount = $newCompleted
                $pct = [math]::Min(100, [int]($completedCount / $toClean.Count * 100))
                Write-Progress -Id 1 -ParentId 0 -Activity $p.Name `
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
            $rel = $this.Ctx.RelativePath($r.Dir)
            $sizeFreed = $preSizes[$r.Dir]
            if ($null -eq $sizeFreed) { $sizeFreed = [long]0 }
            $this.ProfileSizeBytes += $sizeFreed

            $w.Json(@{
                event = "clean_complete"; profile = $p.Key; project = $rel
                size_bytes = $sizeFreed; cumulative_bytes = $this.ProfileSizeBytes
            })

            if (-not $w.JsonMode) {
                $szFmt = [CleanerContext]::FormatSize($sizeFreed)
                $cumFmt = [CleanerContext]::FormatSize($this.ProfileSizeBytes)
                Write-Host "Cleaned: $rel" -ForegroundColor Green -NoNewline
                Write-Host " | freed: $szFmt | total: $cumFmt" -ForegroundColor DarkGray
            }
        }

        Write-Progress -Id 1 -ParentId 0 -Activity $p.Name -Completed
    }
}

# ─── Help ─────────────────────────────────────────────────────────────────────────

function Show-Usage {
    $usage = @"
disk-cleaner.ps1 - Multi-language project cleaner

USAGE:
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" [OPTIONS]

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

Press Ctrl+C at any time to cancel instantly (even mid-scan). A partial summary is printed on exit.

EXAMPLES:
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang rust
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang rust, node -DryRun
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang all -DryRun -Path "C:\projects"
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang node -Exclude myapp
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang all -JsonOutput
    powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -ListProfiles

"@
    Write-Host $usage
    exit 0
}

if ($Help) { Show-Usage }

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

# ─── Load Config ──────────────────────────────────────────────────────────────────

try {
    $toml = [TomlConfig]::new($Config)
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# ─── List Profiles ────────────────────────────────────────────────────────────────

if ($ListProfiles) {
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

# ─── Resolve Profiles ────────────────────────────────────────────────────────────

if ($Lang.Count -eq 0) {
    $Lang = $toml.GetArray("settings.default_profiles")
}

$resolvedProfiles = @()
foreach ($lp in $Lang) {
    if ($lp -eq "all") {
        $resolvedProfiles = $toml.Profiles
        break
    } else {
        $pName = $toml.GetValue("profiles.$lp.name")
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
    $defaultPath = $toml.GetValue("settings.default_path")
    if ($defaultPath -and $defaultPath.Length -gt 0) {
        $Path = $defaultPath
    } else {
        $Path = $ScriptDir
    }
}

# ─── Create Context ──────────────────────────────────────────────────────────────

$script:ctx = [CleanerContext]::new($Path, $Exclude, $Include, [bool]$All, [bool]$DryRun, [bool]$Parallel, [bool]$JsonOutput)

# ─── Cancel Support ───────────────────────────────────────────────────────────────

$script:cancelHandler = [System.ConsoleCancelEventHandler]{
    param($sender, $e)
    $e.Cancel = $true
    $script:ctx.Cancelled = $true
}
[Console]::add_CancelKeyPress($script:cancelHandler)

Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    try { [Console]::remove_CancelKeyPress($script:cancelHandler) } catch {}
} | Out-Null

# ─── Main Execution ──────────────────────────────────────────────────────────────

$w = $script:ctx.Writer

$w.Json(@{
    event = "start"; config = $Config
    profiles = @($resolvedProfiles); path = $Path
    dry_run = [bool]$DryRun; parallel = [bool]$Parallel
})
$w.Text("disk-cleaner - Multi-language project cleaner", "Cyan")
$w.Text("Config: $Config", "DarkGray")
$w.Text("Profiles: $($resolvedProfiles -join ', ')", "DarkGray")

$profileIdx = 0
foreach ($profileKey in $resolvedProfiles) {
    if ($script:ctx.Cancelled) { break }
    $profileIdx++
    $profile = [CleanProfile]::new($profileKey, $toml)
    $cleaner = [ProfileCleaner]::new($profile, $script:ctx)
    $cleaner.Run($profileIdx, $resolvedProfiles.Count)
}

Write-Progress -Id 0 -Activity "disk-cleaner" -Completed

# ─── Handle Cancellation ─────────────────────────────────────────────────────────

if ($script:ctx.Cancelled) {
    $script:ctx.Spinner.Stop()
    Write-Host ""
    $w.Json(@{ event = "cancelled" })
    if (-not $w.JsonMode) {
        Write-Host "Cancelled by user." -ForegroundColor Yellow
        if ($script:ctx.TotalCleaned -gt 0 -or $script:ctx.TotalSizeBytes -gt 0) {
            Write-Host "  Cleaned so far: $($script:ctx.TotalCleaned) projects, $([CleanerContext]::FormatSize($script:ctx.TotalSizeBytes)) freed" -ForegroundColor DarkGray
        }
    }
    Write-Progress -Id 1 -Activity " " -Completed
    try { [Console]::remove_CancelKeyPress($script:cancelHandler) } catch {}
    exit 130
}

# ─── Grand Summary ────────────────────────────────────────────────────────────────

$w.Json(@{
    event = "summary"
    profiles_run = $resolvedProfiles.Count
    profile_names = @($resolvedProfiles)
    projects_found = $script:ctx.TotalProjects
    projects_cleaned = $script:ctx.TotalCleaned
    projects_skipped = $script:ctx.TotalSkipped
    total_freed_bytes = $script:ctx.TotalSizeBytes
    total_freed_formatted = [CleanerContext]::FormatSize($script:ctx.TotalSizeBytes)
})

if (-not $w.JsonMode) {
    Write-Host ""
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "Cleaning complete!" -ForegroundColor Green
    Write-Host "  Profiles run:       $($resolvedProfiles.Count) ($($resolvedProfiles -join ', '))" -ForegroundColor White
    Write-Host "  Projects found:     $($script:ctx.TotalProjects)" -ForegroundColor White
    Write-Host "  Projects cleaned:   $($script:ctx.TotalCleaned)" -ForegroundColor White
    Write-Host "  Projects skipped:   $($script:ctx.TotalSkipped)" -ForegroundColor White
    Write-Host "  Total space freed:  $([CleanerContext]::FormatSize($script:ctx.TotalSizeBytes))" -ForegroundColor Green
}

# Cleanup cancel handler
try { [Console]::remove_CancelKeyPress($script:cancelHandler) } catch {}

# monitor.ps1 - Monitor feature: track build process resources and run history

# ─── History Storage ─────────────────────────────────────────────────────────────

class RunHistory {
    [string] $FilePath

    RunHistory([string]$configDir) {
        $this.FilePath = Join-Path $configDir "history.json"
    }

    [void] Record([hashtable]$entry) {
        $entry["timestamp"] = (Get-Date -Format "o")
        $entries = $this.Load()
        $entries += $entry

        # Keep last 100 entries
        if ($entries.Count -gt 100) {
            $entries = $entries[($entries.Count - 100)..($entries.Count - 1)]
        }

        $json = $entries | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($this.FilePath, $json)
    }

    [hashtable[]] Load() {
        if (-not (Test-Path $this.FilePath)) { return @() }
        try {
            $raw = Get-Content $this.FilePath -Raw
            if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
            $parsed = $raw | ConvertFrom-Json
            # ConvertFrom-Json returns PSCustomObject; convert to hashtable array
            $result = @()
            foreach ($obj in $parsed) {
                $ht = @{}
                foreach ($prop in $obj.PSObject.Properties) {
                    $ht[$prop.Name] = $prop.Value
                }
                $result += $ht
            }
            return $result
        } catch {
            return @()
        }
    }
}

# ─── Process Monitor ─────────────────────────────────────────────────────────────

class ProcessMonitor {
    [CleanerContext] $Ctx

    # Build-related process names to watch
    static [string[]] $BuildProcessNames = @(
        "cargo", "rustc", "rustup", "clippy-driver", "rust-analyzer",
        "node", "npm", "npx", "yarn", "pnpm", "bun", "deno", "tsc", "esbuild", "vite",
        "java", "javac", "mvn", "gradle", "gradlew", "kotlin",
        "python", "python3", "pip", "pip3", "pytest", "mypy", "ruff",
        "cc", "gcc", "g++", "clang", "clang++", "make", "cmake", "ninja",
        "dotnet", "msbuild",
        "go", "zig"
    )

    ProcessMonitor([CleanerContext]$ctx) {
        $this.Ctx = $ctx
    }

    [PSCustomObject[]] ScanProcesses() {
        $results = [System.Collections.ArrayList]::new()

        foreach ($procName in [ProcessMonitor]::BuildProcessNames) {
            try {
                $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
                foreach ($proc in $procs) {
                    $cpuPct = 0
                    try {
                        $cpuPct = [math]::Round($proc.CPU, 1)
                    } catch {}

                    $memBytes = [long]0
                    try {
                        $memBytes = $proc.WorkingSet64
                    } catch {}

                    # Try to determine which project this process belongs to
                    $projectPath = ""
                    try {
                        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue).CommandLine
                        if ($cmdLine -and $this.Ctx.SearchPath) {
                            # Look for the search path in the command line
                            $escapedPath = [regex]::Escape($this.Ctx.SearchPath)
                            if ($cmdLine -match "$escapedPath[\\/]([^\\/""]+)") {
                                $projectPath = $Matches[1]
                            }
                        }
                    } catch {}

                    [void]$results.Add([PSCustomObject]@{
                        PID = $proc.Id
                        Name = $proc.ProcessName
                        CpuSeconds = $cpuPct
                        MemoryBytes = $memBytes
                        Project = $projectPath
                    })
                }
            } catch {}
        }

        return @($results | Sort-Object -Property MemoryBytes -Descending)
    }

    [PSCustomObject] GetSystemMemory() {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($os) {
                return [PSCustomObject]@{
                    TotalBytes = [long]($os.TotalVisibleMemorySize * 1024)
                    FreeBytes = [long]($os.FreePhysicalMemory * 1024)
                    UsedBytes = [long](($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 1024)
                    UsedPercent = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize * 100, 1)
                }
            }
        } catch {}
        return [PSCustomObject]@{ TotalBytes = 0; FreeBytes = 0; UsedBytes = 0; UsedPercent = 0 }
    }
}

# ─── Invoke-Monitor ──────────────────────────────────────────────────────────────

function Invoke-Monitor {
    param(
        [CleanerContext] $Ctx,
        [string]         $ConfigDir,
        [bool]           $ShowHistory
    )

    $w = $Ctx.Writer
    $history = [RunHistory]::new($ConfigDir)
    $monitor = [ProcessMonitor]::new($Ctx)

    $w.Json(@{ event = "start"; command = "monitor"; path = $Ctx.SearchPath; show_history = $ShowHistory })
    $w.Text("disk-cleaner monitor - Resource & history report", "Cyan")
    $w.Text("Path: $($Ctx.SearchPath)", "DarkGray")

    # ─── System Memory ────────────────────────────────────────────────────────
    $sysMem = $monitor.GetSystemMemory()

    if ($sysMem.TotalBytes -gt 0) {
        $w.BlankLine()
        $w.Text("--- System Memory ---", "Cyan")
        $memColor = if ($sysMem.UsedPercent -ge 90) { "Red" } elseif ($sysMem.UsedPercent -ge 70) { "Yellow" } else { "Green" }
        $w.Text("  Total:  $([CleanerContext]::FormatSize($sysMem.TotalBytes))", "White")
        $w.Text("  Used:   $([CleanerContext]::FormatSize($sysMem.UsedBytes)) ($($sysMem.UsedPercent)%)", $memColor)
        $w.Text("  Free:   $([CleanerContext]::FormatSize($sysMem.FreeBytes))", "White")

        $w.Json(@{
            event = "system_memory"
            total_bytes = $sysMem.TotalBytes
            used_bytes = $sysMem.UsedBytes
            free_bytes = $sysMem.FreeBytes
            used_percent = $sysMem.UsedPercent
        })
    }

    # ─── Active Build Processes ───────────────────────────────────────────────
    $w.BlankLine()
    $w.Text("--- Active Build Processes ---", "Cyan")

    $processes = $monitor.ScanProcesses()

    if ($processes.Count -eq 0) {
        $w.Text("  No active build processes found.", "DarkGray")
        $w.Json(@{ event = "processes"; count = 0; processes = @() })
    } else {
        # Header
        if (-not $w.JsonMode) {
            $header = "  {0,-8} {1,-20} {2,12} {3,14} {4}" -f "PID", "Process", "CPU (sec)", "Memory", "Project"
            $w.Text($header, "DarkGray")
            $w.Text("  $("-" * 75)", "DarkGray")
        }

        $totalBuildMem = [long]0
        foreach ($p in $processes) {
            $totalBuildMem += $p.MemoryBytes
            $memStr = [CleanerContext]::FormatSize($p.MemoryBytes)
            $projStr = if ($p.Project) { $p.Project } else { "-" }

            $memColor = if ($p.MemoryBytes -ge 1GB) { "Red" } elseif ($p.MemoryBytes -ge 256MB) { "Yellow" } else { "White" }

            if (-not $w.JsonMode) {
                $line = "  {0,-8} {1,-20} {2,12} {3,14} {4}" -f $p.PID, $p.Name, $p.CpuSeconds, $memStr, $projStr
                $w.Text($line, $memColor)
            }
        }

        $w.BlankLine()
        $w.Text("  Total build process memory: $([CleanerContext]::FormatSize($totalBuildMem))", "White")

        $w.Json(@{
            event = "processes"
            count = $processes.Count
            total_memory_bytes = $totalBuildMem
            processes = @($processes | ForEach-Object {
                @{ pid = $_.PID; name = $_.Name; cpu_seconds = $_.CpuSeconds; memory_bytes = $_.MemoryBytes; project = $_.Project }
            })
        })

        # ─── High Resource Alerts ─────────────────────────────────────────────
        $alerts = @($processes | Where-Object { $_.MemoryBytes -ge 512MB })
        if ($alerts.Count -gt 0) {
            $w.BlankLine()
            $w.Text("--- High Resource Alerts ---", "Red")
            foreach ($a in $alerts) {
                $w.Text("  ! $($a.Name) (PID $($a.PID)) using $([CleanerContext]::FormatSize($a.MemoryBytes)) RAM", "Red")
            }
            $w.Json(@{
                event = "alerts"
                count = $alerts.Count
                alerts = @($alerts | ForEach-Object {
                    @{ pid = $_.PID; name = $_.Name; memory_bytes = $_.MemoryBytes; reason = "high_memory" }
                })
            })
        }
    }

    # ─── Run History ──────────────────────────────────────────────────────────
    $entries = $history.Load()

    if ($ShowHistory -or $entries.Count -gt 0) {
        $w.BlankLine()
        $w.Text("--- Run History ---", "Cyan")

        if ($entries.Count -eq 0) {
            $w.Text("  No history recorded yet. Run clean or analyze to build history.", "DarkGray")
        } else {
            # Show last 10
            $recent = if ($entries.Count -gt 10) { $entries[($entries.Count - 10)..($entries.Count - 1)] } else { $entries }

            if (-not $w.JsonMode) {
                $header = "  {0,-22} {1,-10} {2,-12} {3,10} {4,16}" -f "Date", "Command", "Profiles", "Projects", "Size"
                $w.Text($header, "DarkGray")
                $w.Text("  $("-" * 75)", "DarkGray")
            }

            foreach ($e in $recent) {
                $dateStr = ""
                try {
                    $dateStr = ([datetime]$e.timestamp).ToString("yyyy-MM-dd HH:mm")
                } catch {
                    $dateStr = $e.timestamp
                }
                $cmd = if ($e.command) { $e.command } else { "unknown" }
                $profiles = if ($e.profiles) { $e.profiles } else { "-" }
                $projects = if ($e.projects) { $e.projects } else { 0 }
                $sizeStr = if ($e.size_formatted) { $e.size_formatted } else { "-" }

                if (-not $w.JsonMode) {
                    $line = "  {0,-22} {1,-10} {2,-12} {3,10} {4,16}" -f $dateStr, $cmd, $profiles, $projects, $sizeStr
                    $w.Text($line, "White")
                }
            }

            # Trend analysis
            $cleans = @($entries | Where-Object { $_.command -eq "clean" -and $_.size_bytes })
            if ($cleans.Count -ge 2) {
                $first = [long]$cleans[0].size_bytes
                $last = [long]$cleans[-1].size_bytes
                if ($first -gt 0) {
                    $changePct = [math]::Round(($last - $first) / $first * 100, 1)
                    $arrow = if ($changePct -lt 0) { [char]0x2193 } else { [char]0x2191 } # ↓ or ↑
                    $trendColor = if ($changePct -le 0) { "Green" } else { "Yellow" }
                    $w.BlankLine()
                    $w.Text("  Trend: artifacts $arrow $([math]::Abs($changePct))% since first recorded clean", $trendColor)
                }
            }
        }

        $w.Json(@{
            event = "history"
            total_entries = $entries.Count
            entries = @($recent | ForEach-Object { $_ })
        })
    }

    # ─── Summary ──────────────────────────────────────────────────────────────
    $w.Json(@{
        event = "summary"; command = "monitor"
        system_memory_used_percent = $sysMem.UsedPercent
        build_processes = $processes.Count
        history_entries = $entries.Count
    })

    if (-not $w.JsonMode) {
        Write-Host ""
        Write-Host ("=" * 50) -ForegroundColor Cyan
        Write-Host "Monitor complete!" -ForegroundColor Green
        Write-Host "  System memory:      $($sysMem.UsedPercent)% used" -ForegroundColor White
        Write-Host "  Build processes:    $($processes.Count) active" -ForegroundColor White
        Write-Host "  History entries:    $($entries.Count) recorded" -ForegroundColor White
    }
}

# ─── Record helpers (called by clean/analyze after completion) ────────────────

function Save-RunHistory {
    param(
        [string]    $ConfigDir,
        [string]    $Command,
        [string]    $Profiles,
        [int]       $Projects,
        [long]      $SizeBytes,
        [string]    $Path
    )

    $history = [RunHistory]::new($ConfigDir)
    $history.Record(@{
        command = $Command
        profiles = $Profiles
        projects = $Projects
        size_bytes = $SizeBytes
        size_formatted = [CleanerContext]::FormatSize($SizeBytes)
        path = $Path
    })
}

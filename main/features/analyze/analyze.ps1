# analyze.ps1 - Analyze feature: reports disk space consumption by build artifacts

class ArtifactAnalyzer {
    [CleanProfile]   $Profile
    [CleanerContext]  $Ctx

    ArtifactAnalyzer([CleanProfile]$profile, [CleanerContext]$ctx) {
        $this.Profile = $profile
        $this.Ctx     = $ctx
    }

    [void] Run([int]$profileIndex, [int]$profileCount) {
        $p = $this.Profile
        $w = $this.Ctx.Writer

        $w.Json(@{ event = "scan_start"; profile = $p.Key; name = $p.Name; path = $this.Ctx.SearchPath })
        $w.BlankLine()
        $w.Text("--- $($p.Name) [$profileIndex/$profileCount] ---", "Cyan")
        $w.Text("Analyzing $($p.Name) projects in: $($this.Ctx.SearchPath)", "Cyan")

        Write-Progress -Id 0 -Activity "disk-cleaner analyze" `
            -Status "Profile $profileIndex/$profileCount : $($p.Name)" `
            -PercentComplete (($profileIndex - 1) / $profileCount * 100)

        # Scan and filter
        $foundDirs = $this.Ctx.ScanForProjects($p)
        $filtered = $this.Ctx.FilterProjects($foundDirs)
        $toAnalyze = $filtered.ToProcess
        $skipped = $filtered.Skipped

        $w.Json(@{ event = "scan_complete"; profile = $p.Key; found = $foundDirs.Count; matched = $toAnalyze.Count; skipped = $skipped.Count })

        $this.Ctx.TotalProjects += $foundDirs.Count
        $this.Ctx.TotalSkipped  += $skipped.Count

        if ($toAnalyze.Count -eq 0) {
            $w.BlankLine()
            $w.Text("No $($p.Name) projects found.", "DarkGray")
            return
        }

        # Analyze each project and collect results
        $projectResults = [System.Collections.ArrayList]::new()
        $projectIndex = 0

        foreach ($dir in $toAnalyze) {
            if ($this.Ctx.Cancelled) { break }
            $projectIndex++
            $rel = $this.Ctx.RelativePath($dir)

            $pct = [math]::Min(100, [int]($projectIndex / $toAnalyze.Count * 100))
            Write-Progress -Id 1 -ParentId 0 -Activity $p.Name `
                -Status "[$projectIndex/$($toAnalyze.Count)] $rel" `
                -PercentComplete $pct

            $result = $this.AnalyzeProject($dir, $rel)
            if ($result.TotalBytes -gt 0) {
                [void]$projectResults.Add($result)
            }
        }

        Write-Progress -Id 1 -ParentId 0 -Activity $p.Name -Completed

        # Sort by total size descending
        $sorted = @($projectResults | Sort-Object -Property TotalBytes -Descending)
        $profileTotal = [long]0
        foreach ($r in $sorted) { $profileTotal += $r.TotalBytes }
        $this.Ctx.TotalSizeBytes += $profileTotal
        $this.Ctx.TotalCleaned += $sorted.Count

        # Report
        $w.BlankLine()
        if ($sorted.Count -eq 0) {
            $w.Text("All $($toAnalyze.Count) $($p.Name) projects are clean (no artifacts).", "Green")
        } else {
            $w.Text("$($sorted.Count)/$($toAnalyze.Count) $($p.Name) projects have artifacts ($([CleanerContext]::FormatSize($profileTotal)) total)", "Yellow")
            $w.BlankLine()

            $rank = 0
            foreach ($r in $sorted) {
                $rank++
                $this.ReportProject($r, $rank, $profileTotal)
            }
        }

        # Show skipped
        if (-not $w.JsonMode -and $skipped.Count -gt 0 -and -not $this.Ctx.CleanAll -and
            ($this.Ctx.ExcludePatterns.Count -gt 0 -or $this.Ctx.IncludePatterns.Count -gt 0)) {
            $w.BlankLine()
            $w.Text("Skipped ($($skipped.Count)):", "Yellow")
            foreach ($s in $skipped) {
                $w.Text("  - $($this.Ctx.RelativePath($s))", "DarkYellow")
            }
        }
    }

    hidden [PSCustomObject] AnalyzeProject([string]$dir, [string]$rel) {
        $p = $this.Profile
        $w = $this.Ctx.Writer
        $breakdown = [System.Collections.ArrayList]::new()
        $totalBytes = [long]0

        if ($p.Type -eq "command" -and $p.CleanDir) {
            $artifactRoot = Join-Path $dir $p.CleanDir
            if (Test-Path $artifactRoot) {
                $rootSize = [CleanerContext]::DirSizeBytes($artifactRoot)
                $totalBytes = $rootSize

                # Drill into subdirectories for breakdown
                $subDirs = Get-ChildItem -Path $artifactRoot -Directory -ErrorAction SilentlyContinue
                $accountedFor = [long]0

                foreach ($sub in ($subDirs | Sort-Object Name)) {
                    $subSize = [CleanerContext]::DirSizeBytes($sub.FullName)
                    if ($subSize -gt 0) {
                        $subBreakdown = [System.Collections.ArrayList]::new()

                        # One level deeper for large dirs (e.g., target/debug/incremental, target/debug/deps)
                        if ($subSize -gt 100MB) {
                            $innerDirs = Get-ChildItem -Path $sub.FullName -Directory -ErrorAction SilentlyContinue
                            foreach ($inner in ($innerDirs | Sort-Object Name)) {
                                $innerSize = [CleanerContext]::DirSizeBytes($inner.FullName)
                                if ($innerSize -gt 1MB) {
                                    [void]$subBreakdown.Add([PSCustomObject]@{
                                        Name = $inner.Name
                                        SizeBytes = $innerSize
                                    })
                                }
                            }
                        }

                        [void]$breakdown.Add([PSCustomObject]@{
                            Name = "$($p.CleanDir)/$($sub.Name)"
                            SizeBytes = $subSize
                            Children = @($subBreakdown | Sort-Object -Property SizeBytes -Descending)
                        })
                        $accountedFor += $subSize
                    }
                }

                # Account for files directly in the artifact root
                $directFiles = $rootSize - $accountedFor
                if ($directFiles -gt 1MB) {
                    [void]$breakdown.Add([PSCustomObject]@{
                        Name = "$($p.CleanDir)/ (files)"
                        SizeBytes = $directFiles
                        Children = @()
                    })
                }
            }

            # Also check for orphaned artifact dirs in subdirectories
            $this.FindOrphanedArtifacts($dir, $p.CleanDir, $breakdown, [ref]$totalBytes)

        } elseif ($p.Type -eq "remove") {
            foreach ($t in $p.Targets) {
                $tp = Join-Path $dir $t
                if (Test-Path $tp) {
                    $sz = [CleanerContext]::DirSizeBytes($tp)
                    $totalBytes += $sz
                    [void]$breakdown.Add([PSCustomObject]@{
                        Name = $t
                        SizeBytes = $sz
                        Children = @()
                    })
                }
            }
            foreach ($t in $p.OptionalTargets) {
                $tp = Join-Path $dir $t
                if (Test-Path $tp) {
                    $sz = [CleanerContext]::DirSizeBytes($tp)
                    $totalBytes += $sz
                    [void]$breakdown.Add([PSCustomObject]@{
                        Name = $t
                        SizeBytes = $sz
                        Children = @()
                    })
                }
            }
            foreach ($t in $p.RecursiveTargets) {
                $rdirs = Get-ChildItem -Path $dir -Recurse -Directory -Filter $t -ErrorAction SilentlyContinue
                if ($rdirs -and $rdirs.Count -gt 0) {
                    $sz = [long]0
                    foreach ($rd in $rdirs) {
                        $sz += [CleanerContext]::DirSizeBytes($rd.FullName)
                    }
                    $totalBytes += $sz
                    [void]$breakdown.Add([PSCustomObject]@{
                        Name = "$t (recursive, $($rdirs.Count) dirs)"
                        SizeBytes = $sz
                        Children = @()
                    })
                }
            }
        }

        # Sort breakdown by size descending
        $sortedBreakdown = @($breakdown | Sort-Object -Property SizeBytes -Descending)

        # Emit JSON
        $w.Json(@{
            event = "analyze_result"
            profile = $p.Key
            project = $rel
            path = $dir
            total_bytes = $totalBytes
            breakdown = @($sortedBreakdown | ForEach-Object {
                $entry = @{ name = $_.Name; size_bytes = $_.SizeBytes }
                if ($_.Children.Count -gt 0) {
                    $entry["children"] = @($_.Children | ForEach-Object {
                        @{ name = $_.Name; size_bytes = $_.SizeBytes }
                    })
                }
                $entry
            })
        })

        return [PSCustomObject]@{
            Project = $rel
            Path = $dir
            TotalBytes = $totalBytes
            Breakdown = $sortedBreakdown
        }
    }

    hidden [void] FindOrphanedArtifacts([string]$projectDir, [string]$artifactDirName, [System.Collections.ArrayList]$breakdown, [ref]$totalBytes) {
        # Look for nested artifact dirs that cargo clean at the root level wouldn't have caught
        # e.g., main/features/target/, sub-crate/target/
        try {
            $nestedTargets = Get-ChildItem -Path $projectDir -Recurse -Directory -Filter $artifactDirName -ErrorAction SilentlyContinue |
                Where-Object {
                    # Exclude the root-level artifact dir itself
                    $_.FullName -ne (Join-Path $projectDir $artifactDirName) -and
                    # Exclude anything inside another artifact dir (target/debug/target/ etc.)
                    $_.FullName -notmatch [regex]::Escape($artifactDirName) + ".*" + [regex]::Escape($artifactDirName)
                }

            foreach ($nested in $nestedTargets) {
                $sz = [CleanerContext]::DirSizeBytes($nested.FullName)
                if ($sz -gt 0) {
                    $relNested = $nested.FullName.Substring($projectDir.Length).TrimStart('\', '/')
                    [void]$breakdown.Add([PSCustomObject]@{
                        Name = "$relNested (orphaned)"
                        SizeBytes = $sz
                        Children = @()
                    })
                    $totalBytes.Value += $sz
                }
            }
        } catch {
            # Ignore permission errors
        }
    }

    hidden [void] ReportProject([PSCustomObject]$result, [int]$rank, [long]$profileTotal) {
        $w = $this.Ctx.Writer
        if ($w.JsonMode) { return }

        $pct = if ($profileTotal -gt 0) { [math]::Round($result.TotalBytes / $profileTotal * 100, 1) } else { 0 }
        $sizeColor = if ($result.TotalBytes -ge 1GB) { "Red" } elseif ($result.TotalBytes -ge 100MB) { "Yellow" } else { "White" }

        $w.TextNoNewline("  [$rank] ", "DarkGray")
        $w.TextNoNewline("$($result.Project)", "White")
        $spaces = [math]::Max(1, 45 - $result.Project.Length)
        $w.TextNoNewline((" " * $spaces), "White")
        $w.Text("$([CleanerContext]::FormatSize($result.TotalBytes)) ($pct%)", $sizeColor)

        foreach ($entry in $result.Breakdown) {
            $entrySizeStr = [CleanerContext]::FormatSize($entry.SizeBytes)
            $isOrphaned = $entry.Name -match "\(orphaned\)"
            $entryColor = if ($isOrphaned) { "Magenta" } else { "DarkGray" }
            $w.Text("      $($entry.Name): $entrySizeStr", $entryColor)

            # Show children (one more level deep) for large entries
            foreach ($child in $entry.Children) {
                if ($child.SizeBytes -gt 10MB) {
                    $w.Text("        $($child.Name): $([CleanerContext]::FormatSize($child.SizeBytes))", "DarkGray")
                }
            }
        }
    }
}

# ─── Build Benchmarker ───────────────────────────────────────────────────────────

class BuildBenchmarker {
    [CleanProfile]   $Profile
    [CleanerContext]  $Ctx

    BuildBenchmarker([CleanProfile]$profile, [CleanerContext]$ctx) {
        $this.Profile = $profile
        $this.Ctx     = $ctx
    }

    [void] Run([int]$profileIndex, [int]$profileCount) {
        $p = $this.Profile
        $w = $this.Ctx.Writer

        if ([string]::IsNullOrEmpty($p.BuildCommand)) {
            $w.BlankLine()
            $w.Text("--- $($p.Name) [$profileIndex/$profileCount] ---", "Cyan")
            $w.Text("No build_command configured for $($p.Name), skipping benchmark.", "DarkGray")
            return
        }

        $w.BlankLine()
        $w.Text("--- $($p.Name) Benchmark [$profileIndex/$profileCount] ---", "Cyan")
        $w.Text("Build command: $($p.BuildCommand)", "DarkGray")

        Write-Progress -Id 0 -Activity "disk-cleaner benchmark" `
            -Status "Profile $profileIndex/$profileCount : $($p.Name)" `
            -PercentComplete (($profileIndex - 1) / $profileCount * 100)

        # Scan and filter
        $foundDirs = $this.Ctx.ScanForProjects($p)
        $filtered = $this.Ctx.FilterProjects($foundDirs)
        $toTest = $filtered.ToProcess

        if ($toTest.Count -eq 0) {
            $w.Text("No $($p.Name) projects found.", "DarkGray")
            return
        }

        $w.BlankLine()
        $w.Text("Benchmarking $($toTest.Count) $($p.Name) projects...", "Cyan")
        $w.BlankLine()

        $results = [System.Collections.ArrayList]::new()
        $projectIndex = 0

        foreach ($dir in $toTest) {
            if ($this.Ctx.Cancelled) { break }
            $projectIndex++
            $rel = $this.Ctx.RelativePath($dir)

            $pct = [math]::Min(100, [int]($projectIndex / $toTest.Count * 100))
            Write-Progress -Id 1 -ParentId 0 -Activity "$($p.Name) benchmark" `
                -Status "[$projectIndex/$($toTest.Count)] $rel" `
                -PercentComplete $pct

            $timing = $this.BenchmarkProject($dir, $rel, $p.BuildCommand, $projectIndex, $toTest.Count)
            if ($timing) {
                [void]$results.Add($timing)
            }
        }

        Write-Progress -Id 1 -ParentId 0 -Activity "$($p.Name) benchmark" -Completed

        if ($results.Count -eq 0) { return }

        # Sort by duration descending (slowest first)
        $sorted = @($results | Sort-Object -Property DurationMs -Descending)

        $w.BlankLine()
        $w.Text("--- Build Time Rankings (slowest first) ---", "Cyan")
        $w.BlankLine()

        $rank = 0
        foreach ($r in $sorted) {
            $rank++
            $durationStr = $this.FormatDuration($r.DurationMs)
            $color = if ($r.DurationMs -ge 60000) { "Red" } elseif ($r.DurationMs -ge 10000) { "Yellow" } else { "Green" }
            $status = if ($r.Success) { "" } else { " (FAILED)" }

            $w.TextNoNewline("  [$rank] ", "DarkGray")
            $w.TextNoNewline("$($r.Project)", "White")
            $spaces = [math]::Max(1, 45 - $r.Project.Length)
            $w.TextNoNewline((" " * $spaces), "White")
            $w.Text("$durationStr$status", $color)

            $w.Json(@{
                event = "benchmark_result"
                profile = $p.Key
                project = $r.Project
                duration_ms = $r.DurationMs
                success = $r.Success
                rank = $rank
            })
        }

        # Stats
        $successResults = @($sorted | Where-Object { $_.Success })
        if ($successResults.Count -gt 0) {
            $durations = $successResults | ForEach-Object { $_.DurationMs }
            $totalMs = ($durations | Measure-Object -Sum).Sum
            $avgMs = [math]::Round($totalMs / $successResults.Count)
            $maxMs = ($durations | Measure-Object -Maximum).Maximum
            $minMs = ($durations | Measure-Object -Minimum).Minimum

            $w.BlankLine()
            $w.Text("  Stats:", "Cyan")
            $w.Text("    Slowest:  $($this.FormatDuration($maxMs))", "DarkGray")
            $w.Text("    Fastest:  $($this.FormatDuration($minMs))", "DarkGray")
            $w.Text("    Average:  $($this.FormatDuration($avgMs))", "DarkGray")
            $w.Text("    Total:    $($this.FormatDuration($totalMs))", "DarkGray")

            $w.Json(@{
                event = "benchmark_stats"
                profile = $p.Key
                projects_benchmarked = $successResults.Count
                slowest_ms = $maxMs
                fastest_ms = $minMs
                average_ms = $avgMs
                total_ms = $totalMs
            })
        }
    }

    hidden [PSCustomObject] BenchmarkProject([string]$dir, [string]$rel, [string]$buildCmd, [int]$index, [int]$total) {
        $w = $this.Ctx.Writer

        $w.TextNoNewline("  [$index/$total] ", "DarkGray")
        $w.TextNoNewline("Building: $rel ... ", "White")

        $success = $true
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            Push-Location $dir
            $cmd = $buildCmd
            $p = $this.Profile
            if ($p.Wrapper -and (Test-Path $p.Wrapper)) {
                $cmd = "$($p.Wrapper) build"
            }
            $result = Invoke-Expression "$cmd 2>&1" | Out-String
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                $success = $false
            }
        } catch {
            $success = $false
        } finally {
            Pop-Location
            $sw.Stop()
        }

        $durationMs = $sw.ElapsedMilliseconds
        $durationStr = $this.FormatDuration($durationMs)
        $color = if (-not $success) { "Red" } elseif ($durationMs -ge 60000) { "Yellow" } else { "Green" }
        $statusSuffix = if (-not $success) { " FAILED" } else { "" }

        if (-not $w.JsonMode) {
            $w.Text("$durationStr$statusSuffix", $color)
        }

        return [PSCustomObject]@{
            Project = $rel
            DurationMs = $durationMs
            Success = $success
        }
    }

    [string] FormatDuration([long]$ms) {
        if ($ms -ge 60000) {
            $min = [math]::Floor($ms / 60000)
            $sec = [math]::Round(($ms % 60000) / 1000, 1)
            return "${min}m ${sec}s"
        } elseif ($ms -ge 1000) {
            return "$([math]::Round($ms / 1000, 2))s"
        }
        return "${ms}ms"
    }
}

# ─── Disk Usage Analyzer ─────────────────────────────────────────────────────────

class DiskUsageAnalyzer {
    [CleanerContext]  $Ctx
    [int]             $Depth

    DiskUsageAnalyzer([CleanerContext]$ctx, [int]$depth) {
        $this.Ctx   = $ctx
        $this.Depth = $depth
    }

    [void] Run() {
        $w = $this.Ctx.Writer
        $rootPath = $this.Ctx.SearchPath

        # Resolve drive info
        $driveInfo = $null
        try {
            $driveLetter = [System.IO.Path]::GetPathRoot($rootPath)
            $driveInfo = [System.IO.DriveInfo]::new($driveLetter)
        } catch {}

        $startEvent = @{ event = "start"; command = "disk-usage"; path = $rootPath; depth = $this.Depth }
        if ($driveInfo -and $driveInfo.IsReady) {
            $startEvent["drive_total_bytes"] = $driveInfo.TotalSize
            $startEvent["drive_free_bytes"]  = $driveInfo.AvailableFreeSpace
            $startEvent["drive_used_bytes"]  = $driveInfo.TotalSize - $driveInfo.AvailableFreeSpace
        }
        $w.Json($startEvent)

        $w.Text("disk-cleaner analyze -DiskUsage", "Cyan")
        $w.Text("Path: $rootPath", "DarkGray")
        $w.Text("Depth: $($this.Depth)", "DarkGray")

        if ($driveInfo -and $driveInfo.IsReady) {
            $driveTotal = $driveInfo.TotalSize
            $driveFree  = $driveInfo.AvailableFreeSpace
            $driveUsed  = $driveTotal - $driveFree
            $drivePct   = [math]::Round($driveUsed / $driveTotal * 100, 1)
            $driveColor = if ($drivePct -ge 90) { "Red" } elseif ($drivePct -ge 75) { "Yellow" } else { "Green" }
            $w.Text("Drive: $([CleanerContext]::FormatSize($driveUsed)) used / $([CleanerContext]::FormatSize($driveTotal)) total ($drivePct%) - $([CleanerContext]::FormatSize($driveFree)) free", $driveColor)
        }

        if (-not (Test-Path $rootPath)) {
            $w.Text("Path does not exist: $rootPath", "Red")
            $w.Json(@{ event = "error"; message = "Path does not exist: $rootPath" })
            return
        }

        $w.BlankLine()
        $w.Text("Scanning...", "DarkGray")

        $rootSize = [CleanerContext]::DirSizeBytes($rootPath)
        $this.Ctx.TotalSizeBytes = $rootSize

        # Collect top-level children
        $entries = [System.Collections.ArrayList]::new()
        $childDirs = Get-ChildItem -Path $rootPath -Directory -Force -ErrorAction SilentlyContinue
        $childFiles = Get-ChildItem -Path $rootPath -File -Force -ErrorAction SilentlyContinue

        $dirIndex = 0
        $dirCount = @($childDirs).Count

        foreach ($child in $childDirs) {
            if ($this.Ctx.Cancelled) { break }
            $dirIndex++
            Write-Progress -Id 0 -Activity "disk-cleaner disk-usage" `
                -Status "[$dirIndex/$dirCount] $($child.Name)" `
                -PercentComplete ([math]::Min(100, [int]($dirIndex / [math]::Max(1, $dirCount) * 100)))

            $childSize = [CleanerContext]::DirSizeBytes($child.FullName)
            $childEntry = [PSCustomObject]@{
                Name      = $child.Name
                Path      = $child.FullName
                SizeBytes = $childSize
                IsDir     = $true
                Children  = [System.Collections.ArrayList]::new()
            }

            # Drill deeper if requested
            if ($this.Depth -gt 1 -and $childSize -gt 0) {
                $this.CollectChildren($child.FullName, $childEntry.Children, 2)
            }

            [void]$entries.Add($childEntry)
        }

        # Sum loose files
        $looseFileSize = [long]0
        foreach ($f in $childFiles) {
            $looseFileSize += $f.Length
        }
        if ($looseFileSize -gt 0) {
            [void]$entries.Add([PSCustomObject]@{
                Name      = "(files)"
                Path      = $rootPath
                SizeBytes = $looseFileSize
                IsDir     = $false
                Children  = [System.Collections.ArrayList]::new()
            })
        }

        Write-Progress -Id 0 -Activity "disk-cleaner disk-usage" -Completed

        # Sort descending by size
        $sorted = @($entries | Sort-Object -Property SizeBytes -Descending)

        # Report
        $w.BlankLine()
        $w.Text("--- Disk Usage: $rootPath ---", "Cyan")
        $w.Text("Total: $([CleanerContext]::FormatSize($rootSize))", "White")
        $w.BlankLine()

        $rank = 0
        foreach ($entry in $sorted) {
            if ($entry.SizeBytes -eq 0) { continue }
            $rank++
            $this.ReportEntry($entry, $rootSize, $rank, "  ")

            $w.Json(@{
                event      = "disk_usage_entry"
                name       = $entry.Name
                path       = $entry.Path
                size_bytes = $entry.SizeBytes
                is_dir     = $entry.IsDir
            })
        }

        # System files probe (only when scanning a drive root)
        $systemFilesSize = [long]0
        $systemEntries = [System.Collections.ArrayList]::new()
        $isDriveRoot = ($rootPath -match '^[A-Za-z]:\\?$')

        if ($isDriveRoot -and $driveInfo -and $driveInfo.IsReady) {
            $driveRoot = $driveInfo.RootDirectory.FullName
            $systemFilesSize = $this.ProbeSystemFiles($driveRoot, $systemEntries)
        }

        # Summary
        $w.BlankLine()
        $entryCount = @($sorted | Where-Object { $_.SizeBytes -gt 0 }).Count
        $sizeColor = if ($rootSize -ge 1GB) { "Red" } elseif ($rootSize -ge 100MB) { "Yellow" } else { "Green" }
        $w.Text("Total scanned: $([CleanerContext]::FormatSize($rootSize))  ($entryCount entries)", $sizeColor)

        if ($isDriveRoot -and $driveInfo -and $driveInfo.IsReady) {
            $driveTotal = $driveInfo.TotalSize
            $driveFree  = $driveInfo.AvailableFreeSpace
            $driveUsed  = $driveTotal - $driveFree
            $drivePct   = [math]::Round($driveUsed / $driveTotal * 100, 1)
            $accounted  = $rootSize + $systemFilesSize
            $unaccounted = [math]::Max([long]0, [long]($driveUsed - $accounted))
            $driveColor = if ($drivePct -ge 90) { "Red" } elseif ($drivePct -ge 75) { "Yellow" } else { "Green" }

            if ($systemEntries.Count -gt 0) {
                $w.BlankLine()
                $w.Text("--- System / Hidden Files ---", "Cyan")
                foreach ($sf in $systemEntries) {
                    $sfColor = if ($sf.SizeBytes -ge 1GB) { "Yellow" } else { "DarkGray" }
                    $sfStatus = if ($sf.Accessible) { "" } else { " (access denied)" }
                    if ($sf.SizeBytes -gt 0) {
                        $w.Text("  $($sf.Name): $([CleanerContext]::FormatSize($sf.SizeBytes))$sfStatus", $sfColor)
                    } else {
                        $w.Text("  $($sf.Name): $sfStatus", "DarkGray")
                    }
                    $w.Json(@{
                        event      = "system_file"
                        name       = $sf.Name
                        path       = $sf.Path
                        size_bytes = $sf.SizeBytes
                        accessible = $sf.Accessible
                    })
                }
                $w.Text("  System files total: $([CleanerContext]::FormatSize($systemFilesSize))", "White")
            }

            if ($unaccounted -gt 0) {
                $w.BlankLine()
                $w.Text("--- Unaccounted Space ---", "Cyan")
                $w.Text("  $([CleanerContext]::FormatSize($unaccounted)) not visible to scan", "DarkGray")
                $w.Text("  (restricted dirs, NTFS metadata, VSS snapshots, etc.)", "DarkGray")

                $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                if (-not $isAdmin) {
                    $w.Text("  Run as Administrator for a more complete scan", "Yellow")
                }

                $w.Json(@{
                    event            = "unaccounted_space"
                    unaccounted_bytes = $unaccounted
                    is_admin         = $isAdmin
                })
            }

            # WSL virtual disk introspection
            $this.ProbeWSLDistros()

            # Remediation hints
            $remediations = $this.BuildRemediation($sorted, $systemEntries)
            if ($remediations.Count -gt 0) {
                $w.BlankLine()
                $w.Text("--- Remediation ---", "Cyan")
                foreach ($rem in $remediations) {
                    $remColor = if ($rem.SizeBytes -ge 10GB) { "Red" } elseif ($rem.SizeBytes -ge 1GB) { "Yellow" } else { "White" }
                    $w.TextNoNewline("  $($rem.Name)", $remColor)
                    $pad = [math]::Max(1, 35 - $rem.Name.Length)
                    $w.TextNoNewline((" " * $pad), "White")
                    $w.TextNoNewline("$([CleanerContext]::FormatSize($rem.SizeBytes))", $remColor)
                    $w.Text("  $($rem.Action)", "DarkGray")

                    $w.Json(@{
                        event      = "remediation"
                        name       = $rem.Name
                        path       = $rem.Path
                        size_bytes = $rem.SizeBytes
                        action     = $rem.Action
                    })
                }
            }

            $w.BlankLine()
            $w.Text("Drive: $([CleanerContext]::FormatSize($driveUsed)) / $([CleanerContext]::FormatSize($driveTotal)) ($drivePct% used) - $([CleanerContext]::FormatSize($driveFree)) free", $driveColor)
        } elseif ($driveInfo -and $driveInfo.IsReady) {
            $driveTotal = $driveInfo.TotalSize
            $driveFree  = $driveInfo.AvailableFreeSpace
            $driveUsed  = $driveTotal - $driveFree
            $drivePct   = [math]::Round($driveUsed / $driveTotal * 100, 1)
            $pathPct    = if ($driveTotal -gt 0) { [math]::Round($rootSize / $driveTotal * 100, 1) } else { 0 }
            $driveColor = if ($drivePct -ge 90) { "Red" } elseif ($drivePct -ge 75) { "Yellow" } else { "Green" }

            # Remediation for non-root paths
            $remediations = $this.BuildRemediation($sorted, $null)
            if ($remediations.Count -gt 0) {
                $w.BlankLine()
                $w.Text("--- Remediation ---", "Cyan")
                foreach ($rem in $remediations) {
                    $remColor = if ($rem.SizeBytes -ge 10GB) { "Red" } elseif ($rem.SizeBytes -ge 1GB) { "Yellow" } else { "White" }
                    $w.TextNoNewline("  $($rem.Name)", $remColor)
                    $pad = [math]::Max(1, 35 - $rem.Name.Length)
                    $w.TextNoNewline((" " * $pad), "White")
                    $w.TextNoNewline("$([CleanerContext]::FormatSize($rem.SizeBytes))", $remColor)
                    $w.Text("  $($rem.Action)", "DarkGray")

                    $w.Json(@{
                        event      = "remediation"
                        name       = $rem.Name
                        path       = $rem.Path
                        size_bytes = $rem.SizeBytes
                        action     = $rem.Action
                    })
                }
            }

            $w.BlankLine()
            $w.Text("Drive: $([CleanerContext]::FormatSize($driveUsed)) / $([CleanerContext]::FormatSize($driveTotal)) ($drivePct% used) - $([CleanerContext]::FormatSize($driveFree)) free", $driveColor)
            $w.Text("Path is $pathPct% of drive", "DarkGray")
        }

        $summaryEvent = @{
            event       = "summary"
            command     = "disk-usage"
            path        = $rootPath
            total_bytes = $rootSize
            entry_count = $sorted.Count
        }
        if ($driveInfo -and $driveInfo.IsReady) {
            $summaryEvent["drive_total_bytes"] = $driveInfo.TotalSize
            $summaryEvent["drive_free_bytes"]  = $driveInfo.AvailableFreeSpace
            $summaryEvent["drive_used_bytes"]  = $driveInfo.TotalSize - $driveInfo.AvailableFreeSpace
        }
        if ($systemFilesSize -gt 0) {
            $summaryEvent["system_files_bytes"] = $systemFilesSize
        }
        $w.Json($summaryEvent)
    }

    hidden [void] CollectChildren([string]$parentPath, [System.Collections.ArrayList]$list, [int]$currentDepth) {
        if ($currentDepth -gt $this.Depth) { return }

        $subDirs = Get-ChildItem -Path $parentPath -Directory -Force -ErrorAction SilentlyContinue
        foreach ($sub in $subDirs) {
            if ($this.Ctx.Cancelled) { return }
            $sz = [CleanerContext]::DirSizeBytes($sub.FullName)
            if ($sz -gt 0) {
                $childEntry = [PSCustomObject]@{
                    Name      = $sub.Name
                    Path      = $sub.FullName
                    SizeBytes = $sz
                    IsDir     = $true
                    Children  = [System.Collections.ArrayList]::new()
                }
                if ($currentDepth -lt $this.Depth) {
                    $this.CollectChildren($sub.FullName, $childEntry.Children, $currentDepth + 1)
                }
                [void]$list.Add($childEntry)
            }
        }
    }

    hidden [void] ReportEntry([PSCustomObject]$entry, [long]$parentSize, [int]$rank, [string]$indent) {
        $w = $this.Ctx.Writer
        if ($w.JsonMode) { return }

        $pct = if ($parentSize -gt 0) { [math]::Round($entry.SizeBytes / $parentSize * 100, 1) } else { 0 }
        $sizeColor = if ($entry.SizeBytes -ge 1GB) { "Red" } elseif ($entry.SizeBytes -ge 100MB) { "Yellow" } else { "White" }
        $suffix = if ($entry.IsDir) { "/" } else { "" }

        $nameStr = "$($entry.Name)$suffix"
        $w.TextNoNewline("${indent}[$rank] ", "DarkGray")
        $w.TextNoNewline($nameStr, "White")
        $spaces = [math]::Max(1, 40 - $nameStr.Length)
        $w.Text((" " * $spaces) + "$([CleanerContext]::FormatSize($entry.SizeBytes)) ($pct%)", $sizeColor)

        # Show children sorted by size
        $sortedChildren = @($entry.Children | Sort-Object -Property SizeBytes -Descending)
        $childRank = 0
        foreach ($child in $sortedChildren) {
            if ($child.SizeBytes -eq 0) { continue }
            $childRank++
            $childPct = if ($entry.SizeBytes -gt 0) { [math]::Round($child.SizeBytes / $entry.SizeBytes * 100, 1) } else { 0 }
            $childColor = if ($child.SizeBytes -ge 1GB) { "Red" } elseif ($child.SizeBytes -ge 100MB) { "Yellow" } else { "DarkGray" }
            $childSuffix = if ($child.IsDir) { "/" } else { "" }
            $w.Text("${indent}    $($child.Name)$childSuffix : $([CleanerContext]::FormatSize($child.SizeBytes)) ($childPct%)", $childColor)

            # One more level
            $grandChildren = @($child.Children | Sort-Object -Property SizeBytes -Descending)
            foreach ($gc in $grandChildren) {
                if ($gc.SizeBytes -eq 0) { continue }
                $gcPct = if ($child.SizeBytes -gt 0) { [math]::Round($gc.SizeBytes / $child.SizeBytes * 100, 1) } else { 0 }
                $w.Text("${indent}        $($gc.Name)/ : $([CleanerContext]::FormatSize($gc.SizeBytes)) ($gcPct%)", "DarkGray")
            }
        }
    }

    hidden [long] ProbeSystemFiles([string]$driveRoot, [System.Collections.ArrayList]$results) {
        $totalProbed = [long]0

        # Known large system files
        $systemFiles = @(
            @{ Name = "pagefile.sys";   Path = Join-Path $driveRoot "pagefile.sys" }
            @{ Name = "hiberfil.sys";   Path = Join-Path $driveRoot "hiberfil.sys" }
            @{ Name = "swapfile.sys";   Path = Join-Path $driveRoot "swapfile.sys" }
        )

        foreach ($sf in $systemFiles) {
            $size = [long]0
            $accessible = $false
            try {
                $fi = [System.IO.FileInfo]::new($sf.Path)
                if ($fi.Exists) {
                    $size = $fi.Length
                    $accessible = $true
                }
            } catch {
                # File exists but we can't read its size — try via WMI
                try {
                    $cimFile = Get-CimInstance -ClassName CIM_DataFile -Filter "Name='$($sf.Path.Replace('\','\\'))'" -ErrorAction SilentlyContinue
                    if ($cimFile) {
                        $size = [long]$cimFile.FileSize
                        $accessible = $true
                    }
                } catch {}
            }

            if ($size -gt 0 -or (Test-Path $sf.Path -ErrorAction SilentlyContinue)) {
                [void]$results.Add([PSCustomObject]@{
                    Name       = $sf.Name
                    Path       = $sf.Path
                    SizeBytes  = $size
                    Accessible = $accessible
                })
                $totalProbed += $size
            }
        }

        # Known large system directories
        $systemDirs = @(
            @{ Name = "System Volume Information"; Path = Join-Path $driveRoot "System Volume Information" }
            @{ Name = '$Recycle.Bin';              Path = Join-Path $driveRoot '$Recycle.Bin' }
            @{ Name = "Recovery";                  Path = Join-Path $driveRoot "Recovery" }
        )

        foreach ($sd in $systemDirs) {
            if (Test-Path $sd.Path -ErrorAction SilentlyContinue) {
                $size = [long]0
                $accessible = $false
                try {
                    $size = [CleanerContext]::DirSizeBytes($sd.Path)
                    if ($size -gt 0) { $accessible = $true }
                } catch {}

                [void]$results.Add([PSCustomObject]@{
                    Name       = $sd.Name + "/"
                    Path       = $sd.Path
                    SizeBytes  = $size
                    Accessible = $accessible
                })
                $totalProbed += $size
            }
        }

        # Check for WSL vhdx files
        $wslPaths = @(
            "$env:LOCALAPPDATA\Packages",
            "$env:LOCALAPPDATA\Docker"
        )
        foreach ($wslRoot in $wslPaths) {
            if (Test-Path $wslRoot -ErrorAction SilentlyContinue) {
                try {
                    $vhdxFiles = Get-ChildItem -Path $wslRoot -Recurse -Filter "*.vhdx" -ErrorAction SilentlyContinue
                    foreach ($vhdx in $vhdxFiles) {
                        if ($vhdx.Length -gt 100MB) {
                            [void]$results.Add([PSCustomObject]@{
                                Name       = "WSL/Docker: $($vhdx.Name)"
                                Path       = $vhdx.FullName
                                SizeBytes  = $vhdx.Length
                                Accessible = $true
                            })
                            $totalProbed += $vhdx.Length
                        }
                    }
                } catch {}
            }
        }

        return $totalProbed
    }

    hidden [void] ProbeWSLDistros() {
        $w = $this.Ctx.Writer

        # Check if WSL is available
        $wslCmd = Get-Command wsl -ErrorAction SilentlyContinue
        if (-not $wslCmd) { return }

        # Get distro list
        $distroRaw = $null
        try {
            $distroRaw = wsl --list --quiet 2>$null
        } catch { return }
        if (-not $distroRaw) { return }

        # Parse distro names (wsl --list outputs UTF-16, may have null bytes)
        $distros = @($distroRaw | ForEach-Object { $_.Trim().Replace("`0", "") } | Where-Object { $_.Length -gt 0 })
        if ($distros.Count -eq 0) { return }

        $w.BlankLine()
        $w.Text("--- WSL Virtual Disks ---", "Cyan")

        # Find all vhdx files once upfront
        $allVhdx = [System.Collections.ArrayList]::new()
        $wslRoot = "$env:LOCALAPPDATA\wsl"
        if (Test-Path $wslRoot) {
            $vhdxFiles = Get-ChildItem -Path $wslRoot -Recurse -Filter "ext4.vhdx" -Force -Depth 3 -ErrorAction SilentlyContinue
            foreach ($vf in $vhdxFiles) {
                if ($vf.Length -gt 0) {
                    [void]$allVhdx.Add($vf)
                }
            }
        }
        $seenVhdx = @{}

        # WSL remediation rules: path pattern inside Linux -> action
        $wslRules = @(
            @{ Pattern = "^/var/lib/docker";   Action = "docker system prune -a" }
            @{ Pattern = "^/var/cache/apt";    Action = "sudo apt clean" }
            @{ Pattern = "^/var/log";          Action = "sudo journalctl --vacuum-size=100M" }
            @{ Pattern = "^/snap";             Action = "snap list --all; sudo snap remove --purge <old>" }
            @{ Pattern = "^/tmp";              Action = "rm -rf /tmp/*" }
            @{ Pattern = "^/home/.*/\.cache";  Action = "rm -rf ~/.cache/*" }
            @{ Pattern = "^/home/.*/\.local";  Action = "Review ~/.local/share for stale data" }
            @{ Pattern = "^/usr";              Action = "sudo apt autoremove" }
        )

        foreach ($distro in $distros) {
            if ($this.Ctx.Cancelled) { break }

            # Match distro to a vhdx file (assign unmatched vhdx by order)
            $vhdxSize = [long]0
            $vhdxPath = ""
            foreach ($vf in $allVhdx) {
                if (-not $seenVhdx.ContainsKey($vf.FullName)) {
                    $vhdxSize = $vf.Length
                    $vhdxPath = $vf.FullName
                    $seenVhdx[$vf.FullName] = $distro
                    break
                }
            }

            $vhdxSizeStr = if ($vhdxSize -gt 0) { [CleanerContext]::FormatSize($vhdxSize) } else { "unknown" }
            $vhdxColor = if ($vhdxSize -ge 50GB) { "Red" } elseif ($vhdxSize -ge 10GB) { "Yellow" } else { "White" }
            $w.BlankLine()
            $w.Text("  $distro (vhdx: $vhdxSizeStr)", $vhdxColor)
            if ($vhdxPath) {
                $w.Text("  $vhdxPath", "DarkGray")
            }

            # Shell into WSL and run du (with 60s timeout)
            $duOutput = $null
            try {
                $w.Text("  Scanning inside $distro...", "DarkGray")
                $job = Start-Job -ScriptBlock {
                    param($d)
                    wsl -d $d -- bash -c "du -h --max-depth=2 / 2>/dev/null | sort -rh | head -20"
                } -ArgumentList $distro
                $completed = $job | Wait-Job -Timeout 60
                if ($completed) {
                    $duOutput = Receive-Job $job
                }
                Remove-Job $job -Force -ErrorAction SilentlyContinue
            } catch {}

            if (-not $duOutput) {
                $w.Text("  Could not scan (timed out or distro unavailable)", "DarkGray")
                $w.Json(@{ event = "wsl_distro"; distro = $distro; vhdx_bytes = $vhdxSize; error = "scan_failed" })
                continue
            }

            # Parse du output: "1.2G\t/var/lib/docker"
            $wslEntries = [System.Collections.ArrayList]::new()
            foreach ($line in $duOutput) {
                $line = $line.Trim()
                if ($line.Length -eq 0) { continue }
                $parts = $line -split '\s+', 2
                if ($parts.Count -lt 2) { continue }
                $sizeStr = $parts[0]
                $path = $parts[1]

                # Parse human-readable size to bytes
                $sizeBytes = [long]0
                if ($sizeStr -match '^([\d.]+)([KMGTP]?)$') {
                    $num = [double]$Matches[1]
                    switch ($Matches[2]) {
                        'K' { $sizeBytes = [long]($num * 1KB) }
                        'M' { $sizeBytes = [long]($num * 1MB) }
                        'G' { $sizeBytes = [long]($num * 1GB) }
                        'T' { $sizeBytes = [long]($num * 1TB) }
                        'P' { $sizeBytes = [long]($num * 1PB) }
                        default { $sizeBytes = [long]$num }
                    }
                }

                if ($path -eq "/" -or $sizeBytes -lt 1MB) { continue }

                # Match remediation
                $action = ""
                foreach ($rule in $wslRules) {
                    if ($path -match $rule.Pattern) {
                        $action = $rule.Action
                        break
                    }
                }

                [void]$wslEntries.Add([PSCustomObject]@{
                    Path      = $path
                    SizeStr   = $sizeStr
                    SizeBytes = $sizeBytes
                    Action    = $action
                })
            }

            # Display top entries
            $shown = 0
            foreach ($entry in $wslEntries) {
                if ($shown -ge 15) { break }
                $shown++
                $entryColor = if ($entry.SizeBytes -ge 10GB) { "Red" } elseif ($entry.SizeBytes -ge 1GB) { "Yellow" } else { "DarkGray" }
                $actionStr = if ($entry.Action) { "  $($entry.Action)" } else { "" }

                $nameStr = $entry.Path
                $w.TextNoNewline("    $nameStr", $entryColor)
                $pad = [math]::Max(1, 38 - $nameStr.Length)
                $w.TextNoNewline((" " * $pad), "White")
                $w.Text("$($entry.SizeStr)$actionStr", $entryColor)

                $w.Json(@{
                    event      = "wsl_entry"
                    distro     = $distro
                    path       = $entry.Path
                    size       = $entry.SizeStr
                    size_bytes = $entry.SizeBytes
                    action     = $entry.Action
                })
            }

            # Compact hint
            if ($vhdxSize -gt 0) {
                $actualUsed = if ($wslEntries.Count -gt 0) { $wslEntries[0].SizeBytes } else { 0 }
                if ($actualUsed -gt 0 -and $vhdxSize -gt ($actualUsed * 1.5)) {
                    $reclaimable = $vhdxSize - $actualUsed
                    $w.BlankLine()
                    $w.Text("    Compactable: ~$([CleanerContext]::FormatSize($reclaimable)) reclaimable", "Green")
                    $w.Text("    disk-cleaner.ps1 compact-wsl (or: wsl --shutdown && diskpart)", "DarkGray")
                }
            }

            $w.Json(@{
                event      = "wsl_distro"
                distro     = $distro
                vhdx_bytes = $vhdxSize
                vhdx_path  = $vhdxPath
                entries    = @($wslEntries | ForEach-Object { @{ path = $_.Path; size = $_.SizeStr; action = $_.Action } })
            })
        }
    }

    hidden [System.Collections.ArrayList] BuildRemediation([PSCustomObject[]]$entries, [System.Collections.ArrayList]$systemEntries) {
        $hints = [System.Collections.ArrayList]::new()
        $minSize = [long]500MB

        # Known remediation rules: pattern on full path -> action text
        $rules = @(
            @{ Pattern = "\\AppData\\Local\\wsl";                Action = "disk-cleaner.ps1 compact-wsl" }
            @{ Pattern = "\\AppData\\Local\\Docker";             Action = "docker system prune -a" }
            @{ Pattern = "\\AppData\\Local\\Temp";               Action = "Safe to delete: Remove-Item $env:TEMP\* -Recurse -Force" }
            @{ Pattern = "\\AppData\\Local\\npm-cache";          Action = "npm cache clean --force" }
            @{ Pattern = "\\AppData\\Local\\Ollama";             Action = "ollama list; ollama rm <unused-models>" }
            @{ Pattern = "\\AppData\\Local\\ms-playwright";      Action = "npx playwright install --dry-run (remove unused browsers)" }
            @{ Pattern = "\\AppData\\Local\\NuGet";              Action = "dotnet nuget locals all --clear" }
            @{ Pattern = "\\AppData\\Local\\pip\\Cache";         Action = "pip cache purge" }
            @{ Pattern = "\\AppData\\Local\\yarn\\Cache";        Action = "yarn cache clean" }
            @{ Pattern = "\\AppData\\Roaming\\npm-cache";        Action = "npm cache clean --force" }
            @{ Pattern = "\\AppData\\Roaming\\Code";             Action = "VS Code: clear Extension cache + workspace storage" }
            @{ Pattern = "\\.rustup";                            Action = "rustup toolchain list; rustup toolchain remove <old>" }
            @{ Pattern = "\\.cargo\\registry";                   Action = "cargo cache --autoclean (install cargo-cache first)" }
            @{ Pattern = "\\.cargo";                             Action = "cargo cache --autoclean (install cargo-cache first)" }
            @{ Pattern = "\\.claude";                            Action = "Claude Code cache; safe to clear old conversations" }
            @{ Pattern = "\\.gemini";                            Action = "Gemini cache; safe to clear" }
            @{ Pattern = "\\.gradle\\caches";                    Action = "gradle --stop; rm -rf ~/.gradle/caches" }
            @{ Pattern = "\\.gradle";                            Action = "gradle --stop; rm -rf ~/.gradle/caches" }
            @{ Pattern = "\\.m2\\repository";                    Action = "mvn dependency:purge-local-repository" }
            @{ Pattern = "\\.m2";                                Action = "mvn dependency:purge-local-repository" }
            @{ Pattern = "\\.bun\\install";                      Action = "bun pm cache rm" }
            @{ Pattern = "\\.bun";                               Action = "bun pm cache rm" }
            @{ Pattern = "\\.cache";                             Action = "Review and clear stale caches" }
            @{ Pattern = "\\.vscode\\extensions";                Action = "VS Code: uninstall unused extensions" }
            @{ Pattern = "\\.vscode";                            Action = "VS Code: uninstall unused extensions" }
            @{ Pattern = "\\.fastembed_cache";                   Action = "Safe to delete if not actively used" }
            @{ Pattern = "\\.pnpm-store";                        Action = "pnpm store prune" }
            @{ Pattern = "\\node_modules";                       Action = "disk-cleaner clean -Lang node" }
            @{ Pattern = "\\target$";                            Action = "disk-cleaner clean -Lang rust (or cargo clean)" }
            @{ Pattern = "\\`$Recycle\\.Bin";                    Action = "Empty Recycle Bin: Clear-RecycleBin -Force" }
            @{ Pattern = "\\Windows\\Temp";                      Action = "Run Disk Cleanup (cleanmgr) as Admin" }
            @{ Pattern = "\\Windows\\SoftwareDistribution";      Action = "Run Disk Cleanup (cleanmgr) as Admin" }
            @{ Pattern = "\\SoftwareDistribution\\Download";     Action = "Stop wuauserv; delete Download folder contents" }
            @{ Pattern = "\\temp$";                              Action = "Review and clean temporary files" }
            @{ Pattern = "\\tmp$";                               Action = "Review and clean temporary files" }
        )

        # System file rules
        $systemRules = @{
            "pagefile.sys" = "Reduce: System > Advanced > Performance > Virtual Memory"
            "hiberfil.sys" = "Disable hibernation: powercfg /h off (saves ~RAM size)"
            "swapfile.sys" = "Managed by Windows (tied to pagefile settings)"
        }

        # Walk all scanned entries recursively to find matches (skip children of matched parents)
        $matchedPaths = @{}
        $this.MatchEntries($entries, $rules, $hints, $minSize, $this.Ctx.SearchPath, $matchedPaths)

        # Match system files
        if ($systemEntries) {
            foreach ($sf in $systemEntries) {
                if ($sf.SizeBytes -ge $minSize -and $systemRules.ContainsKey($sf.Name)) {
                    [void]$hints.Add([PSCustomObject]@{
                        Name      = $sf.Name
                        Path      = $sf.Path
                        SizeBytes = $sf.SizeBytes
                        Action    = $systemRules[$sf.Name]
                    })
                }
            }
        }

        # Sort by size descending
        return [System.Collections.ArrayList]@($hints | Sort-Object -Property SizeBytes -Descending)
    }

    hidden [void] MatchEntries([PSCustomObject[]]$entries, [array]$rules, [System.Collections.ArrayList]$hints, [long]$minSize, [string]$rootPath, [hashtable]$matchedPaths) {
        foreach ($entry in $entries) {
            if ($entry.SizeBytes -lt $minSize) { continue }

            $fullPath = $entry.Path
            if (-not $fullPath -and $entry.Name -ne "(files)") {
                $fullPath = Join-Path $rootPath $entry.Name
            }
            if (-not $fullPath) { continue }

            # Skip if a parent path already matched
            $parentMatched = $false
            foreach ($mp in $matchedPaths.Keys) {
                if ($fullPath.StartsWith($mp + "\") -or $fullPath.StartsWith($mp + "/")) {
                    $parentMatched = $true
                    break
                }
            }
            if ($parentMatched) { continue }

            $thisMatched = $false
            foreach ($rule in $rules) {
                if ($fullPath -match $rule.Pattern -and -not $matchedPaths.ContainsKey($fullPath)) {
                    [void]$hints.Add([PSCustomObject]@{
                        Name      = $entry.Name
                        Path      = $fullPath
                        SizeBytes = $entry.SizeBytes
                        Action    = $rule.Action
                    })
                    $matchedPaths[$fullPath] = $true
                    $thisMatched = $true
                    break
                }
            }

            # Only recurse into children if this entry did NOT match
            if (-not $thisMatched -and $entry.Children -and $entry.Children.Count -gt 0) {
                $this.MatchEntries(@($entry.Children), $rules, $hints, $minSize, $fullPath, $matchedPaths)
            }
        }
    }
}

function Invoke-DiskUsage {
    param(
        [CleanerContext] $Ctx,
        [int]            $Depth = 2
    )

    $analyzer = [DiskUsageAnalyzer]::new($Ctx, $Depth)
    $analyzer.Run()
}

function Invoke-Analyze {
    param(
        [CleanerContext] $Ctx,
        [string[]]       $ProfileKeys,
        [TomlConfig]     $Toml
    )

    $w = $Ctx.Writer
    $isBenchmark = $Ctx.Benchmark

    $startEvent = @{
        event = "start"; command = "analyze"
        profiles = @($ProfileKeys); path = $Ctx.SearchPath
    }
    if ($isBenchmark) { $startEvent["benchmark"] = $true }
    $w.Json($startEvent)

    if ($isBenchmark) {
        $w.Text("disk-cleaner analyze -Benchmark - Build time analysis", "Cyan")
    } else {
        $w.Text("disk-cleaner analyze - Space consumption report", "Cyan")
    }
    $w.Text("Path: $($Ctx.SearchPath)", "DarkGray")
    $w.Text("Profiles: $($ProfileKeys -join ', ')", "DarkGray")

    $profileIdx = 0
    foreach ($profileKey in $ProfileKeys) {
        if ($Ctx.Cancelled) { break }
        $profileIdx++
        $profile = [CleanProfile]::new($profileKey, $Toml)

        if ($isBenchmark) {
            $benchmarker = [BuildBenchmarker]::new($profile, $Ctx)
            $benchmarker.Run($profileIdx, $ProfileKeys.Count)
        } else {
            $analyzer = [ArtifactAnalyzer]::new($profile, $Ctx)
            $analyzer.Run($profileIdx, $ProfileKeys.Count)
        }
    }

    Write-Progress -Id 0 -Activity "disk-cleaner analyze" -Completed

    # Summary
    $summaryEvent = @{
        event = "summary"; command = "analyze"
        profiles_run = $ProfileKeys.Count
        profile_names = @($ProfileKeys)
        projects_found = $Ctx.TotalProjects
    }
    if (-not $isBenchmark) {
        $summaryEvent["projects_with_artifacts"] = $Ctx.TotalCleaned
        $summaryEvent["projects_skipped"] = $Ctx.TotalSkipped
        $summaryEvent["total_artifact_bytes"] = $Ctx.TotalSizeBytes
        $summaryEvent["total_artifact_formatted"] = [CleanerContext]::FormatSize($Ctx.TotalSizeBytes)
    }
    $w.Json($summaryEvent)

    if (-not $w.JsonMode) {
        Write-Host ""
        Write-Host ("=" * 50) -ForegroundColor Cyan
        if ($isBenchmark) {
            Write-Host "Benchmark complete!" -ForegroundColor Green
            Write-Host "  Profiles benchmarked:    $($ProfileKeys.Count) ($($ProfileKeys -join ', '))" -ForegroundColor White
        } else {
            Write-Host "Analysis complete!" -ForegroundColor Green
            Write-Host "  Profiles analyzed:       $($ProfileKeys.Count) ($($ProfileKeys -join ', '))" -ForegroundColor White
            Write-Host "  Projects found:          $($Ctx.TotalProjects)" -ForegroundColor White
            Write-Host "  Projects with artifacts: $($Ctx.TotalCleaned)" -ForegroundColor White
            Write-Host "  Projects skipped:        $($Ctx.TotalSkipped)" -ForegroundColor White
            $sizeColor = if ($Ctx.TotalSizeBytes -ge 1GB) { "Red" } elseif ($Ctx.TotalSizeBytes -ge 100MB) { "Yellow" } else { "Green" }
            Write-Host "  Total artifact size:     $([CleanerContext]::FormatSize($Ctx.TotalSizeBytes))" -ForegroundColor $sizeColor
        }
    }
}

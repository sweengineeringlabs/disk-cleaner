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

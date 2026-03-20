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

function Invoke-Analyze {
    param(
        [CleanerContext] $Ctx,
        [string[]]       $ProfileKeys,
        [TomlConfig]     $Toml
    )

    $w = $Ctx.Writer
    $w.Json(@{
        event = "start"; command = "analyze"
        profiles = @($ProfileKeys); path = $Ctx.SearchPath
    })
    $w.Text("disk-cleaner analyze - Space consumption report", "Cyan")
    $w.Text("Path: $($Ctx.SearchPath)", "DarkGray")
    $w.Text("Profiles: $($ProfileKeys -join ', ')", "DarkGray")

    $profileIdx = 0
    foreach ($profileKey in $ProfileKeys) {
        if ($Ctx.Cancelled) { break }
        $profileIdx++
        $profile = [CleanProfile]::new($profileKey, $Toml)
        $analyzer = [ArtifactAnalyzer]::new($profile, $Ctx)
        $analyzer.Run($profileIdx, $ProfileKeys.Count)
    }

    Write-Progress -Id 0 -Activity "disk-cleaner analyze" -Completed

    # Summary
    $w.Json(@{
        event = "summary"; command = "analyze"
        profiles_run = $ProfileKeys.Count
        profile_names = @($ProfileKeys)
        projects_found = $Ctx.TotalProjects
        projects_with_artifacts = $Ctx.TotalCleaned
        projects_skipped = $Ctx.TotalSkipped
        total_artifact_bytes = $Ctx.TotalSizeBytes
        total_artifact_formatted = [CleanerContext]::FormatSize($Ctx.TotalSizeBytes)
    })

    if (-not $w.JsonMode) {
        Write-Host ""
        Write-Host ("=" * 50) -ForegroundColor Cyan
        Write-Host "Analysis complete!" -ForegroundColor Green
        Write-Host "  Profiles analyzed:       $($ProfileKeys.Count) ($($ProfileKeys -join ', '))" -ForegroundColor White
        Write-Host "  Projects found:          $($Ctx.TotalProjects)" -ForegroundColor White
        Write-Host "  Projects with artifacts: $($Ctx.TotalCleaned)" -ForegroundColor White
        Write-Host "  Projects skipped:        $($Ctx.TotalSkipped)" -ForegroundColor White
        $sizeColor = if ($Ctx.TotalSizeBytes -ge 1GB) { "Red" } elseif ($Ctx.TotalSizeBytes -ge 100MB) { "Yellow" } else { "Green" }
        Write-Host "  Total artifact size:     $([CleanerContext]::FormatSize($Ctx.TotalSizeBytes))" -ForegroundColor $sizeColor
    }
}

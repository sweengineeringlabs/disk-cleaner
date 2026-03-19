# clean.ps1 - Clean feature: removes build artifacts from detected projects

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

        Write-Progress -Id 0 -Activity "disk-cleaner clean" `
            -Status "Profile $profileIndex/$profileCount : $($p.Name)" `
            -PercentComplete (($profileIndex - 1) / $profileCount * 100)

        # Scan and filter
        $foundDirs = $this.Ctx.ScanForProjects($p)
        $filtered = $this.Ctx.FilterProjects($foundDirs)
        $toClean = $filtered.ToProcess
        $skipped = $filtered.Skipped

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

function Invoke-Clean {
    param(
        [CleanerContext] $Ctx,
        [string[]]       $ProfileKeys,
        [TomlConfig]     $Toml
    )

    $w = $Ctx.Writer
    $w.Json(@{
        event = "start"; command = "clean"
        profiles = @($ProfileKeys); path = $Ctx.SearchPath
        dry_run = $Ctx.DryRun; parallel = $Ctx.Parallel
    })
    $w.Text("disk-cleaner clean - Build artifact cleaner", "Cyan")
    $w.Text("Path: $($Ctx.SearchPath)", "DarkGray")
    $w.Text("Profiles: $($ProfileKeys -join ', ')", "DarkGray")

    $profileIdx = 0
    foreach ($profileKey in $ProfileKeys) {
        if ($Ctx.Cancelled) { break }
        $profileIdx++
        $profile = [CleanProfile]::new($profileKey, $Toml)
        $cleaner = [ProfileCleaner]::new($profile, $Ctx)
        $cleaner.Run($profileIdx, $ProfileKeys.Count)
    }

    Write-Progress -Id 0 -Activity "disk-cleaner clean" -Completed

    # Summary
    $w.Json(@{
        event = "summary"; command = "clean"
        profiles_run = $ProfileKeys.Count
        profile_names = @($ProfileKeys)
        projects_found = $Ctx.TotalProjects
        projects_cleaned = $Ctx.TotalCleaned
        projects_skipped = $Ctx.TotalSkipped
        total_freed_bytes = $Ctx.TotalSizeBytes
        total_freed_formatted = [CleanerContext]::FormatSize($Ctx.TotalSizeBytes)
    })

    if (-not $w.JsonMode) {
        Write-Host ""
        Write-Host ("=" * 50) -ForegroundColor Cyan
        Write-Host "Cleaning complete!" -ForegroundColor Green
        Write-Host "  Profiles run:       $($ProfileKeys.Count) ($($ProfileKeys -join ', '))" -ForegroundColor White
        Write-Host "  Projects found:     $($Ctx.TotalProjects)" -ForegroundColor White
        Write-Host "  Projects cleaned:   $($Ctx.TotalCleaned)" -ForegroundColor White
        Write-Host "  Projects skipped:   $($Ctx.TotalSkipped)" -ForegroundColor White
        Write-Host "  Total space freed:  $([CleanerContext]::FormatSize($Ctx.TotalSizeBytes))" -ForegroundColor Green
    }
}

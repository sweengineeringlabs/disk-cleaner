# search.ps1 - Search feature: finds and reports projects without modifying them
#              Supports text/regex search within project source files via -Text

class ProjectSearcher {
    [CleanProfile]   $Profile
    [CleanerContext]  $Ctx

    ProjectSearcher([CleanProfile]$profile, [CleanerContext]$ctx) {
        $this.Profile = $profile
        $this.Ctx     = $ctx
    }

    [void] Run([int]$profileIndex, [int]$profileCount) {
        $p = $this.Profile
        $w = $this.Ctx.Writer
        $isTextSearch = -not [string]::IsNullOrEmpty($this.Ctx.TextPattern)

        $w.Json(@{ event = "scan_start"; profile = $p.Key; name = $p.Name; path = $this.Ctx.SearchPath })
        $w.BlankLine()
        $w.Text("--- $($p.Name) [$profileIndex/$profileCount] ---", "Cyan")
        if ($isTextSearch) {
            $w.Text("Searching for /$($this.Ctx.TextPattern)/ in $($p.Name) projects...", "Cyan")
        } else {
            $w.Text("Searching for $($p.Name) projects in: $($this.Ctx.SearchPath)", "Cyan")
        }

        Write-Progress -Id 0 -Activity "disk-cleaner search" `
            -Status "Profile $profileIndex/$profileCount : $($p.Name)" `
            -PercentComplete (($profileIndex - 1) / $profileCount * 100)

        # Scan and filter
        $foundDirs = $this.Ctx.ScanForProjects($p)
        $filtered = $this.Ctx.FilterProjects($foundDirs)
        $toShow = $filtered.ToProcess
        $skipped = $filtered.Skipped

        $w.Json(@{ event = "scan_complete"; profile = $p.Key; found = $foundDirs.Count; matched = $toShow.Count; skipped = $skipped.Count })

        $this.Ctx.TotalProjects += $foundDirs.Count
        $this.Ctx.TotalSkipped  += $skipped.Count

        if ($toShow.Count -eq 0) {
            $w.BlankLine()
            $w.Text("No $($p.Name) projects found.", "DarkGray")
            return
        }

        if (-not $isTextSearch) {
            $this.Ctx.TotalCleaned += $toShow.Count
            $w.BlankLine()
            $w.Text("Found $($toShow.Count) $($p.Name) projects:", "Cyan")
            $w.BlankLine()
        }

        $projectIndex = 0
        $matchedCount = 0
        foreach ($dir in $toShow) {
            if ($this.Ctx.Cancelled) { break }
            $projectIndex++
            $rel = $this.Ctx.RelativePath($dir)

            $pct = [math]::Min(100, [int]($projectIndex / $toShow.Count * 100))
            Write-Progress -Id 1 -ParentId 0 -Activity $p.Name `
                -Status "[$projectIndex/$($toShow.Count)] $rel" `
                -PercentComplete $pct

            if ($isTextSearch) {
                $matched = $this.SearchTextInProject($dir, $rel, $projectIndex, $toShow.Count)
                if ($matched) { $matchedCount++ }
            } else {
                $this.ReportProject($dir, $rel, $projectIndex, $toShow.Count)
            }
        }

        if ($isTextSearch) {
            $this.Ctx.TotalCleaned += $matchedCount
        }

        Write-Progress -Id 1 -ParentId 0 -Activity $p.Name -Completed

        if ($isTextSearch) {
            $w.BlankLine()
            $w.Text("$matchedCount/$($toShow.Count) $($p.Name) projects matched /$($this.Ctx.TextPattern)/", "Cyan")
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

    # Search source files in a project for the text pattern. Returns $true if any match found.
    hidden [bool] SearchTextInProject([string]$dir, [string]$rel, [int]$index, [int]$total) {
        $p = $this.Profile
        $w = $this.Ctx.Writer
        $pattern = $this.Ctx.TextPattern

        # Determine which extensions to search
        $extensions = $p.SourceExtensions
        if ($extensions.Count -eq 0) {
            # Fallback: search common text files
            $extensions = @(".txt", ".md", ".json", ".toml", ".yaml", ".yml", ".xml")
        }

        # Build exclude directory set
        $excludeDirs = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($d in $p.SearchExclude) { [void]$excludeDirs.Add($d) }
        # Also exclude artifact dirs by default
        if ($p.CleanDir) { [void]$excludeDirs.Add($p.CleanDir) }
        foreach ($t in $p.Targets) { [void]$excludeDirs.Add($t) }
        foreach ($t in $p.OptionalTargets) { [void]$excludeDirs.Add($t) }
        foreach ($t in $p.RecursiveTargets) { [void]$excludeDirs.Add($t) }
        # Common dirs to always skip
        foreach ($d in @(".git", ".hg", ".svn")) { [void]$excludeDirs.Add($d) }

        # Find matching files
        $matches = [System.Collections.ArrayList]::new()
        $regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        try {
            $this.SearchDirectory($dir, $dir, $extensions, $excludeDirs, $regex, $matches)
        } catch {
            # Ignore permission errors, etc.
        }

        if ($matches.Count -eq 0) {
            return $false
        }

        # Report matches
        $w.Json(@{
            event = "text_match"
            profile = $p.Key
            project = $rel
            path = $dir
            pattern = $pattern
            match_count = $matches.Count
            matches = @($matches | ForEach-Object {
                @{ file = $_.File; line = $_.Line; text = $_.Text }
            })
        })

        if (-not $w.JsonMode) {
            $w.BlankLine()
            $w.TextNoNewline("  [$index/$total] ", "DarkGray")
            $w.Text("$rel ($($matches.Count) matches)", "White")

            # Group matches by file
            $byFile = $matches | Group-Object -Property File
            foreach ($group in $byFile) {
                $fileRel = $group.Name
                $w.Text("    $fileRel", "Cyan")
                foreach ($m in $group.Group) {
                    $lineText = $m.Text
                    # Highlight the match in the line
                    $highlighted = $regex.Replace($lineText, { param($match) $match.Value })
                    $w.TextNoNewline("      $($m.Line): ", "DarkGray")
                    # Print with match highlighting
                    $parts = $regex.Split($lineText)
                    $regMatches = $regex.Matches($lineText)
                    $partIdx = 0
                    foreach ($part in $parts) {
                        $w.TextNoNewline($part, "Gray")
                        if ($partIdx -lt $regMatches.Count) {
                            $w.TextNoNewline($regMatches[$partIdx].Value, "Yellow")
                        }
                        $partIdx++
                    }
                    Write-Host ""
                }
            }
        }

        return $true
    }

    # Recursively search a directory for files matching extensions, skipping excluded dirs
    hidden [void] SearchDirectory(
        [string]$currentDir,
        [string]$projectRoot,
        [string[]]$extensions,
        [System.Collections.Generic.HashSet[string]]$excludeDirs,
        [regex]$regex,
        [System.Collections.ArrayList]$results
    ) {
        if ($this.Ctx.Cancelled) { return }

        # Check files in current directory
        try {
            foreach ($file in [System.IO.Directory]::GetFiles($currentDir)) {
                if ($this.Ctx.Cancelled) { return }
                $ext = [System.IO.Path]::GetExtension($file)
                $matchesExt = $false
                foreach ($e in $extensions) {
                    if ($ext -eq $e) { $matchesExt = $true; break }
                }
                if (-not $matchesExt) { continue }

                # Read and search file
                try {
                    $lineNum = 0
                    foreach ($line in [System.IO.File]::ReadLines($file)) {
                        $lineNum++
                        if ($regex.IsMatch($line)) {
                            $fileRel = $file.Substring($projectRoot.Length).TrimStart('\', '/')
                            [void]$results.Add([PSCustomObject]@{
                                File = $fileRel
                                Line = $lineNum
                                Text = $line.Trim()
                            })
                            # Cap at 50 matches per project to avoid flooding
                            if ($results.Count -ge 50) { return }
                        }
                    }
                } catch {
                    # Skip binary/unreadable files
                }
            }
        } catch {
            # Permission denied, etc.
        }

        # Recurse into subdirectories
        try {
            foreach ($subDir in [System.IO.Directory]::GetDirectories($currentDir)) {
                if ($this.Ctx.Cancelled) { return }
                if ($results.Count -ge 50) { return }
                $dirName = [System.IO.Path]::GetFileName($subDir)
                if ($excludeDirs.Contains($dirName)) { continue }
                $this.SearchDirectory($subDir, $projectRoot, $extensions, $excludeDirs, $regex, $results)
            }
        } catch {
            # Permission denied, etc.
        }
    }

    hidden [void] ReportProject([string]$dir, [string]$rel, [int]$index, [int]$total) {
        $p = $this.Profile
        $w = $this.Ctx.Writer

        # Collect artifact info
        $artifacts = @()
        $totalArtifactSize = [long]0

        if ($p.Type -eq "command" -and $p.CleanDir) {
            $cdp = Join-Path $dir $p.CleanDir
            $exists = Test-Path $cdp
            $sz = [long]0
            if ($exists) {
                $sz = [CleanerContext]::DirSizeBytes($cdp)
            }
            $artifacts += @{ Name = $p.CleanDir; Exists = $exists; SizeBytes = $sz }
            $totalArtifactSize += $sz
        } elseif ($p.Type -eq "remove") {
            foreach ($t in $p.Targets) {
                $tp = Join-Path $dir $t
                $exists = Test-Path $tp
                $sz = [long]0
                if ($exists) { $sz = [CleanerContext]::DirSizeBytes($tp) }
                $artifacts += @{ Name = $t; Exists = $exists; SizeBytes = $sz }
                $totalArtifactSize += $sz
            }
            foreach ($t in $p.OptionalTargets) {
                $tp = Join-Path $dir $t
                if (Test-Path $tp) {
                    $sz = [CleanerContext]::DirSizeBytes($tp)
                    $artifacts += @{ Name = $t; Exists = $true; SizeBytes = $sz }
                    $totalArtifactSize += $sz
                }
            }
            foreach ($t in $p.RecursiveTargets) {
                $rdirs = Get-ChildItem -Path $dir -Recurse -Directory -Filter $t -ErrorAction SilentlyContinue
                if ($rdirs -and $rdirs.Count -gt 0) {
                    $sz = [long]0
                    foreach ($rd in $rdirs) {
                        $sz += [CleanerContext]::DirSizeBytes($rd.FullName)
                    }
                    $artifacts += @{ Name = "$t (recursive, $($rdirs.Count) dirs)"; Exists = $true; SizeBytes = $sz }
                    $totalArtifactSize += $sz
                }
            }
        }

        $this.Ctx.TotalSizeBytes += $totalArtifactSize
        $hasArtifacts = ($artifacts | Where-Object { $_.Exists }).Count -gt 0

        # JSON output
        $w.Json(@{
            event = "search_result"
            profile = $p.Key
            project = $rel
            path = $dir
            has_artifacts = $hasArtifacts
            artifact_size_bytes = $totalArtifactSize
            artifacts = @($artifacts | ForEach-Object {
                @{ name = $_.Name; exists = $_.Exists; size_bytes = $_.SizeBytes }
            })
        })

        # Text output
        if (-not $w.JsonMode) {
            $w.TextNoNewline("  [$index/$total] ", "DarkGray")
            $w.TextNoNewline("$rel", "White")
            if ($hasArtifacts) {
                $w.Text(" ($([CleanerContext]::FormatSize($totalArtifactSize)))", "Yellow")
                foreach ($a in $artifacts) {
                    if ($a.Exists) {
                        $w.Text("    $($a.Name): $([CleanerContext]::FormatSize($a.SizeBytes))", "DarkGray")
                    }
                }
            } else {
                $w.Text(" (clean)", "Green")
            }
        }
    }
}

function Invoke-Search {
    param(
        [CleanerContext] $Ctx,
        [string[]]       $ProfileKeys,
        [TomlConfig]     $Toml
    )

    $w = $Ctx.Writer
    $isTextSearch = -not [string]::IsNullOrEmpty($Ctx.TextPattern)

    $startEvent = @{
        event = "start"; command = "search"
        profiles = @($ProfileKeys); path = $Ctx.SearchPath
    }
    if ($isTextSearch) { $startEvent["text_pattern"] = $Ctx.TextPattern }
    $w.Json($startEvent)

    if ($isTextSearch) {
        $w.Text("disk-cleaner search - Text search across projects", "Cyan")
        $w.Text("Pattern: /$($Ctx.TextPattern)/", "Yellow")
    } else {
        $w.Text("disk-cleaner search - Project finder", "Cyan")
    }
    $w.Text("Path: $($Ctx.SearchPath)", "DarkGray")
    $w.Text("Profiles: $($ProfileKeys -join ', ')", "DarkGray")

    $profileIdx = 0
    foreach ($profileKey in $ProfileKeys) {
        if ($Ctx.Cancelled) { break }
        $profileIdx++
        $profile = [CleanProfile]::new($profileKey, $Toml)
        $searcher = [ProjectSearcher]::new($profile, $Ctx)
        $searcher.Run($profileIdx, $ProfileKeys.Count)
    }

    Write-Progress -Id 0 -Activity "disk-cleaner search" -Completed

    # Summary
    $summaryEvent = @{
        event = "summary"; command = "search"
        profiles_run = $ProfileKeys.Count
        profile_names = @($ProfileKeys)
        projects_found = $Ctx.TotalProjects
        projects_matched = $Ctx.TotalCleaned
        projects_skipped = $Ctx.TotalSkipped
    }
    if ($isTextSearch) {
        $summaryEvent["text_pattern"] = $Ctx.TextPattern
    } else {
        $summaryEvent["total_artifact_bytes"] = $Ctx.TotalSizeBytes
        $summaryEvent["total_artifact_formatted"] = [CleanerContext]::FormatSize($Ctx.TotalSizeBytes)
    }
    $w.Json($summaryEvent)

    if (-not $w.JsonMode) {
        Write-Host ""
        Write-Host ("=" * 50) -ForegroundColor Cyan
        Write-Host "Search complete!" -ForegroundColor Green
        Write-Host "  Profiles searched:  $($ProfileKeys.Count) ($($ProfileKeys -join ', '))" -ForegroundColor White
        Write-Host "  Projects found:     $($Ctx.TotalProjects)" -ForegroundColor White
        Write-Host "  Projects matched:   $($Ctx.TotalCleaned)" -ForegroundColor White
        Write-Host "  Projects skipped:   $($Ctx.TotalSkipped)" -ForegroundColor White
        if ($isTextSearch) {
            Write-Host "  Pattern:            /$($Ctx.TextPattern)/" -ForegroundColor Yellow
        } else {
            Write-Host "  Total artifact size: $([CleanerContext]::FormatSize($Ctx.TotalSizeBytes))" -ForegroundColor Yellow
        }
    }
}

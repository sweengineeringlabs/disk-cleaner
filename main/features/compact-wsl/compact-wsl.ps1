# compact-wsl.ps1 - Compact WSL virtual disk files to reclaim space

class VhdxCompactor {
    [CleanerContext] $Ctx

    VhdxCompactor([CleanerContext]$ctx) {
        $this.Ctx = $ctx
    }

    [void] Run() {
        $w = $this.Ctx.Writer

        $w.Json(@{ event = "compact_start"; command = "compact-wsl"; dry_run = $this.Ctx.DryRun })

        # Check WSL availability
        $wslCmd = Get-Command wsl -ErrorAction SilentlyContinue
        if (-not $wslCmd) {
            $w.Text("WSL is not installed.", "Red")
            $w.Json(@{ event = "error"; message = "WSL not installed" })
            return
        }

        # Admin check (only needed for actual compaction)
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin -and -not $this.Ctx.DryRun) {
            $w.Text("compact-wsl requires administrator privileges (for diskpart).", "Red")
            $w.Text("Re-run in an elevated PowerShell terminal, or use -DryRun to preview.", "Yellow")
            $w.Json(@{ event = "error"; message = "requires admin" })
            return
        }

        # Discover distros
        $distroRaw = $null
        try {
            $distroRaw = wsl --list --quiet 2>$null
        } catch {}
        if (-not $distroRaw) {
            $w.Text("No WSL distributions found.", "DarkGray")
            $w.Json(@{ event = "error"; message = "no distros" })
            return
        }

        $distros = @($distroRaw | ForEach-Object { $_.Trim().Replace("`0", "") } | Where-Object { $_.Length -gt 0 })
        if ($distros.Count -eq 0) {
            $w.Text("No WSL distributions found.", "DarkGray")
            return
        }

        # Find all vhdx files
        $vhdxEntries = $this.FindVhdxFiles($distros)
        if ($vhdxEntries.Count -eq 0) {
            $w.Text("No WSL virtual disk files found.", "DarkGray")
            $w.Json(@{ event = "error"; message = "no vhdx files" })
            return
        }

        # Display what we found
        $modeLabel = if ($this.Ctx.DryRun) { " (dry run)" } else { "" }
        $w.Text("--- WSL VHDX Compaction$modeLabel ---", "Cyan")
        $w.Text("Found $($vhdxEntries.Count) virtual disk(s):", "White")
        $w.BlankLine()

        $totalBefore = [long]0
        foreach ($entry in $vhdxEntries) {
            $sizeColor = if ($entry.SizeBytes -ge 50GB) { "Red" } elseif ($entry.SizeBytes -ge 10GB) { "Yellow" } else { "White" }
            $w.Text("  $($entry.Distro)", $sizeColor)
            $w.Text("    vhdx: $([CleanerContext]::FormatSize($entry.SizeBytes))", $sizeColor)
            $w.Text("    $($entry.Path)", "DarkGray")
            $totalBefore += $entry.SizeBytes

            $w.Json(@{
                event      = "compact_target"
                distro     = $entry.Distro
                path       = $entry.Path
                size_bytes = $entry.SizeBytes
            })
        }

        $w.BlankLine()
        $w.Text("Total vhdx size: $([CleanerContext]::FormatSize($totalBefore))", "White")

        # DryRun - show what would happen and exit
        if ($this.Ctx.DryRun) {
            $w.BlankLine()
            $w.Text("Would perform:", "Cyan")
            $w.Text("  1. wsl --shutdown (terminates all running WSL processes)", "Yellow")
            $w.Text("  2. diskpart compact on $($vhdxEntries.Count) vhdx file(s)", "Yellow")
            $w.Text("  3. Report space reclaimed", "Yellow")
            $w.BlankLine()
            $w.Text("Run without -DryRun to execute (requires Administrator).", "DarkGray")
            $w.Json(@{ event = "compact_dry_run"; vhdx_count = $vhdxEntries.Count; total_bytes = $totalBefore })
            return
        }

        # Confirmation prompt
        if (-not $w.JsonMode) {
            $w.BlankLine()
            $w.Text("WARNING: This will shut down all WSL distributions.", "Yellow")
            $w.Text("Running Linux processes will be terminated.", "Yellow")
            $w.BlankLine()
            $response = Read-Host "Continue? [y/N]"
            if ($response -notmatch '^[yY]') {
                $w.Text("Cancelled.", "DarkGray")
                $w.Json(@{ event = "compact_cancelled" })
                return
            }
        }

        # Shutdown WSL
        $w.BlankLine()
        $w.Text("Shutting down WSL...", "Cyan")
        try {
            wsl --shutdown 2>$null
            Start-Sleep -Seconds 2
        } catch {
            $w.Text("Failed to shut down WSL: $_", "Red")
            $w.Json(@{ event = "error"; message = "shutdown failed" })
            return
        }
        $w.Text("WSL shut down.", "Green")

        # Compact each vhdx
        $totalReclaimed = [long]0
        foreach ($entry in $vhdxEntries) {
            if ($this.Ctx.Cancelled) { break }

            $w.BlankLine()
            $w.Text("Compacting $($entry.Distro)...", "Cyan")
            $w.Text("  $($entry.Path)", "DarkGray")

            $beforeSize = (Get-Item $entry.Path -Force).Length
            $success = $this.CompactVhdx($entry.Path)

            if ($success) {
                $afterSize = (Get-Item $entry.Path -Force).Length
                $reclaimed = $beforeSize - $afterSize

                $w.Text("  Before:    $([CleanerContext]::FormatSize($beforeSize))", "White")
                $w.Text("  After:     $([CleanerContext]::FormatSize($afterSize))", "Green")
                if ($reclaimed -gt 0) {
                    $w.Text("  Reclaimed: $([CleanerContext]::FormatSize($reclaimed))", "Green")
                    $totalReclaimed += $reclaimed
                } else {
                    $w.Text("  Reclaimed: 0 B (already compact)", "DarkGray")
                }

                $w.Json(@{
                    event          = "compact_result"
                    distro         = $entry.Distro
                    path           = $entry.Path
                    before_bytes   = $beforeSize
                    after_bytes    = $afterSize
                    reclaimed_bytes = $reclaimed
                })
            } else {
                $w.Text("  Failed to compact.", "Red")
                $w.Json(@{
                    event  = "compact_result"
                    distro = $entry.Distro
                    path   = $entry.Path
                    error  = "compact failed"
                })
            }
        }

        # Summary
        $w.BlankLine()
        Write-Host ("=" * 50) -ForegroundColor Cyan
        if ($totalReclaimed -gt 0) {
            $reclaimColor = if ($totalReclaimed -ge 1GB) { "Green" } else { "White" }
            $w.Text("Total reclaimed: $([CleanerContext]::FormatSize($totalReclaimed))", $reclaimColor)
        } else {
            $w.Text("No space reclaimed. Virtual disks were already compact.", "DarkGray")
        }

        $w.Json(@{
            event                = "compact_complete"
            total_reclaimed_bytes = $totalReclaimed
            vhdx_count           = $vhdxEntries.Count
        })
    }

    hidden [System.Collections.ArrayList] FindVhdxFiles([string[]]$distros) {
        $entries = [System.Collections.ArrayList]::new()
        $seenPaths = @{}

        $wslRoot = "$env:LOCALAPPDATA\wsl"
        $allVhdx = [System.Collections.ArrayList]::new()

        if (Test-Path $wslRoot) {
            $files = Get-ChildItem -Path $wslRoot -Recurse -Filter "ext4.vhdx" -Force -Depth 3 -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                if ($f.Length -gt 0) {
                    [void]$allVhdx.Add($f)
                }
            }
        }

        # Also check legacy Packages location
        $packagesRoot = "$env:LOCALAPPDATA\Packages"
        if (Test-Path $packagesRoot) {
            foreach ($distro in $distros) {
                $pattern = Join-Path $packagesRoot "CanonicalGroupLimited*$distro*\LocalState"
                $resolved = Resolve-Path $pattern -ErrorAction SilentlyContinue
                if ($resolved) {
                    $vf = Get-ChildItem -Path $resolved.Path -Filter "ext4.vhdx" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($vf -and $vf.Length -gt 0 -and -not $seenPaths.ContainsKey($vf.FullName)) {
                        [void]$allVhdx.Add($vf)
                    }
                }
            }
        }

        # Assign vhdx files to distros by order
        $vhdxIndex = 0
        foreach ($distro in $distros) {
            if ($vhdxIndex -ge $allVhdx.Count) { break }
            $vf = $allVhdx[$vhdxIndex]
            if (-not $seenPaths.ContainsKey($vf.FullName)) {
                [void]$entries.Add([PSCustomObject]@{
                    Distro    = $distro
                    Path      = $vf.FullName
                    SizeBytes = $vf.Length
                })
                $seenPaths[$vf.FullName] = $true
                $vhdxIndex++
            }
        }

        return $entries
    }

    hidden [bool] CompactVhdx([string]$vhdxPath) {
        $tempScript = $null
        try {
            # Build diskpart script
            $scriptContent = @"
select vdisk file="$vhdxPath"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@
            $tempScript = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $tempScript -Value $scriptContent -Encoding ASCII

            $w = $this.Ctx.Writer
            $w.Text("  Running diskpart (this may take several minutes)...", "DarkGray")

            $result = & diskpart /s $tempScript 2>&1 | Out-String
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0 -and $result -notmatch "error|failed") {
                return $true
            } else {
                $w.Text("  diskpart output: $result", "DarkGray")
                return $false
            }
        } catch {
            $this.Ctx.Writer.Text("  Error: $_", "Red")
            return $false
        } finally {
            if ($tempScript -and (Test-Path $tempScript)) {
                Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-CompactWSL {
    param(
        [CleanerContext] $Ctx
    )

    $compactor = [VhdxCompactor]::new($Ctx)
    $compactor.Run()
}

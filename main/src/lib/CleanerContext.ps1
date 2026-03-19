# CleanerContext.ps1 - Shared state for disk-cleaner operations

class CleanerContext {
    [string]       $SearchPath
    [string[]]     $ExcludePatterns
    [string[]]     $IncludePatterns
    [bool]         $CleanAll
    [bool]         $DryRun
    [bool]         $Parallel
    [bool]         $Cancelled
    [string]       $TextPattern
    [Spinner]      $Spinner
    [OutputWriter] $Writer

    # Grand totals
    [int]  $TotalProjects
    [int]  $TotalCleaned
    [int]  $TotalSkipped
    [long] $TotalSizeBytes

    CleanerContext([string]$searchPath, [string[]]$exclude, [string[]]$include,
                   [bool]$all, [bool]$dryRun, [bool]$parallel, [bool]$jsonOutput,
                   [string]$textPattern) {
        $this.SearchPath      = $searchPath
        $this.ExcludePatterns = $exclude
        $this.IncludePatterns = $include
        $this.CleanAll        = $all
        $this.DryRun          = $dryRun
        $this.Parallel        = $parallel
        $this.Cancelled       = $false
        $this.TextPattern     = $textPattern
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

    # Scan for projects matching a profile's marker files
    [System.Collections.ArrayList] ScanForProjects([CleanProfile]$profile) {
        $foundDirs = [System.Collections.ArrayList]::new()

        $this.Spinner.Start("Scanning for $($profile.Name) projects...")

        foreach ($marker in $profile.AllMarkers()) {
            if ($this.Cancelled) { $this.Spinner.Stop(); return $foundDirs }
            try {
                $enumerator = [System.IO.Directory]::EnumerateFiles(
                    $this.SearchPath, $marker, [System.IO.SearchOption]::AllDirectories
                ).GetEnumerator()
                try {
                    while ($enumerator.MoveNext()) {
                        if ($this.Cancelled) { break }
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
            if ($this.Cancelled) { break }
        }

        $this.Spinner.Stop()
        return $foundDirs
    }

    # Filter found directories into to-process and skipped lists
    [hashtable] FilterProjects([System.Collections.ArrayList]$foundDirs) {
        $toProcess = @()
        $skipped = @()
        foreach ($dir in ($foundDirs | Sort-Object)) {
            if ($this.ShouldClean($dir)) {
                $toProcess += $dir
            } else {
                $skipped += $dir
            }
        }
        return @{ ToProcess = $toProcess; Skipped = $skipped }
    }
}

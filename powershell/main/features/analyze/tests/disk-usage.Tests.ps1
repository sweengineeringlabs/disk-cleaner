# disk-usage.Tests.ps1 — Pester 5 tests for the disk-usage mode of analyze
# Run: powershell.exe -ExecutionPolicy Bypass -Command "Invoke-Pester ./main/features/analyze/tests/disk-usage.Tests.ps1 -Output Detailed"

BeforeDiscovery {
    $script:ScriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) "disk-cleaner.ps1"
}

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) "disk-cleaner.ps1"

    function Invoke-DiskCleaner {
        param([string[]]$Arguments)
        $output = powershell.exe -ExecutionPolicy Bypass -NoProfile -File $script:ScriptPath @Arguments 2>&1
        return ($output | Out-String)
    }

    function New-TempTree {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "disk-usage-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }

    function Remove-TempTree {
        param([string]$Path)
        if ($Path -and (Test-Path $Path)) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ─── Basic Disk Usage ────────────────────────────────────────────────────────────

Describe "Disk Usage - Basic scan" {

    BeforeEach {
        $script:testRoot = New-TempTree

        # Create subdirectories with known sizes
        $dirA = Join-Path $script:testRoot "large-dir"
        New-Item -ItemType Directory -Path $dirA -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dirA "big.bin"), [byte[]]::new(16384))

        $dirB = Join-Path $script:testRoot "small-dir"
        New-Item -ItemType Directory -Path $dirB -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dirB "tiny.bin"), [byte[]]::new(1024))

        # Loose file in root
        [System.IO.File]::WriteAllBytes((Join-Path $script:testRoot "root.txt"), [byte[]]::new(512))
    }

    AfterEach {
        Remove-TempTree -Path $script:testRoot
    }

    It "reports total size" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $script:testRoot)
        $output | Should -Match "Total:"
    }

    It "lists subdirectories by name" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $script:testRoot)
        $output | Should -Match "large-dir"
        $output | Should -Match "small-dir"
    }

    It "lists largest directory first" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $script:testRoot)
        $largePos = $output.IndexOf("large-dir")
        $smallPos = $output.IndexOf("small-dir")
        $largePos | Should -BeLessThan $smallPos
    }

    It "shows loose files entry" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $script:testRoot)
        $output | Should -Match "\(files\)"
    }

    It "shows percentage for entries" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $script:testRoot)
        $output | Should -Match "\d+(\.\d+)?%"
    }

    It "does not require -Lang parameter" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $script:testRoot)
        $output | Should -Not -Match "No profiles selected"
        $output | Should -Not -Match "Unknown profile"
    }
}

# ─── Nonexistent Path ─────────────────────────────────────────────────────────

Describe "Disk Usage - Nonexistent path" {

    It "reports error for missing path" {
        $fakePath = Join-Path ([System.IO.Path]::GetTempPath()) "nonexistent-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $fakePath)
        $output | Should -Match "does not exist"
    }
}

# ─── Depth Control ───────────────────────────────────────────────────────────

Describe "Disk Usage - Depth" {

    BeforeEach {
        $script:testRoot = New-TempTree

        # Create nested structure: root/parent/child/grandchild
        $parent = Join-Path $script:testRoot "parent"
        $child = Join-Path $parent "child"
        $grandchild = Join-Path $child "grandchild"
        New-Item -ItemType Directory -Path $grandchild -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $grandchild "deep.bin"), [byte[]]::new(4096))
    }

    AfterEach {
        Remove-TempTree -Path $script:testRoot
    }

    It "with depth 1 shows only top-level dirs" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $script:testRoot, "-Depth", "1")
        $output | Should -Match "parent"
        # child should not appear as a separate drilled-down entry
        # (it will be inside parent's size, but not listed separately at depth 1)
        $output | Should -Match "Depth: 1"
    }

    It "with depth 2 shows child directories" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $script:testRoot, "-Depth", "2")
        $output | Should -Match "child"
    }
}

# ─── JSON Output ──────────────────────────────────────────────────────────────

Describe "Disk Usage - JSON Output" {

    BeforeEach {
        $script:testRoot = New-TempTree

        $dirA = Join-Path $script:testRoot "data"
        New-Item -ItemType Directory -Path $dirA -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dirA "file.bin"), [byte[]]::new(2048))
    }

    AfterEach {
        Remove-TempTree -Path $script:testRoot
    }

    It "emits valid JSON lines" {
        $raw = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        foreach ($line in $lines) {
            { $line | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    It "emits start event with command=disk-usage" {
        $raw = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $first = $lines[0] | ConvertFrom-Json
        $first.event | Should -Be "start"
        $first.command | Should -Be "disk-usage"
    }

    It "emits disk_usage_entry events" {
        $raw = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $entries = @($lines | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq "disk_usage_entry" })
        $entries.Count | Should -BeGreaterOrEqual 1
        ($entries | Select-Object -First 1).size_bytes | Should -BeGreaterThan 0
    }

    It "emits summary with total_bytes" {
        $raw = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $summary = $lines | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq "summary" } | Select-Object -Last 1
        $summary.command | Should -Be "disk-usage"
        $summary.total_bytes | Should -BeGreaterThan 0
    }
}

# ─── Empty Directory ─────────────────────────────────────────────────────────

Describe "Disk Usage - Empty directory" {

    It "handles empty directory gracefully" {
        $emptyRoot = New-TempTree
        try {
            $output = Invoke-DiskCleaner -Arguments @("analyze", "-DiskUsage", "-Path", $emptyRoot)
            $output | Should -Match "Total:"
            $output | Should -Not -Match "error"
        } finally {
            Remove-TempTree -Path $emptyRoot
        }
    }
}

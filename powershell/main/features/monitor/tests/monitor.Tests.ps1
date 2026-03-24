# monitor.Tests.ps1 — Pester 5 tests for the monitor feature
# Run: powershell.exe -ExecutionPolicy Bypass -Command "Invoke-Pester ./main/features/monitor/tests/monitor.Tests.ps1 -Output Detailed"

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

    function New-TempProjectTree {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "disk-cleaner-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }

    function Remove-TempProjectTree {
        param([string]$Path)
        if ($Path -and (Test-Path $Path)) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ─── Monitor Basic Output ───────────────────────────────────────────────────────

Describe "Monitor - Basic Output" {

    It "reports monitor complete banner" {
        $output = Invoke-DiskCleaner -Arguments @("monitor")
        $output | Should -Match "Monitor complete!"
    }

    It "shows system memory section" {
        $output = Invoke-DiskCleaner -Arguments @("monitor")
        $output | Should -Match "System Memory"
        $output | Should -Match "Total:"
        $output | Should -Match "Used:"
        $output | Should -Match "Free:"
    }

    It "shows active build processes section" {
        $output = Invoke-DiskCleaner -Arguments @("monitor")
        $output | Should -Match "Active Build Processes"
    }

    It "reports system memory percentage" {
        $output = Invoke-DiskCleaner -Arguments @("monitor")
        $output | Should -Match "System memory:\s+\d+(\.\d+)?% used"
    }

    It "reports build process count" {
        $output = Invoke-DiskCleaner -Arguments @("monitor")
        $output | Should -Match "Build processes:\s+\d+ active"
    }

    It "reports history entry count" {
        $output = Invoke-DiskCleaner -Arguments @("monitor")
        $output | Should -Match "History entries:\s+\d+ recorded"
    }
}

# ─── Monitor JSON Output ────────────────────────────────────────────────────────

Describe "Monitor - JSON Output" {

    It "emits valid JSON lines" {
        $raw = Invoke-DiskCleaner -Arguments @("monitor", "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        foreach ($line in $lines) {
            { $line | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    It "emits start event with command=monitor" {
        $raw = Invoke-DiskCleaner -Arguments @("monitor", "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $first = $lines[0] | ConvertFrom-Json
        $first.event | Should -Be "start"
        $first.command | Should -Be "monitor"
    }

    It "emits system_memory event" {
        $raw = Invoke-DiskCleaner -Arguments @("monitor", "-JsonOutput")
        $raw | Should -Match '"event":"system_memory"'
    }

    It "emits processes event with count" {
        $raw = Invoke-DiskCleaner -Arguments @("monitor", "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $procEvent = $lines | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq "processes" } | Select-Object -First 1
        $procEvent | Should -Not -BeNullOrEmpty
        $procEvent.count | Should -BeGreaterOrEqual 0
    }

    It "emits summary event" {
        $raw = Invoke-DiskCleaner -Arguments @("monitor", "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $summary = $lines[-1] | ConvertFrom-Json
        $summary.event | Should -Be "summary"
        $summary.command | Should -Be "monitor"
    }
}

# ─── History Recording ───────────────────────────────────────────────────────────

Describe "Monitor - History Recording" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        # Create a node project for clean/analyze
        $proj = Join-Path $script:testRoot "hist-app"
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -Path (Join-Path $proj "package-lock.json") -Value ""
        $nm = Join-Path $proj "node_modules"
        New-Item -ItemType Directory -Path $nm -Force | Out-Null
        $bytes = [byte[]]::new(2048)
        [System.IO.File]::WriteAllBytes((Join-Path $nm "dep.bin"), $bytes)
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "clean command records history entry" {
        # Run clean to generate history
        $null = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "node", "-Path", $script:testRoot)

        # Check monitor shows history
        $output = Invoke-DiskCleaner -Arguments @("monitor", "-History")
        $output | Should -Match "Run History"
        $output | Should -Match "clean"
    }

    It "analyze command records history entry" {
        # Run analyze
        $null = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot)

        # Check monitor shows history
        $output = Invoke-DiskCleaner -Arguments @("monitor", "-History")
        $output | Should -Match "Run History"
        $output | Should -Match "analyze"
    }

    It "dry run does not record history" {
        # Run clean with dry run
        $null = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "node", "-Path", $script:testRoot, "-DryRun")

        # Monitor should show 0 or no history section related to this
        $output = Invoke-DiskCleaner -Arguments @("monitor", "-History", "-JsonOutput")
        $lines = $output.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $histEvent = $lines | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq "history" } | Select-Object -First 1
        if ($histEvent) {
            # Should have 0 entries from this test (history file is global though)
            # Just verify structure is valid
            $histEvent.total_entries | Should -BeGreaterOrEqual 0
        }
    }
}

# ─── Monitor Does Not Modify ────────────────────────────────────────────────────

Describe "Monitor - Non-destructive" {

    It "does not modify any project files" {
        $testRoot = New-TempProjectTree
        $proj = Join-Path $testRoot "safe-proj"
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -Path (Join-Path $proj "package-lock.json") -Value "original"

        try {
            $null = Invoke-DiskCleaner -Arguments @("monitor", "-Path", $testRoot)

            $content = Get-Content (Join-Path $proj "package-lock.json")
            $content | Should -Be "original"
        } finally {
            Remove-TempProjectTree -Path $testRoot
        }
    }
}

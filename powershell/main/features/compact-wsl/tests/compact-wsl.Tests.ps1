# compact-wsl.Tests.ps1 — Pester 5 tests for the compact-wsl command
# Run: powershell.exe -ExecutionPolicy Bypass -Command "Invoke-Pester ./main/features/compact-wsl/tests/compact-wsl.Tests.ps1 -Output Detailed"

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
}

# ─── DryRun Mode ──────────────────────────────────────────────────────────────

Describe "CompactWSL - DryRun" {

    It "shows dry run label" {
        $output = Invoke-DiskCleaner -Arguments @("compact-wsl", "-DryRun")
        $output | Should -Match "dry run"
    }

    It "does not shut down WSL in dry run" {
        $output = Invoke-DiskCleaner -Arguments @("compact-wsl", "-DryRun")
        $output | Should -Not -Match "Shutting down WSL"
    }

    It "shows what would be performed" {
        $output = Invoke-DiskCleaner -Arguments @("compact-wsl", "-DryRun")
        # Either shows "Would perform" steps or "No WSL" - both are valid
        $hasSteps = $output -match "Would perform"
        $noWsl = $output -match "not installed|No WSL|no vhdx"
        ($hasSteps -or $noWsl) | Should -Be $true
    }

    It "does not block on admin check in dry run" {
        $output = Invoke-DiskCleaner -Arguments @("compact-wsl", "-DryRun")
        # Dry run should show vhdx info or "no vhdx", not block with admin error
        $blocked = $output -match "^compact-wsl requires administrator"
        $blocked | Should -Be $false
    }
}

# ─── Non-Admin Detection ─────────────────────────────────────────────────────

Describe "CompactWSL - Admin check" {

    It "refuses to run without admin when not dry run" {
        # This test runs without admin, so it should be blocked
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            Set-ItResult -Skipped -Because "running as admin"
            return
        }
        $output = Invoke-DiskCleaner -Arguments @("compact-wsl")
        $output | Should -Match "requires administrator|not installed|No WSL"
    }
}

# ─── Help Integration ────────────────────────────────────────────────────────

Describe "CompactWSL - Help" {

    It "appears in help output" {
        $output = Invoke-DiskCleaner -Arguments @("help")
        $output | Should -Match "compact-wsl"
    }

    It "shows compact-wsl description in help" {
        $output = Invoke-DiskCleaner -Arguments @("help")
        $output | Should -Match "Compact WSL"
    }

    It "shows compact-wsl examples in help" {
        $output = Invoke-DiskCleaner -Arguments @("help")
        $output | Should -Match "compact-wsl -DryRun"
    }
}

# ─── JSON Output ──────────────────────────────────────────────────────────────

Describe "CompactWSL - JSON DryRun" {

    It "emits valid JSON in dry run" {
        $raw = Invoke-DiskCleaner -Arguments @("compact-wsl", "-DryRun", "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        foreach ($line in $lines) {
            { $line | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    It "emits compact_start event" {
        $raw = Invoke-DiskCleaner -Arguments @("compact-wsl", "-DryRun", "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $start = $lines[0] | ConvertFrom-Json
        $start.event | Should -Be "compact_start"
        $start.dry_run | Should -Be $true
    }
}

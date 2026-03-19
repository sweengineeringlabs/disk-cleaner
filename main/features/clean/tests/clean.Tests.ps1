# clean.Tests.ps1 — Pester 5 tests for the clean feature
# Run: powershell.exe -ExecutionPolicy Bypass -Command "Invoke-Pester ./main/features/clean/tests/clean.Tests.ps1 -Output Detailed"

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

# ─── TOML Parser Tests ──────────────────────────────────────────────────────────

Describe "TOML Parser" {

    It "parses the config file without error" {
        { Invoke-DiskCleaner -Arguments @("list-profiles") } | Should -Not -Throw
    }

    It "detects all five profiles" {
        $output = Invoke-DiskCleaner -Arguments @("list-profiles")
        $output | Should -Match "rust"
        $output | Should -Match "node"
        $output | Should -Match "java-maven"
        $output | Should -Match "java-gradle"
        $output | Should -Match "python"
    }

    It "shows profile display names" {
        $output = Invoke-DiskCleaner -Arguments @("list-profiles")
        $output | Should -Match "Rust \(Cargo\)"
        $output | Should -Match "Node\.js"
    }

    It "rejects a missing config file" {
        $output = Invoke-DiskCleaner -Arguments @("-Config", "nonexistent.toml", "list-profiles")
        $output | Should -Match "Config file not found"
    }
}

# ─── Help Output Tests ──────────────────────────────────────────────────────────

Describe "Help Output" {

    It "prints usage when -Help is passed" {
        $output = Invoke-DiskCleaner -Arguments @("-Help")
        $output | Should -Match "USAGE:"
        $output | Should -Match "COMMANDS:"
        $output | Should -Match "EXAMPLES:"
    }

    It "documents both clean and search commands" {
        $output = Invoke-DiskCleaner -Arguments @("-Help")
        $output | Should -Match "clean"
        $output | Should -Match "search"
    }

    It "documents all shared parameters" {
        $output = Invoke-DiskCleaner -Arguments @("-Help")
        $output | Should -Match "-Lang"
        $output | Should -Match "-Config"
        $output | Should -Match "-Exclude"
        $output | Should -Match "-Include"
        $output | Should -Match "-Path"
        $output | Should -Match "-All"
        $output | Should -Match "-JsonOutput"
    }
}

# ─── Profile Resolution Tests ───────────────────────────────────────────────────

Describe "Profile Resolution" {

    It "rejects an unknown profile name" {
        $output = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "nonexistent")
        $output | Should -Match "Unknown profile"
    }

    It "suggests list-profiles on unknown profile" {
        $output = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "nonexistent")
        $output | Should -Match "list-profiles"
    }
}

# ─── Scanning & Dry Run Tests ───────────────────────────────────────────────────

Describe "Clean - Scanning" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj1 = Join-Path $script:testRoot "project-alpha"
        $proj2 = Join-Path $script:testRoot "project-beta"
        New-Item -ItemType Directory -Path $proj1 -Force | Out-Null
        New-Item -ItemType Directory -Path $proj2 -Force | Out-Null
        Set-Content -Path (Join-Path $proj1 "Cargo.lock") -Value ""
        Set-Content -Path (Join-Path $proj2 "Cargo.lock") -Value ""

        $t1 = Join-Path $proj1 "target"
        $t2 = Join-Path $proj2 "target"
        New-Item -ItemType Directory -Path $t1 -Force | Out-Null
        New-Item -ItemType Directory -Path $t2 -Force | Out-Null
        Set-Content -Path (Join-Path $t1 "dummy.bin") -Value ("X" * 1024)
        Set-Content -Path (Join-Path $t2 "dummy.bin") -Value ("X" * 2048)
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "finds projects by marker file" {
        $output = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "rust", "-DryRun", "-Path", $script:testRoot)
        $output | Should -Match "Found 2 Rust \(Cargo\) projects"
    }

    It "lists projects in dry run output" {
        $output = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "rust", "-DryRun", "-Path", $script:testRoot)
        $output | Should -Match "project-alpha"
        $output | Should -Match "project-beta"
    }

    It "shows DRY RUN label" {
        $output = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "rust", "-DryRun", "-Path", $script:testRoot)
        $output | Should -Match "\[DRY RUN\]"
    }

    It "reports zero projects for empty directory" {
        $emptyRoot = New-TempProjectTree
        try {
            $output = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "rust", "-DryRun", "-Path", $emptyRoot)
            $output | Should -Match "Found 0 Rust \(Cargo\) projects"
        } finally {
            Remove-TempProjectTree -Path $emptyRoot
        }
    }
}

# ─── Include/Exclude Filter Tests ───────────────────────────────────────────────

Describe "Clean - Filters" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        foreach ($name in @("app-web", "app-api", "lib-core")) {
            $dir = Join-Path $script:testRoot $name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -Path (Join-Path $dir "Cargo.lock") -Value ""
            $target = Join-Path $dir "target"
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        }
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "excludes projects matching -Exclude pattern" {
        $output = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "rust", "-DryRun", "-Path", $script:testRoot, "-Exclude", "lib-core")
        $output | Should -Match "To clean: 2"
        $output | Should -Match "Skipped:  1"
    }

    It "includes only projects matching -Include pattern" {
        $output = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "rust", "-DryRun", "-Path", $script:testRoot, "-Include", "app-web")
        $output | Should -Match "To clean: 1"
        $output | Should -Match "Skipped:  2"
    }

    It "-All overrides exclude filters" {
        $output = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "rust", "-DryRun", "-Path", $script:testRoot, "-Exclude", "lib-core", "-All")
        $output | Should -Match "To clean: 3"
        $output | Should -Match "Skipped:  0"
    }
}

# ─── Remove-Type Profile Tests ──────────────────────────────────────────────────

Describe "Clean - Remove-type" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj = Join-Path $script:testRoot "my-app"
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -Path (Join-Path $proj "package-lock.json") -Value ""

        $nm = Join-Path $proj "node_modules"
        New-Item -ItemType Directory -Path $nm -Force | Out-Null
        Set-Content -Path (Join-Path $nm "module.js") -Value ("Y" * 512)

        $next = Join-Path $proj ".next"
        New-Item -ItemType Directory -Path $next -Force | Out-Null
        Set-Content -Path (Join-Path $next "cache.dat") -Value ("Z" * 256)
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "actually removes node_modules when not dry run" {
        $nm = Join-Path (Join-Path $script:testRoot "my-app") "node_modules"
        $nm | Should -Exist

        $null = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "node", "-Path", $script:testRoot)

        $nm | Should -Not -Exist
    }

    It "actually removes optional target .next when not dry run" {
        $next = Join-Path (Join-Path $script:testRoot "my-app") ".next"
        $next | Should -Exist

        $null = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "node", "-Path", $script:testRoot)

        $next | Should -Not -Exist
    }

    It "reports freed space after cleaning" {
        $output = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "node", "-Path", $script:testRoot)
        $output | Should -Match "freed"
    }
}

# ─── Backward Compatibility Tests ────────────────────────────────────────────────

Describe "Backward Compatibility" {

    It "defaults to clean command when no command specified" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "rust", "-DryRun", "-Path", $env:TEMP)
        $output | Should -Match "disk-cleaner clean"
    }
}

# ─── Grand Summary Tests ────────────────────────────────────────────────────────

Describe "Clean - Grand Summary" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        foreach ($name in @("p1", "p2")) {
            $dir = Join-Path $script:testRoot $name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -Path (Join-Path $dir "package-lock.json") -Value ""
            $nm = Join-Path $dir "node_modules"
            New-Item -ItemType Directory -Path $nm -Force | Out-Null
            Set-Content -Path (Join-Path $nm "file.js") -Value "x"
        }
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "prints cleaning complete banner" {
        $output = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "node", "-Path", $script:testRoot)
        $output | Should -Match "Cleaning complete!"
    }

    It "reports correct project count" {
        $output = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "node", "-Path", $script:testRoot)
        $output | Should -Match "Projects found:\s+2"
        $output | Should -Match "Projects cleaned:\s+2"
    }

    It "JSON summary has correct counts" {
        $raw = Invoke-DiskCleaner -Arguments @("clean", "-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $summary = $lines[-1] | ConvertFrom-Json
        $summary.event | Should -Be "summary"
        $summary.projects_found | Should -Be 2
        $summary.projects_cleaned | Should -Be 2
    }
}

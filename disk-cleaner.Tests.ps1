# disk-cleaner.Tests.ps1 — Pester 5 tests for disk-cleaner.ps1
# Run: powershell.exe -ExecutionPolicy Bypass -Command "Invoke-Pester ./disk-cleaner.Tests.ps1 -Output Detailed"

BeforeDiscovery {
    $script:ScriptPath = Join-Path $PSScriptRoot "disk-cleaner.ps1"
}

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot "disk-cleaner.ps1"

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

    It "parses the real config file without error" {
        { Invoke-DiskCleaner -Arguments @("-ListProfiles") } | Should -Not -Throw
    }

    It "detects all five profiles from disk-cleaner.toml" {
        $output = Invoke-DiskCleaner -Arguments @("-ListProfiles")
        $output | Should -Match "rust"
        $output | Should -Match "node"
        $output | Should -Match "java-maven"
        $output | Should -Match "java-gradle"
        $output | Should -Match "python"
    }

    It "shows profile display names" {
        $output = Invoke-DiskCleaner -Arguments @("-ListProfiles")
        $output | Should -Match "Rust \(Cargo\)"
        $output | Should -Match "Node\.js"
        $output | Should -Match "Java \(Maven\)"
        $output | Should -Match "Java \(Gradle\)"
        $output | Should -Match "Python"
    }

    It "shows marker files for each profile" {
        $output = Invoke-DiskCleaner -Arguments @("-ListProfiles")
        $output | Should -Match "Cargo\.lock"
        $output | Should -Match "package-lock\.json"
        $output | Should -Match "pom\.xml"
        $output | Should -Match "build\.gradle"
        $output | Should -Match "pyproject\.toml"
    }

    It "rejects a missing config file" {
        $output = Invoke-DiskCleaner -Arguments @("-Config", "nonexistent.toml", "-ListProfiles")
        $output | Should -Match "Config file not found"
    }
}

# ─── Help Output Tests ──────────────────────────────────────────────────────────

Describe "Help Output" {

    It "prints usage when -Help is passed" {
        $output = Invoke-DiskCleaner -Arguments @("-Help")
        $output | Should -Match "USAGE:"
        $output | Should -Match "OPTIONS:"
        $output | Should -Match "EXAMPLES:"
    }

    It "documents all parameters" {
        $output = Invoke-DiskCleaner -Arguments @("-Help")
        $output | Should -Match "-Lang"
        $output | Should -Match "-Config"
        $output | Should -Match "-ListProfiles"
        $output | Should -Match "-Exclude"
        $output | Should -Match "-Include"
        $output | Should -Match "-DryRun"
        $output | Should -Match "-Path"
        $output | Should -Match "-Parallel"
        $output | Should -Match "-All"
        $output | Should -Match "-JsonOutput"
        $output | Should -Match "-Help"
    }

    It "mentions Ctrl+C cancellation" {
        $output = Invoke-DiskCleaner -Arguments @("-Help")
        $output | Should -Match "Ctrl\+C"
    }
}

# ─── Profile Resolution Tests ───────────────────────────────────────────────────

Describe "Profile Resolution" {

    It "rejects an unknown profile name" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "nonexistent")
        $output | Should -Match "Unknown profile"
    }

    It "suggests -ListProfiles on unknown profile" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "nonexistent")
        $output | Should -Match "ListProfiles"
    }
}

# ─── Scanning & Dry Run Tests ───────────────────────────────────────────────────

Describe "Scanning" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        # Create two Rust projects
        $proj1 = Join-Path $script:testRoot "project-alpha"
        $proj2 = Join-Path $script:testRoot "project-beta"
        New-Item -ItemType Directory -Path $proj1 -Force | Out-Null
        New-Item -ItemType Directory -Path $proj2 -Force | Out-Null
        Set-Content -Path (Join-Path $proj1 "Cargo.lock") -Value ""
        Set-Content -Path (Join-Path $proj2 "Cargo.lock") -Value ""

        # Create target dirs with some content so sizes are nonzero
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
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "rust", "-DryRun", "-Path", $script:testRoot)
        $output | Should -Match "Found 2 Rust \(Cargo\) projects"
    }

    It "lists projects in dry run output" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "rust", "-DryRun", "-Path", $script:testRoot)
        $output | Should -Match "project-alpha"
        $output | Should -Match "project-beta"
    }

    It "shows DRY RUN label" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "rust", "-DryRun", "-Path", $script:testRoot)
        $output | Should -Match "\[DRY RUN\]"
    }

    It "reports target directory size in dry run" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "rust", "-DryRun", "-Path", $script:testRoot)
        $output | Should -Match "target/ size:"
    }

    It "reports zero projects for empty directory" {
        $emptyRoot = New-TempProjectTree
        try {
            $output = Invoke-DiskCleaner -Arguments @("-Lang", "rust", "-DryRun", "-Path", $emptyRoot)
            $output | Should -Match "Found 0 Rust \(Cargo\) projects"
        } finally {
            Remove-TempProjectTree -Path $emptyRoot
        }
    }
}

# ─── Include/Exclude Filter Tests ───────────────────────────────────────────────

Describe "Filters" {

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
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "rust", "-DryRun", "-Path", $script:testRoot, "-Exclude", "lib-core")
        $output | Should -Match "To clean: 2"
        $output | Should -Match "Skipped:  1"
    }

    It "excluded project appears in skipped list" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "rust", "-DryRun", "-Path", $script:testRoot, "-Exclude", "lib-core")
        $output | Should -Match "lib-core"
    }

    It "includes only projects matching -Include pattern" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "rust", "-DryRun", "-Path", $script:testRoot, "-Include", "app-web")
        $output | Should -Match "To clean: 1"
        $output | Should -Match "Skipped:  2"
    }

    It "-All overrides exclude filters" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "rust", "-DryRun", "-Path", $script:testRoot, "-Exclude", "lib-core", "-All")
        $output | Should -Match "To clean: 3"
        $output | Should -Match "Skipped:  0"
    }
}

# ─── Remove-Type Profile Tests ──────────────────────────────────────────────────

Describe "Remove-type cleaning" {

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

    It "dry run lists node_modules as target" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-DryRun", "-Path", $script:testRoot)
        $output | Should -Match "remove: node_modules"
    }

    It "dry run lists optional target .next" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-DryRun", "-Path", $script:testRoot)
        $output | Should -Match "remove: \.next"
    }

    It "actually removes node_modules when not dry run" {
        $nm = Join-Path (Join-Path $script:testRoot "my-app") "node_modules"
        $nm | Should -Exist

        $null = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-Path", $script:testRoot)

        $nm | Should -Not -Exist
    }

    It "actually removes optional target .next when not dry run" {
        $next = Join-Path (Join-Path $script:testRoot "my-app") ".next"
        $next | Should -Exist

        $null = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-Path", $script:testRoot)

        $next | Should -Not -Exist
    }

    It "reports freed space after cleaning" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-Path", $script:testRoot)
        $output | Should -Match "freed"
    }
}

# ─── JSON Output Tests ──────────────────────────────────────────────────────────

Describe "JSON Output" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj = Join-Path $script:testRoot "json-proj"
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -Path (Join-Path $proj "package-lock.json") -Value ""
        $nm = Join-Path $proj "node_modules"
        New-Item -ItemType Directory -Path $nm -Force | Out-Null
        Set-Content -Path (Join-Path $nm "pkg.js") -Value "data"
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "emits valid JSON lines" {
        $raw = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-DryRun", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        foreach ($line in $lines) {
            { $line | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    It "emits start event first" {
        $raw = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-DryRun", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $first = $lines[0] | ConvertFrom-Json
        $first.event | Should -Be "start"
    }

    It "emits summary event last" {
        $raw = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-DryRun", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $last = $lines[-1] | ConvertFrom-Json
        $last.event | Should -Be "summary"
    }

    It "emits scan_start and scan_complete events" {
        $raw = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-DryRun", "-Path", $script:testRoot, "-JsonOutput")
        $raw | Should -Match '"event":"scan_start"'
        $raw | Should -Match '"event":"scan_complete"'
    }

    It "emits dry_run event for each project in dry-run mode" {
        $raw = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-DryRun", "-Path", $script:testRoot, "-JsonOutput")
        $raw | Should -Match '"event":"dry_run"'
    }

    It "includes timestamp in every event" {
        $raw = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-DryRun", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        foreach ($line in $lines) {
            $obj = $line | ConvertFrom-Json
            $obj.timestamp | Should -Not -BeNullOrEmpty
        }
    }

    It "emits clean_complete event during actual cleaning" {
        $raw = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $raw | Should -Match '"event":"clean_complete"'
    }
}

# ─── Grand Summary Tests ────────────────────────────────────────────────────────

Describe "Grand Summary" {

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
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-Path", $script:testRoot)
        $output | Should -Match "Cleaning complete!"
    }

    It "reports correct project count" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-Path", $script:testRoot)
        $output | Should -Match "Projects found:\s+2"
        $output | Should -Match "Projects cleaned:\s+2"
    }

    It "reports total space freed" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-Path", $script:testRoot)
        $output | Should -Match "Total space freed:"
    }

    It "JSON summary has correct counts" {
        $raw = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $summary = $lines[-1] | ConvertFrom-Json
        $summary.event | Should -Be "summary"
        $summary.projects_found | Should -Be 2
        $summary.projects_cleaned | Should -Be 2
    }
}

# ─── Multi-Profile Tests ────────────────────────────────────────────────────────

Describe "Multi-Profile" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        # Rust project
        $rust = Join-Path $script:testRoot "rust-proj"
        New-Item -ItemType Directory -Path $rust -Force | Out-Null
        Set-Content -Path (Join-Path $rust "Cargo.lock") -Value ""
        New-Item -ItemType Directory -Path (Join-Path $rust "target") -Force | Out-Null

        # Node project
        $node = Join-Path $script:testRoot "node-proj"
        New-Item -ItemType Directory -Path $node -Force | Out-Null
        Set-Content -Path (Join-Path $node "package-lock.json") -Value ""
        $nm = Join-Path $node "node_modules"
        New-Item -ItemType Directory -Path $nm -Force | Out-Null
        Set-Content -Path (Join-Path $nm "f.js") -Value "x"
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "scans multiple profiles in one run" {
        $output = powershell.exe -ExecutionPolicy Bypass -NoProfile -Command "& '$script:ScriptPath' -Lang rust,node -DryRun -Path '$($script:testRoot)'" 2>&1 | Out-String
        $output | Should -Match "Rust \(Cargo\)"
        $output | Should -Match "Node\.js"
    }

    It "shows profile index counters" {
        $output = powershell.exe -ExecutionPolicy Bypass -NoProfile -Command "& '$script:ScriptPath' -Lang rust,node -DryRun -Path '$($script:testRoot)'" 2>&1 | Out-String
        $output | Should -Match "\[1/2\]"
        $output | Should -Match "\[2/2\]"
    }
}

# ─── Format-Size Tests (via JSON output) ────────────────────────────────────────

Describe "Size Formatting" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree
        $proj = Join-Path $script:testRoot "sized-proj"
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -Path (Join-Path $proj "package-lock.json") -Value ""
        $nm = Join-Path $proj "node_modules"
        New-Item -ItemType Directory -Path $nm -Force | Out-Null

        # Create a file with known size (~10 KiB)
        $bytes = [byte[]]::new(10240)
        [System.IO.File]::WriteAllBytes((Join-Path $nm "big.dat"), $bytes)
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "JSON reports size_bytes as a number" {
        $raw = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $cleanEvent = $lines | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq "clean_complete" } | Select-Object -First 1
        $cleanEvent.size_bytes | Should -Not -Be 0
        ($cleanEvent.size_bytes -is [int] -or $cleanEvent.size_bytes -is [long]) | Should -BeTrue
    }

    It "text output shows KiB for kilobyte-range sizes" {
        $output = Invoke-DiskCleaner -Arguments @("-Lang", "node", "-Path", $script:testRoot)
        $output | Should -Match "KiB"
    }
}

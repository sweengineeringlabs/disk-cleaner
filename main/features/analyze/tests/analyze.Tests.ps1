# analyze.Tests.ps1 — Pester 5 tests for the analyze feature
# Run: powershell.exe -ExecutionPolicy Bypass -Command "Invoke-Pester ./main/features/analyze/tests/analyze.Tests.ps1 -Output Detailed"

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

# ─── Analyze Discovery Tests ────────────────────────────────────────────────────

Describe "Analyze - Discovery" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        # Node project with node_modules
        $proj = Join-Path $script:testRoot "big-app"
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -Path (Join-Path $proj "package-lock.json") -Value ""
        $nm = Join-Path $proj "node_modules"
        New-Item -ItemType Directory -Path $nm -Force | Out-Null
        $bytes = [byte[]]::new(8192)
        [System.IO.File]::WriteAllBytes((Join-Path $nm "dep.bin"), $bytes)

        # Node project without artifacts
        $proj2 = Join-Path $script:testRoot "clean-app"
        New-Item -ItemType Directory -Path $proj2 -Force | Out-Null
        Set-Content -Path (Join-Path $proj2 "package-lock.json") -Value ""
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "reports analysis complete banner" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot)
        $output | Should -Match "Analysis complete!"
    }

    It "reports correct project counts" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot)
        $output | Should -Match "Projects found:\s+2"
        $output | Should -Match "Projects with artifacts:\s+1"
    }

    It "reports total artifact size" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot)
        $output | Should -Match "Total artifact size:"
    }

    It "shows project breakdown with size" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot)
        $output | Should -Match "big-app"
        $output | Should -Match "node_modules"
    }

    It "does not modify any files" {
        $nm = Join-Path (Join-Path $script:testRoot "big-app") "node_modules"
        $nm | Should -Exist

        $null = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot)

        $nm | Should -Exist
    }

    It "reports zero artifacts for clean projects only" {
        $emptyRoot = New-TempProjectTree
        $proj = Join-Path $emptyRoot "empty-proj"
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -Path (Join-Path $proj "package-lock.json") -Value ""
        try {
            $output = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $emptyRoot)
            $output | Should -Match "clean \(no artifacts\)"
        } finally {
            Remove-TempProjectTree -Path $emptyRoot
        }
    }
}

# ─── Analyze Sorts by Size ──────────────────────────────────────────────────────

Describe "Analyze - Sorting" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        # Small project
        $small = Join-Path $script:testRoot "small-app"
        New-Item -ItemType Directory -Path $small -Force | Out-Null
        Set-Content -Path (Join-Path $small "package-lock.json") -Value ""
        $nm1 = Join-Path $small "node_modules"
        New-Item -ItemType Directory -Path $nm1 -Force | Out-Null
        $bytes1 = [byte[]]::new(1024)
        [System.IO.File]::WriteAllBytes((Join-Path $nm1 "s.bin"), $bytes1)

        # Large project
        $large = Join-Path $script:testRoot "large-app"
        New-Item -ItemType Directory -Path $large -Force | Out-Null
        Set-Content -Path (Join-Path $large "package-lock.json") -Value ""
        $nm2 = Join-Path $large "node_modules"
        New-Item -ItemType Directory -Path $nm2 -Force | Out-Null
        $bytes2 = [byte[]]::new(16384)
        [System.IO.File]::WriteAllBytes((Join-Path $nm2 "l.bin"), $bytes2)
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "lists largest project first" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot)
        $largePos = $output.IndexOf("large-app")
        $smallPos = $output.IndexOf("small-app")
        $largePos | Should -BeLessThan $smallPos
    }

    It "shows percentage for each project" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot)
        $output | Should -Match "\d+(\.\d+)?%"
    }
}

# ─── Analyze Filters ────────────────────────────────────────────────────────────

Describe "Analyze - Filters" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        foreach ($name in @("app-web", "app-api", "lib-core")) {
            $dir = Join-Path $script:testRoot $name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -Path (Join-Path $dir "package-lock.json") -Value ""
            $nm = Join-Path $dir "node_modules"
            New-Item -ItemType Directory -Path $nm -Force | Out-Null
            $bytes = [byte[]]::new(512)
            [System.IO.File]::WriteAllBytes((Join-Path $nm "d.bin"), $bytes)
        }
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "respects -Exclude filter" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot, "-Exclude", "lib-core")
        $output | Should -Match "Projects with artifacts:\s+2"
    }

    It "respects -Include filter" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot, "-Include", "app-web")
        $output | Should -Match "Projects with artifacts:\s+1"
    }
}

# ─── Analyze JSON Output ────────────────────────────────────────────────────────

Describe "Analyze - JSON Output" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj = Join-Path $script:testRoot "json-proj"
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -Path (Join-Path $proj "package-lock.json") -Value ""
        $nm = Join-Path $proj "node_modules"
        New-Item -ItemType Directory -Path $nm -Force | Out-Null
        $bytes = [byte[]]::new(4096)
        [System.IO.File]::WriteAllBytes((Join-Path $nm "pkg.bin"), $bytes)
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "emits valid JSON lines" {
        $raw = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        foreach ($line in $lines) {
            { $line | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    It "emits start event with command=analyze" {
        $raw = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $first = $lines[0] | ConvertFrom-Json
        $first.event | Should -Be "start"
        $first.command | Should -Be "analyze"
    }

    It "emits analyze_result event with breakdown" {
        $raw = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $result = $lines | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq "analyze_result" } | Select-Object -First 1
        $result | Should -Not -BeNullOrEmpty
        $result.total_bytes | Should -BeGreaterThan 0
        $result.breakdown.Count | Should -BeGreaterThan 0
    }

    It "summary has projects_with_artifacts count" {
        $raw = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $summary = $lines[-1] | ConvertFrom-Json
        $summary.event | Should -Be "summary"
        $summary.command | Should -Be "analyze"
        $summary.projects_with_artifacts | Should -Be 1
    }
}

# ─── Analyze Orphaned Artifacts ──────────────────────────────────────────────────

Describe "Analyze - Orphaned artifacts" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        # Rust-like project with nested orphaned target
        $proj = Join-Path $script:testRoot "workspace-proj"
        $src = Join-Path $proj "src"
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -Path (Join-Path $proj "Cargo.lock") -Value ""

        # Root target — normal
        $target = Join-Path $proj "target"
        $debug = Join-Path $target "debug"
        New-Item -ItemType Directory -Path $debug -Force | Out-Null
        $bytes = [byte[]]::new(2048)
        [System.IO.File]::WriteAllBytes((Join-Path $debug "main.bin"), $bytes)

        # Nested orphaned target in subcrate
        $subcrate = Join-Path (Join-Path $proj "crates") "sub-crate"
        $orphanTarget = Join-Path (Join-Path $subcrate "target") "debug"
        New-Item -ItemType Directory -Path $orphanTarget -Force | Out-Null
        $bytes2 = [byte[]]::new(4096)
        [System.IO.File]::WriteAllBytes((Join-Path $orphanTarget "orphan.bin"), $bytes2)
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "detects orphaned nested target directories" {
        $output = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "rust", "-Path", $script:testRoot)
        $output | Should -Match "orphaned"
    }

    It "includes orphaned size in total" {
        $raw = Invoke-DiskCleaner -Arguments @("analyze", "-Lang", "rust", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $result = $lines | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq "analyze_result" } | Select-Object -First 1
        # Total should include both root target (2048) and orphaned (4096)
        $result.total_bytes | Should -BeGreaterOrEqual 6144
    }
}

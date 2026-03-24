# clean.int.Tests.ps1 — Integration tests for the clean feature
# Tests classes and functions in-process (dot-sourced), not via CLI invocation.
# Run: powershell.exe -ExecutionPolicy Bypass -Command "Invoke-Pester ./main/features/clean/tests/clean.int.Tests.ps1 -Output Detailed"

BeforeAll {
    $projectRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

    . (Join-Path $projectRoot "main\src\lib\TomlConfig.ps1")
    . (Join-Path $projectRoot "main\src\lib\Spinner.ps1")
    . (Join-Path $projectRoot "main\src\lib\OutputWriter.ps1")
    . (Join-Path $projectRoot "main\src\lib\CleanProfile.ps1")
    . (Join-Path $projectRoot "main\src\lib\CleanerContext.ps1")
    . (Join-Path $projectRoot "main\features\clean\clean.ps1")

    $script:ConfigPath = Join-Path $projectRoot "main\config\profiles.toml"

    function New-TempProjectTree {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "dc-int-$([guid]::NewGuid().ToString('N').Substring(0,8))"
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

# ─── TomlConfig Integration ─────────────────────────────────────────────────────

Describe "TomlConfig - profile loading" {

    It "loads all profiles from real config" {
        $toml = [TomlConfig]::new($script:ConfigPath)
        $toml.Profiles.Count | Should -Be 5
        $toml.Profiles | Should -Contain "rust"
        $toml.Profiles | Should -Contain "node"
        $toml.Profiles | Should -Contain "python"
    }

    It "reads string values correctly" {
        $toml = [TomlConfig]::new($script:ConfigPath)
        $toml.GetValue("profiles.rust.name") | Should -Be "Rust (Cargo)"
        $toml.GetValue("profiles.rust.marker") | Should -Be "Cargo.lock"
        $toml.GetValue("profiles.rust.type") | Should -Be "command"
    }

    It "reads array values correctly" {
        $toml = [TomlConfig]::new($script:ConfigPath)
        $arr = $toml.GetArray("profiles.node.alt_markers")
        $arr | Should -Contain "yarn.lock"
        $arr | Should -Contain "pnpm-lock.yaml"
    }

    It "returns empty string for missing key" {
        $toml = [TomlConfig]::new($script:ConfigPath)
        $toml.GetValue("profiles.nonexistent.name") | Should -Be ""
    }

    It "returns empty array for missing array key" {
        $toml = [TomlConfig]::new($script:ConfigPath)
        $arr = $toml.GetArray("profiles.rust.nonexistent_array")
        $arr.Count | Should -Be 0
    }
}

# ─── CleanProfile Integration ───────────────────────────────────────────────────

Describe "CleanProfile - field population" {

    BeforeAll {
        $script:toml = [TomlConfig]::new($script:ConfigPath)
    }

    It "populates command-type profile fields" {
        $p = [CleanProfile]::new("rust", $script:toml)
        $p.Key | Should -Be "rust"
        $p.Name | Should -Be "Rust (Cargo)"
        $p.Marker | Should -Be "Cargo.lock"
        $p.Type | Should -Be "command"
        $p.Command | Should -Be "cargo clean"
        $p.CleanDir | Should -Be "target"
    }

    It "populates remove-type profile fields" {
        $p = [CleanProfile]::new("node", $script:toml)
        $p.Type | Should -Be "remove"
        $p.Targets | Should -Contain "node_modules"
        $p.OptionalTargets | Should -Contain ".next"
    }

    It "populates source_extensions" {
        $p = [CleanProfile]::new("rust", $script:toml)
        $p.SourceExtensions | Should -Contain ".rs"
        $p.SourceExtensions | Should -Contain ".toml"
    }

    It "populates search_exclude" {
        $p = [CleanProfile]::new("rust", $script:toml)
        $p.SearchExclude | Should -Contain "target"
    }

    It "returns all markers including alt_markers" {
        $p = [CleanProfile]::new("node", $script:toml)
        $all = $p.AllMarkers()
        $all | Should -Contain "package-lock.json"
        $all | Should -Contain "yarn.lock"
        $all | Should -Contain "pnpm-lock.yaml"
        $all | Should -Contain "bun.lock"
    }

    It "populates python recursive_targets" {
        $p = [CleanProfile]::new("python", $script:toml)
        $p.RecursiveTargets | Should -Contain "__pycache__"
    }
}

# ─── CleanerContext - Scan + Filter Pipeline ─────────────────────────────────────

Describe "CleanerContext - scan and filter" {

    BeforeAll {
        $script:toml = [TomlConfig]::new($script:ConfigPath)
    }

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        # Create three node projects
        foreach ($name in @("app-web", "app-api", "lib-shared")) {
            $dir = Join-Path $script:testRoot $name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -Path (Join-Path $dir "package-lock.json") -Value ""
            $nm = Join-Path $dir "node_modules"
            New-Item -ItemType Directory -Path $nm -Force | Out-Null
            Set-Content -Path (Join-Path $nm "dep.js") -Value "module"
        }
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "ScanForProjects finds all projects by marker" {
        $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $true, $false, $true, "")
        $profile = [CleanProfile]::new("node", $script:toml)
        $found = $ctx.ScanForProjects($profile)
        $found.Count | Should -Be 3
    }

    It "ScanForProjects returns empty for no matches" {
        $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $true, $false, $true, "")
        $profile = [CleanProfile]::new("rust", $script:toml)
        $found = $ctx.ScanForProjects($profile)
        $found.Count | Should -Be 0
    }

    It "FilterProjects applies exclude patterns" {
        $ctx = [CleanerContext]::new($script:testRoot, @("lib-shared"), @(), $false, $true, $false, $true, "")
        $profile = [CleanProfile]::new("node", $script:toml)
        $found = $ctx.ScanForProjects($profile)
        $filtered = $ctx.FilterProjects($found)
        $filtered.ToProcess.Count | Should -Be 2
        $filtered.Skipped.Count | Should -Be 1
    }

    It "FilterProjects applies include patterns" {
        $ctx = [CleanerContext]::new($script:testRoot, @(), @("app-web"), $false, $true, $false, $true, "")
        $profile = [CleanProfile]::new("node", $script:toml)
        $found = $ctx.ScanForProjects($profile)
        $filtered = $ctx.FilterProjects($found)
        $filtered.ToProcess.Count | Should -Be 1
        $filtered.Skipped.Count | Should -Be 2
    }

    It "FilterProjects with CleanAll ignores exclude patterns" {
        $ctx = [CleanerContext]::new($script:testRoot, @("lib-shared"), @(), $true, $true, $false, $true, "")
        $profile = [CleanProfile]::new("node", $script:toml)
        $found = $ctx.ScanForProjects($profile)
        $filtered = $ctx.FilterProjects($found)
        $filtered.ToProcess.Count | Should -Be 3
        $filtered.Skipped.Count | Should -Be 0
    }

    It "RelativePath strips search path prefix" {
        $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $true, $false, $true, "")
        $full = Join-Path $script:testRoot "app-web"
        $rel = $ctx.RelativePath($full)
        $rel | Should -Be "app-web"
    }

    It "ShouldClean returns false for excluded project" {
        $ctx = [CleanerContext]::new($script:testRoot, @("app-api"), @(), $false, $true, $false, $true, "")
        $ctx.ShouldClean((Join-Path $script:testRoot "app-api")) | Should -BeFalse
        $ctx.ShouldClean((Join-Path $script:testRoot "app-web")) | Should -BeTrue
    }
}

# ─── CleanerContext - Utility Methods ────────────────────────────────────────────

Describe "CleanerContext - utilities" {

    It "FormatSize formats bytes correctly" {
        [CleanerContext]::FormatSize(0) | Should -Be "0 B"
        [CleanerContext]::FormatSize(512) | Should -Be "512 B"
        [CleanerContext]::FormatSize(1024) | Should -Be "1 KiB"
        [CleanerContext]::FormatSize(1048576) | Should -Be "1 MiB"
        [CleanerContext]::FormatSize(1073741824) | Should -Be "1 GiB"
    }

    It "FormatSize rounds to two decimal places" {
        $result = [CleanerContext]::FormatSize(1536)
        $result | Should -Be "1.5 KiB"
    }

    It "DirSizeBytes returns 0 for nonexistent path" {
        [CleanerContext]::DirSizeBytes("C:\nonexistent\path\12345") | Should -Be 0
    }

    It "DirSizeBytes measures directory content" {
        $tmpDir = New-TempProjectTree
        try {
            $bytes = [byte[]]::new(4096)
            [System.IO.File]::WriteAllBytes((Join-Path $tmpDir "data.bin"), $bytes)
            $size = [CleanerContext]::DirSizeBytes($tmpDir)
            $size | Should -Be 4096
        } finally {
            Remove-TempProjectTree -Path $tmpDir
        }
    }
}

# ─── ProfileCleaner - Remove-type Integration ───────────────────────────────────

Describe "ProfileCleaner - remove-type clean" {

    BeforeAll {
        $script:toml = [TomlConfig]::new($script:ConfigPath)
    }

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj = Join-Path $script:testRoot "test-app"
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -Path (Join-Path $proj "package-lock.json") -Value ""

        $nm = Join-Path $proj "node_modules"
        New-Item -ItemType Directory -Path $nm -Force | Out-Null
        $bytes = [byte[]]::new(2048)
        [System.IO.File]::WriteAllBytes((Join-Path $nm "dep.bin"), $bytes)

        $next = Join-Path $proj ".next"
        New-Item -ItemType Directory -Path $next -Force | Out-Null
        $bytes2 = [byte[]]::new(1024)
        [System.IO.File]::WriteAllBytes((Join-Path $next "cache.bin"), $bytes2)
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "removes target directories and tracks size" {
        $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $false, $false, $true, "")
        $profile = [CleanProfile]::new("node", $script:toml)
        $cleaner = [ProfileCleaner]::new($profile, $ctx)
        $cleaner.Run(1, 1)

        # Directories should be gone
        (Join-Path (Join-Path $script:testRoot "test-app") "node_modules") | Should -Not -Exist
        (Join-Path (Join-Path $script:testRoot "test-app") ".next") | Should -Not -Exist

        # Size should be tracked
        $ctx.TotalSizeBytes | Should -BeGreaterThan 0
        $ctx.TotalCleaned | Should -Be 1
    }

    It "dry run does not remove directories" {
        $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $true, $false, $true, "")
        $profile = [CleanProfile]::new("node", $script:toml)
        $cleaner = [ProfileCleaner]::new($profile, $ctx)
        $cleaner.Run(1, 1)

        # Directories should still exist
        (Join-Path (Join-Path $script:testRoot "test-app") "node_modules") | Should -Exist
        (Join-Path (Join-Path $script:testRoot "test-app") ".next") | Should -Exist
    }
}

# ─── Cross-feature: scan then clean on same tree ────────────────────────────────

Describe "Cross-feature - scan does not interfere with clean" {

    BeforeAll {
        $script:toml = [TomlConfig]::new($script:ConfigPath)
    }

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj = Join-Path $script:testRoot "cross-app"
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -Path (Join-Path $proj "package-lock.json") -Value ""
        $nm = Join-Path $proj "node_modules"
        New-Item -ItemType Directory -Path $nm -Force | Out-Null
        $bytes = [byte[]]::new(512)
        [System.IO.File]::WriteAllBytes((Join-Path $nm "lib.bin"), $bytes)
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "scanning first does not prevent cleaning" {
        $profile = [CleanProfile]::new("node", $script:toml)

        # First: scan (should not modify)
        $scanCtx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $true, $false, $true, "")
        $scanFound = $scanCtx.ScanForProjects($profile)
        $scanFound.Count | Should -Be 1
        (Join-Path (Join-Path $script:testRoot "cross-app") "node_modules") | Should -Exist

        # Second: clean (should remove)
        $cleanCtx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $false, $false, $true, "")
        $cleaner = [ProfileCleaner]::new($profile, $cleanCtx)
        $cleaner.Run(1, 1)
        (Join-Path (Join-Path $script:testRoot "cross-app") "node_modules") | Should -Not -Exist
        $cleanCtx.TotalCleaned | Should -Be 1
    }
}

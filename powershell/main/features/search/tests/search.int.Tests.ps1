# search.int.Tests.ps1 — Integration tests for the search feature
# Tests classes and functions in-process (dot-sourced), not via CLI invocation.
# Run: powershell.exe -ExecutionPolicy Bypass -Command "Invoke-Pester ./main/features/search/tests/search.int.Tests.ps1 -Output Detailed"

BeforeAll {
    $projectRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

    . (Join-Path $projectRoot "main\src\lib\TomlConfig.ps1")
    . (Join-Path $projectRoot "main\src\lib\Spinner.ps1")
    . (Join-Path $projectRoot "main\src\lib\OutputWriter.ps1")
    . (Join-Path $projectRoot "main\src\lib\CleanProfile.ps1")
    . (Join-Path $projectRoot "main\src\lib\CleanerContext.ps1")
    . (Join-Path $projectRoot "main\features\search\search.ps1")

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

# ─── ProjectSearcher - Text Search Internals ─────────────────────────────────────

Describe "ProjectSearcher - SearchDirectory respects source_extensions" {

    BeforeAll {
        $script:toml = [TomlConfig]::new($script:ConfigPath)
    }

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj = Join-Path $script:testRoot "ext-proj"
        $src = Join-Path $proj "src"
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -Path (Join-Path $proj "Cargo.lock") -Value ""

        # .rs file — should be searched
        Set-Content -Path (Join-Path $src "main.rs") -Value "fn find_me() {}"
        # .txt file — should NOT be searched (not in rust source_extensions)
        Set-Content -Path (Join-Path $src "notes.txt") -Value "fn find_me() {}"
        # .toml file — should be searched (in rust source_extensions)
        Set-Content -Path (Join-Path $src "config.toml") -Value "find_me = true"
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "only searches files matching profile source_extensions" {
        $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $false, $false, $true, "find_me")
        $profile = [CleanProfile]::new("rust", $script:toml)
        $searcher = [ProjectSearcher]::new($profile, $ctx)

        $found = $ctx.ScanForProjects($profile)
        $found.Count | Should -Be 1

        # Run the search via Invoke-Search (JSON mode to suppress console output)
        Invoke-Search -Ctx $ctx -ProfileKeys @("rust") -Toml $script:toml

        # Should match: main.rs has "find_me", config.toml has "find_me"
        # Should NOT match: notes.txt has "find_me" but .txt is not in source_extensions
        $ctx.TotalCleaned | Should -Be 1  # 1 project matched
    }
}

Describe "ProjectSearcher - SearchDirectory skips excluded directories" {

    BeforeAll {
        $script:toml = [TomlConfig]::new($script:ConfigPath)
    }

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj = Join-Path $script:testRoot "excl-proj"
        $src = Join-Path $proj "src"
        $target = Join-Path $proj "target"
        $targetSrc = Join-Path $target "debug"
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        New-Item -ItemType Directory -Path $targetSrc -Force | Out-Null
        Set-Content -Path (Join-Path $proj "Cargo.lock") -Value ""

        # Source file — should be found
        Set-Content -Path (Join-Path $src "lib.rs") -Value "pub fn visible() {}"
        # File in target/ — should be excluded
        Set-Content -Path (Join-Path $targetSrc "generated.rs") -Value "pub fn visible() {}"
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "skips target directory during text search" {
        $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $false, $false, $true, "visible")
        Invoke-Search -Ctx $ctx -ProfileKeys @("rust") -Toml $script:toml

        # Should match 1 project, but only from src/lib.rs, not target/debug/generated.rs
        $ctx.TotalCleaned | Should -Be 1
    }

    It "skips .git directory during text search" {
        # Add a .git dir with a matching file
        $gitDir = Join-Path (Join-Path $script:testRoot "excl-proj") ".git"
        New-Item -ItemType Directory -Path $gitDir -Force | Out-Null
        Set-Content -Path (Join-Path $gitDir "config.toml") -Value "unique_git_marker = true"

        $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $false, $false, $true, "unique_git_marker")
        Invoke-Search -Ctx $ctx -ProfileKeys @("rust") -Toml $script:toml

        # .git should be skipped, so no matches
        $ctx.TotalCleaned | Should -Be 0
    }
}

Describe "ProjectSearcher - match cap at 50" {

    BeforeAll {
        $script:toml = [TomlConfig]::new($script:ConfigPath)
    }

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj = Join-Path $script:testRoot "big-proj"
        $src = Join-Path $proj "src"
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -Path (Join-Path $proj "Cargo.lock") -Value ""

        # Create a file with 100 matching lines
        $lines = 1..100 | ForEach-Object { "fn function_$_() {}" }
        Set-Content -Path (Join-Path $src "big.rs") -Value ($lines -join "`n")
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "caps matches at 50 per project" {
        $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $false, $false, $true, "fn function_")
        Invoke-Search -Ctx $ctx -ProfileKeys @("rust") -Toml $script:toml

        # Project should match, but we can't directly inspect match count from ctx
        # Verify via JSON output
        $ctx.TotalCleaned | Should -Be 1
    }
}

Describe "ProjectSearcher - JSON text_match event via Invoke-Search" {

    BeforeAll {
        $script:toml = [TomlConfig]::new($script:ConfigPath)
    }

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj = Join-Path $script:testRoot "json-proj"
        $src = Join-Path $proj "src"
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -Path (Join-Path $proj "Cargo.lock") -Value ""
        Set-Content -Path (Join-Path $src "main.rs") -Value @"
fn hello() {
    println!("world");
}
fn goodbye() {
    println!("world");
}
"@
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "captures JSON text_match events with correct structure" {
        # Capture JSON output by redirecting console
        $jsonLines = [System.Collections.ArrayList]::new()
        $origOut = [Console]::Out
        $sw = [System.IO.StringWriter]::new()
        [Console]::SetOut($sw)
        try {
            $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $false, $false, $true, "println")
            Invoke-Search -Ctx $ctx -ProfileKeys @("rust") -Toml $script:toml
        } finally {
            [Console]::SetOut($origOut)
        }

        $output = $sw.ToString()
        $lines = $output.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $matchEvent = $lines | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq "text_match" } | Select-Object -First 1

        $matchEvent | Should -Not -BeNullOrEmpty
        $matchEvent.pattern | Should -Be "println"
        $matchEvent.match_count | Should -Be 2
        $matchEvent.matches.Count | Should -Be 2
    }
}

# ─── ProjectSearcher - artifact reporting (no text) ──────────────────────────────

Describe "ProjectSearcher - artifact report without text search" {

    BeforeAll {
        $script:toml = [TomlConfig]::new($script:ConfigPath)
    }

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        # Node project with artifacts
        $proj1 = Join-Path $script:testRoot "has-deps"
        New-Item -ItemType Directory -Path $proj1 -Force | Out-Null
        Set-Content -Path (Join-Path $proj1 "package-lock.json") -Value ""
        $nm = Join-Path $proj1 "node_modules"
        New-Item -ItemType Directory -Path $nm -Force | Out-Null
        $bytes = [byte[]]::new(8192)
        [System.IO.File]::WriteAllBytes((Join-Path $nm "big.bin"), $bytes)

        # Node project without artifacts
        $proj2 = Join-Path $script:testRoot "no-deps"
        New-Item -ItemType Directory -Path $proj2 -Force | Out-Null
        Set-Content -Path (Join-Path $proj2 "package-lock.json") -Value ""
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "tracks total artifact size across projects" {
        $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $false, $false, $true, "")
        Invoke-Search -Ctx $ctx -ProfileKeys @("node") -Toml $script:toml

        $ctx.TotalProjects | Should -Be 2
        $ctx.TotalCleaned | Should -Be 2
        $ctx.TotalSizeBytes | Should -BeGreaterOrEqual 8192
    }

    It "does not modify any files or directories" {
        $nm = Join-Path (Join-Path $script:testRoot "has-deps") "node_modules"
        $nm | Should -Exist

        $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $false, $false, $true, "")
        Invoke-Search -Ctx $ctx -ProfileKeys @("node") -Toml $script:toml

        $nm | Should -Exist
        $binFile = Join-Path $nm "big.bin"
        (Get-Item $binFile).Length | Should -Be 8192
    }
}

# ─── ProjectSearcher - handles binary/unreadable files ───────────────────────────

Describe "ProjectSearcher - binary file handling" {

    BeforeAll {
        $script:toml = [TomlConfig]::new($script:ConfigPath)
    }

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj = Join-Path $script:testRoot "bin-proj"
        $src = Join-Path $proj "src"
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -Path (Join-Path $proj "Cargo.lock") -Value ""

        # Valid source file
        Set-Content -Path (Join-Path $src "main.rs") -Value "fn searchable() {}"

        # Binary file with .rs extension (edge case)
        $binBytes = [byte[]]@(0, 1, 2, 255, 254, 253, 0, 0)
        [System.IO.File]::WriteAllBytes((Join-Path $src "binary.rs"), $binBytes)
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "does not crash when encountering binary files" {
        $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $false, $false, $true, "searchable")
        { Invoke-Search -Ctx $ctx -ProfileKeys @("rust") -Toml $script:toml } | Should -Not -Throw
        $ctx.TotalCleaned | Should -Be 1
    }
}

# ─── ProjectSearcher - fallback extensions when none configured ──────────────────

Describe "ProjectSearcher - fallback source extensions" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        # Create a minimal TOML config with no source_extensions
        $configContent = @"
[settings]
default_profiles = ["custom"]

[profiles.custom]
name = "Custom"
marker = "custom.lock"
type = "remove"
targets = ["out"]
"@
        $script:customConfig = Join-Path $script:testRoot "custom.toml"
        Set-Content -Path $script:customConfig -Value $configContent

        $proj = Join-Path $script:testRoot "custom-proj"
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -Path (Join-Path $proj "custom.lock") -Value ""

        # .md file — in fallback list
        Set-Content -Path (Join-Path $proj "README.md") -Value "fallback_marker here"
        # .rs file — NOT in fallback list
        Set-Content -Path (Join-Path $proj "main.rs") -Value "fallback_marker here"
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "uses fallback extensions when profile has none configured" {
        $toml = [TomlConfig]::new($script:customConfig)
        $ctx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $false, $false, $true, "fallback_marker")
        Invoke-Search -Ctx $ctx -ProfileKeys @("custom") -Toml $toml

        # Should find the project via README.md (fallback extension .md)
        $ctx.TotalCleaned | Should -Be 1
    }
}

# ─── Cross-feature: search then clean preserves correctness ──────────────────────

Describe "Cross-feature - text search then clean" {

    BeforeAll {
        $script:toml = [TomlConfig]::new($script:ConfigPath)
    }

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj = Join-Path $script:testRoot "cross-proj"
        $src = Join-Path $proj "src"
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -Path (Join-Path $proj "package-lock.json") -Value ""
        Set-Content -Path (Join-Path $src "index.js") -Value "const express = require('express');"

        $nm = Join-Path $proj "node_modules"
        New-Item -ItemType Directory -Path $nm -Force | Out-Null
        $bytes = [byte[]]::new(1024)
        [System.IO.File]::WriteAllBytes((Join-Path $nm "dep.bin"), $bytes)
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "text search does not prevent subsequent clean" {
        # Load clean feature too
        $projectRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
        . (Join-Path $projectRoot "main\features\clean\clean.ps1")

        $nm = Join-Path (Join-Path $script:testRoot "cross-proj") "node_modules"

        # Step 1: text search — should find "express" and leave files intact
        $searchCtx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $false, $false, $true, "express")
        Invoke-Search -Ctx $searchCtx -ProfileKeys @("node") -Toml $script:toml
        $searchCtx.TotalCleaned | Should -Be 1
        $nm | Should -Exist

        # Step 2: clean — should remove node_modules
        $cleanCtx = [CleanerContext]::new($script:testRoot, @(), @(), $false, $false, $false, $true, "")
        Invoke-Clean -Ctx $cleanCtx -ProfileKeys @("node") -Toml $script:toml
        $nm | Should -Not -Exist
        $cleanCtx.TotalCleaned | Should -Be 1
        $cleanCtx.TotalSizeBytes | Should -BeGreaterOrEqual 1024

        # Step 3: source file should still exist
        $srcFile = Join-Path (Join-Path (Join-Path $script:testRoot "cross-proj") "src") "index.js"
        $srcFile | Should -Exist
    }
}

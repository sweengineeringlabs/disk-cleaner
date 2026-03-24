# search.Tests.ps1 — Pester 5 tests for the search feature
# Run: powershell.exe -ExecutionPolicy Bypass -Command "Invoke-Pester ./main/features/search/tests/search.Tests.ps1 -Output Detailed"

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

# ─── Search Discovery Tests ─────────────────────────────────────────────────────

Describe "Search - Discovery" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        # Rust project with target
        $proj1 = Join-Path $script:testRoot "rust-proj"
        New-Item -ItemType Directory -Path $proj1 -Force | Out-Null
        Set-Content -Path (Join-Path $proj1 "Cargo.lock") -Value ""
        $t1 = Join-Path $proj1 "target"
        New-Item -ItemType Directory -Path $t1 -Force | Out-Null
        Set-Content -Path (Join-Path $t1 "binary.exe") -Value ("B" * 4096)

        # Rust project without target (clean)
        $proj2 = Join-Path $script:testRoot "rust-clean"
        New-Item -ItemType Directory -Path $proj2 -Force | Out-Null
        Set-Content -Path (Join-Path $proj2 "Cargo.lock") -Value ""
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "finds projects without modifying them" {
        $target = Join-Path (Join-Path $script:testRoot "rust-proj") "target"
        $target | Should -Exist

        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Path", $script:testRoot)

        # target should still exist — search does not delete
        $target | Should -Exist
    }

    It "reports search complete banner" {
        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Path", $script:testRoot)
        $output | Should -Match "Search complete!"
    }

    It "reports correct project count" {
        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Path", $script:testRoot)
        $output | Should -Match "Projects found:\s+2"
        $output | Should -Match "Projects matched:\s+2"
    }

    It "shows artifact size for projects with build output" {
        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Path", $script:testRoot)
        $output | Should -Match "rust-proj"
        $output | Should -Match "KiB"
    }

    It "marks clean projects as clean" {
        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Path", $script:testRoot)
        $output | Should -Match "\(clean\)"
    }

    It "reports total artifact size in summary" {
        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Path", $script:testRoot)
        $output | Should -Match "Total artifact size:"
    }
}

# ─── Search Filter Tests ────────────────────────────────────────────────────────

Describe "Search - Filters" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        foreach ($name in @("app-web", "app-api", "lib-core")) {
            $dir = Join-Path $script:testRoot $name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -Path (Join-Path $dir "Cargo.lock") -Value ""
        }
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "respects -Exclude filter in search" {
        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Path", $script:testRoot, "-Exclude", "lib-core")
        $output | Should -Match "Projects matched:\s+2"
        $output | Should -Match "Projects skipped:\s+1"
    }

    It "respects -Include filter in search" {
        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Path", $script:testRoot, "-Include", "app-web")
        $output | Should -Match "Projects matched:\s+1"
    }
}

# ─── Search Multi-Profile Tests ──────────────────────────────────────────────────

Describe "Search - Multi-Profile" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        # Rust project
        $rust = Join-Path $script:testRoot "my-rust"
        New-Item -ItemType Directory -Path $rust -Force | Out-Null
        Set-Content -Path (Join-Path $rust "Cargo.lock") -Value ""

        # Node project
        $node = Join-Path $script:testRoot "my-node"
        New-Item -ItemType Directory -Path $node -Force | Out-Null
        Set-Content -Path (Join-Path $node "package-lock.json") -Value ""
        $nm = Join-Path $node "node_modules"
        New-Item -ItemType Directory -Path $nm -Force | Out-Null
        Set-Content -Path (Join-Path $nm "pkg.js") -Value "data"
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "searches across multiple profiles" {
        $output = powershell.exe -ExecutionPolicy Bypass -NoProfile -Command "& '$script:ScriptPath' search -Lang rust,node -Path '$($script:testRoot)'" 2>&1 | Out-String
        $output | Should -Match "Rust \(Cargo\)"
        $output | Should -Match "Node\.js"
    }
}

# ─── Search JSON Output Tests ───────────────────────────────────────────────────

Describe "Search - JSON Output" {

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
        $raw = Invoke-DiskCleaner -Arguments @("search", "-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        foreach ($line in $lines) {
            { $line | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    It "emits start event with command=search" {
        $raw = Invoke-DiskCleaner -Arguments @("search", "-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $first = $lines[0] | ConvertFrom-Json
        $first.event | Should -Be "start"
        $first.command | Should -Be "search"
    }

    It "emits search_result events" {
        $raw = Invoke-DiskCleaner -Arguments @("search", "-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $raw | Should -Match '"event":"search_result"'
    }

    It "emits summary event with artifact info" {
        $raw = Invoke-DiskCleaner -Arguments @("search", "-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $summary = $lines[-1] | ConvertFrom-Json
        $summary.event | Should -Be "summary"
        $summary.command | Should -Be "search"
        $summary.projects_matched | Should -Be 1
    }

    It "includes timestamp in every event" {
        $raw = Invoke-DiskCleaner -Arguments @("search", "-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        foreach ($line in $lines) {
            $obj = $line | ConvertFrom-Json
            $obj.timestamp | Should -Not -BeNullOrEmpty
        }
    }

    It "search_result includes has_artifacts and size" {
        $raw = Invoke-DiskCleaner -Arguments @("search", "-Lang", "node", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $result = $lines | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq "search_result" } | Select-Object -First 1
        $result.has_artifacts | Should -BeTrue
        $result.artifact_size_bytes | Should -BeGreaterThan 0
    }
}

# ─── Search Does Not Modify ─────────────────────────────────────────────────────

Describe "Search - Non-destructive" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj = Join-Path $script:testRoot "safe-proj"
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Set-Content -Path (Join-Path $proj "package-lock.json") -Value ""
        $nm = Join-Path $proj "node_modules"
        New-Item -ItemType Directory -Path $nm -Force | Out-Null
        Set-Content -Path (Join-Path $nm "important.js") -Value "do not delete"
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "does not remove node_modules during search" {
        $nm = Join-Path (Join-Path $script:testRoot "safe-proj") "node_modules"
        $nm | Should -Exist

        $null = Invoke-DiskCleaner -Arguments @("search", "-Lang", "node", "-Path", $script:testRoot)

        $nm | Should -Exist
    }

    It "does not remove any files during search" {
        $file = Join-Path (Join-Path (Join-Path $script:testRoot "safe-proj") "node_modules") "important.js"
        $file | Should -Exist

        $null = Invoke-DiskCleaner -Arguments @("search", "-Lang", "node", "-Path", $script:testRoot)

        $file | Should -Exist
        (Get-Content $file) | Should -Be "do not delete"
    }
}

# ─── Text Search Tests ──────────────────────────────────────────────────────────

Describe "Search - Text Pattern" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        # Rust project with source files
        $proj = Join-Path $script:testRoot "my-crate"
        $src = Join-Path $proj "src"
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -Path (Join-Path $proj "Cargo.lock") -Value ""
        Set-Content -Path (Join-Path $src "main.rs") -Value @"
fn main() {
    println!("hello world");
}

fn helper() {
    let x = 42;
}
"@
        Set-Content -Path (Join-Path $src "lib.rs") -Value @"
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

pub async fn fetch_data() {
    todo!()
}
"@
        # Also create a target dir that should be skipped
        $target = Join-Path $proj "target"
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -Path (Join-Path $target "decoy.rs") -Value "fn main() { panic!(); }"
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "finds text matches in source files" {
        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Text", "fn main", "-Path", $script:testRoot)
        $output | Should -Match "1 matches"
        $output | Should -Match "Projects matched:\s+1"
    }

    It "reports zero matches when pattern not found" {
        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Text", "nonexistent_symbol", "-Path", $script:testRoot)
        $output | Should -Match "Projects matched:\s+0"
    }

    It "supports regex patterns" {
        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Text", "pub\s+(async\s+)?fn", "-Path", $script:testRoot)
        $output | Should -Match "matches"
        $output | Should -Match "Projects matched:\s+1"
    }

    It "skips build artifact directories during text search" {
        # target/decoy.rs has "fn main" but should be excluded
        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Text", "panic", "-Path", $script:testRoot)
        # "panic" only exists in target/decoy.rs which should be skipped
        $output | Should -Match "Projects matched:\s+0"
    }

    It "shows file path and line number for matches" {
        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Text", "fn main", "-Path", $script:testRoot)
        $output | Should -Match "src\\main\.rs"
        $output | Should -Match "\d+:.*fn main"
    }

    It "shows pattern in summary" {
        $output = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Text", "hello", "-Path", $script:testRoot)
        $output | Should -Match "Pattern:.*hello"
    }

    It "does not modify files during text search" {
        $mainRs = Join-Path (Join-Path (Join-Path $script:testRoot "my-crate") "src") "main.rs"
        $before = Get-Content $mainRs -Raw

        $null = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Text", "fn main", "-Path", $script:testRoot)

        $after = Get-Content $mainRs -Raw
        $after | Should -Be $before
    }
}

Describe "Search - Text Pattern JSON" {

    BeforeEach {
        $script:testRoot = New-TempProjectTree

        $proj = Join-Path $script:testRoot "json-crate"
        $src = Join-Path $proj "src"
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Set-Content -Path (Join-Path $proj "Cargo.lock") -Value ""
        Set-Content -Path (Join-Path $src "lib.rs") -Value @"
pub fn greet(name: &str) -> String {
    format!("Hello, {}!", name)
}
"@
    }

    AfterEach {
        Remove-TempProjectTree -Path $script:testRoot
    }

    It "emits text_match event in JSON mode" {
        $raw = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Text", "pub fn", "-Path", $script:testRoot, "-JsonOutput")
        $raw | Should -Match '"event":"text_match"'
    }

    It "text_match event includes pattern and match details" {
        $raw = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Text", "pub fn", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $match = $lines | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq "text_match" } | Select-Object -First 1
        $match.pattern | Should -Be "pub fn"
        $match.match_count | Should -BeGreaterThan 0
        $match.matches.Count | Should -BeGreaterThan 0
    }

    It "summary includes text_pattern in JSON mode" {
        $raw = Invoke-DiskCleaner -Arguments @("search", "-Lang", "rust", "-Text", "greet", "-Path", $script:testRoot, "-JsonOutput")
        $lines = $raw.Trim().Split("`n") | Where-Object { $_.Trim().Length -gt 0 }
        $summary = $lines[-1] | ConvertFrom-Json
        $summary.text_pattern | Should -Be "greet"
    }
}

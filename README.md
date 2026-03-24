# disk-cleaner

Multi-language build artifact cleaner implemented in three languages. Scans directory trees, detects projects by marker files, and manages build artifacts to free disk space.

Supports **Rust**, **Node.js**, **Java (Maven/Gradle)**, and **Python** out of the box. Extensible via shared TOML config.

## Implementations

| Directory | Language | Build | Status |
|-----------|----------|-------|--------|
| `powershell/` | PowerShell + Bash | Native | Full (all features) |
| `rust/` | Rust | `cargo build` | Full (all features) |
| `java/` | Java (justc) | `justc build` | Full (monitor/compact-wsl stubbed) |

## Commands

All three implementations support the same command set:

| Command | Description |
|---------|-------------|
| `clean` | Remove build artifacts from detected projects (default) |
| `search` | Find and report projects, with optional text search |
| `analyze` | Report disk space consumption, or generic disk usage scan |
| `monitor` | Show build process resources and run history |
| `compact-wsl` | Compact WSL virtual disks (Windows only, Admin required) |
| `list-profiles` | Show available language profiles |

## Quick Start

```powershell
# PowerShell
powershell.exe -ExecutionPolicy Bypass -File "./powershell/disk-cleaner.ps1" clean -Lang all

# Rust
cd rust && cargo run -- clean --lang all

# Java (justc)
cd java && justc build src/DiskCleaner.java -o disk-cleaner && ./disk-cleaner clean --lang all
```

## Configuration

All implementations share the same profile format defined in `powershell/main/config/profiles.toml`. Copy or symlink this file as needed.

See `powershell/README.md` for full documentation on profiles, options, JSON output, and WSL compaction.

## Project Structure

```
disk-cleaner/
  powershell/               # PowerShell + Bash implementation (primary)
    disk-cleaner.ps1        # Entry point
    main/config/profiles.toml
    main/src/lib/           # Shared classes
    main/features/          # Feature modules + tests
  rust/                     # Rust implementation
    Cargo.toml              # Workspace root
    cli/                    # Binary crate (clap CLI)
    lib/                    # Library crate (config, model, features)
  java/                     # Java implementation (justc)
    src/DiskCleaner.java    # Entry point
    src/config/             # TOML parser
    src/model/              # Profile, context
    src/features/           # Feature classes
    build.ps1 / build.sh    # Build scripts
```

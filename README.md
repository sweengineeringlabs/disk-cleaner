# disk-cleaner

Multi-language project cleaner that scans a directory tree, detects projects by marker files, and cleans build artifacts to free disk space.

Supports **Rust**, **Node.js**, **Java (Maven/Gradle)**, and **Python** out of the box. Extensible via TOML config — add new language profiles without changing the scripts.

## Quick Start

```powershell
# PowerShell (Windows)
powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang all -Path "C:\projects"

# Bash (Linux/macOS)
./bin/disk-cleaner --lang all -p ~/projects
```

## Features

- **Multi-language** — detects projects by marker files (Cargo.lock, package-lock.json, pom.xml, etc.)
- **Dry run** — preview what would be cleaned and how much space it occupies
- **Progress tracking** — animated text spinner during scanning, progress bars during cleaning, and `[N/M]` counters per project
- **Cancellable** — press Ctrl+C for instant cancellation (even mid-scan); prints a partial summary of work done so far
- **Size tracking** — measures and reports freed space per project, per profile, and grand total
- **JSON output** — structured JSON lines for programmatic consumption, logging, or piping to `jq`
- **Parallel mode** — cleans command-type profiles concurrently for faster execution
- **Include/Exclude filters** — target or skip specific projects by pattern
- **Extensible config** — add new profiles to `disk-cleaner.toml` without modifying scripts

## Usage

### PowerShell

```powershell
# Prefix all commands with: powershell.exe -ExecutionPolicy Bypass -File
powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang rust
powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang rust, node -DryRun
powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang all -DryRun -Path "C:\projects"
powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang node -Exclude myapp
powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang all -Parallel
powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -Lang all -JsonOutput
powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" -ListProfiles
```

### Bash

```bash
disk-cleaner --lang rust                              # Clean Rust projects
disk-cleaner --lang rust --lang node -d               # Dry run Rust + Node
disk-cleaner --lang all -d -p /path/to/projects       # Dry run all languages
disk-cleaner --lang node -e myapp                     # Node except myapp
disk-cleaner --lang all -P                            # Parallel cleaning
disk-cleaner --lang all --json                        # JSON event stream
disk-cleaner -L                                       # List available profiles
```

## Options

| PowerShell | Bash | Description |
|---|---|---|
| `-Lang <profile>` | `-l, --lang PROFILE` | Language profile to clean (repeatable, or `all`) |
| `-Config <file>` | `-c, --config FILE` | Path to TOML config |
| `-ListProfiles` | `-L, --list-profiles` | Show available profiles and exit |
| `-Exclude <pattern>` | `-e, --exclude PATTERN` | Exclude projects matching pattern |
| `-Include <pattern>` | `-i, --include PATTERN` | Only include projects matching pattern |
| `-DryRun` | `-d, --dry-run` | Show what would be cleaned without cleaning |
| `-Path <path>` | `-p, --path PATH` | Root path to search |
| `-Parallel` | `-P, --parallel` | Run clean operations in parallel |
| `-All` | `-a, --all` | Clean all projects, ignoring filters |
| `-JsonOutput` | `-j, --json` | Emit structured JSON lines |
| `-Help` | `-h, --help` | Show help |

## Configuration

All profiles are defined in `disk-cleaner.toml`. See the file for full field documentation.

### Profile Types

**Command profiles** run a shell command (e.g., `cargo clean`, `mvn clean`):

```toml
[profiles.rust]
name = "Rust (Cargo)"
marker = "Cargo.lock"
type = "command"
command = "cargo clean"
clean_dir = "target"             # measured for size tracking before cleaning
wrapper = "./cargo"              # optional wrapper script
```

**Remove profiles** delete directories directly:

```toml
[profiles.node]
name = "Node.js"
marker = "package-lock.json"
alt_markers = ["yarn.lock", "pnpm-lock.yaml", "bun.lock"]
type = "remove"
targets = ["node_modules"]
optional_targets = [".next", ".nuxt", "dist"]
```

### Adding a New Profile

Add a section to `disk-cleaner.toml`:

```toml
[profiles.dotnet]
name = ".NET"
marker = "*.csproj"
type = "command"
command = "dotnet clean"
clean_dir = "bin"
```

No script changes needed.

## JSON Output

Use `-JsonOutput` (PowerShell) or `--json` (bash) for structured output. Each line is a JSON object with a `timestamp` and `event` field.

### Event Types

| Event | Description | Key Fields |
|---|---|---|
| `start` | Cleaning session begins | `profiles`, `path`, `dry_run`, `parallel` |
| `scan_start` | Profile scan begins | `profile`, `name`, `path` |
| `scan_complete` | Scan finished | `profile`, `found`, `to_clean`, `skipped` |
| `dry_run` | Dry run entry | `profile`, `project`, `command` or `targets` |
| `clean_complete` | Project cleaned | `profile`, `project`, `size_bytes`, `cumulative_bytes` |
| `profile_complete` | Profile finished | `profile`, `cleaned`, `freed_bytes`, `cumulative_total_bytes` |
| `cancelled` | User pressed Ctrl+C | — |
| `summary` | Session complete | `projects_found`, `projects_cleaned`, `total_freed_bytes` |

### Example

```bash
disk-cleaner --lang node --json | jq 'select(.event == "clean_complete")'
```

## Project Structure

```
disk-cleaner/
  bin/disk-cleaner            # Bash entry point
  disk-cleaner.ps1            # PowerShell entry point
  disk-cleaner.toml           # Profile configuration
  main/src/
    clean-profile.sh          # Core cleaning logic (bash)
    lib/
      common.sh               # Shared utilities, colors, formatters
      toml-parser.sh           # Pure-bash TOML parser
```

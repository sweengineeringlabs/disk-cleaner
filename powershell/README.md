# disk-cleaner

Multi-language project workspace tool that scans directory trees, detects projects by marker files, and manages build artifacts to free disk space. Includes disk usage analysis, build process monitoring, and WSL virtual disk compaction.

Supports **Rust**, **Node.js**, **Java (Maven/Gradle)**, and **Python** out of the box. Extensible via TOML config — add new language profiles without changing the scripts.

## Quick Start

```powershell
# PowerShell — clean all build artifacts
powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" clean -Lang all -Path "C:\projects"

# PowerShell — analyze disk usage with remediation hints
powershell.exe -ExecutionPolicy Bypass -File "./disk-cleaner.ps1" analyze -DiskUsage -Path "C:\projects"

# Bash — clean all build artifacts
./bin/disk-cleaner clean --lang all -p ~/projects
```

## Commands

| Command | Description | PowerShell | Bash |
|---------|-------------|:----------:|:----:|
| `clean` | Remove build artifacts from detected projects (default) | Yes | Yes |
| `search` | Find and report projects without modifying them | Yes | Yes |
| `analyze` | Report disk space consumption by build artifacts | Yes | — |
| `monitor` | Show build process resources and run history | Yes | — |
| `compact-wsl` | Compact WSL virtual disks to reclaim space (Admin required) | Yes | — |
| `list-profiles` | Show available language profiles | Yes | Yes |

## Features

- **Multi-language** — detects projects by marker files (Cargo.lock, package-lock.json, pom.xml, etc.)
- **Dry run** — preview what would be cleaned and how much space it occupies
- **Progress tracking** — animated text spinner during scanning, progress bars during cleaning, and `[N/M]` counters per project
- **Cancellable** — press Ctrl+C for instant cancellation; prints a partial summary of work done so far
- **Size tracking** — measures and reports freed space per project, per profile, and grand total
- **JSON output** — structured JSON lines for programmatic consumption, logging, or piping to `jq`
- **Parallel mode** — cleans command-type profiles concurrently for faster execution
- **Include/Exclude filters** — target or skip specific projects by pattern
- **Extensible config** — add new profiles to `profiles.toml` without modifying scripts
- **Text search** — search for text or regex patterns within project source files
- **Disk usage analysis** — generic disk usage scanning with remediation hints for known space hogs
- **Build benchmarking** — measure and compare build times across projects
- **Process monitoring** — track CPU, memory, and runtime of build processes
- **Run history** — persistent log of past cleans and analyses (last 100 entries)
- **WSL compaction** — discover and compact WSL virtual disks with dry-run preview

## Usage

### PowerShell

```powershell
# Prefix all commands with: powershell.exe -ExecutionPolicy Bypass -File
# Clean
disk-cleaner.ps1 clean -Lang rust
disk-cleaner.ps1 clean -Lang rust, node -DryRun
disk-cleaner.ps1 clean -Lang all -DryRun -Path "C:\projects"
disk-cleaner.ps1 clean -Lang node -Exclude myapp
disk-cleaner.ps1 clean -Lang all -Parallel
disk-cleaner.ps1 clean -Lang all -JsonOutput

# Search
disk-cleaner.ps1 search -Lang all -Path "C:\projects"
disk-cleaner.ps1 search -Lang rust -Text "unsafe" -JsonOutput

# Analyze
disk-cleaner.ps1 analyze -Lang rust -Path "C:\projects"
disk-cleaner.ps1 analyze -DiskUsage -Path "C:\data"
disk-cleaner.ps1 analyze -DiskUsage -Path /tmp -Depth 3
disk-cleaner.ps1 analyze -Lang rust -Benchmark

# Monitor
disk-cleaner.ps1 monitor
disk-cleaner.ps1 monitor -History

# WSL compaction (requires elevated terminal)
disk-cleaner.ps1 compact-wsl -DryRun
disk-cleaner.ps1 compact-wsl

# Other
disk-cleaner.ps1 list-profiles
disk-cleaner.ps1 -Lang rust                    # clean is the default command
```

### Bash

```bash
# Clean
disk-cleaner clean --lang rust
disk-cleaner clean --lang rust --lang node -d
disk-cleaner clean --lang all -d -p /path/to/projects
disk-cleaner clean --lang node -e myapp
disk-cleaner clean --lang all -P
disk-cleaner clean --lang all --json

# Search
disk-cleaner search --lang all -p /path/to/projects
disk-cleaner search --lang rust --json

# Other
disk-cleaner list-profiles
disk-cleaner --lang rust                       # clean is the default command
```

## Options

### Shared Options

| PowerShell | Bash | Description |
|---|---|---|
| `-Lang <profile>` | `-l, --lang PROFILE` | Language profile to target (repeatable, or `all`) |
| `-Config <file>` | `-c, --config FILE` | Path to TOML config |
| `-ListProfiles` | `-L, --list-profiles` | Show available profiles and exit |
| `-Exclude <pattern>` | `-e, --exclude PATTERN` | Exclude projects matching pattern |
| `-Include <pattern>` | `-i, --include PATTERN` | Only include projects matching pattern |
| `-Path <path>` | `-p, --path PATH` | Root path to search |
| `-All` | `-a, --all` | Process all projects, ignoring filters |
| `-JsonOutput` | `-j, --json` | Emit structured JSON lines |
| `-Help` | `-h, --help` | Show help |

### Clean Options

| PowerShell | Bash | Description |
|---|---|---|
| `-DryRun` | `-d, --dry-run` | Show what would be cleaned without cleaning |
| `-Parallel` | `-P, --parallel` | Run clean operations in parallel |

### Search Options (PowerShell only)

| PowerShell | Description |
|---|---|
| `-Text <pattern>` | Search for text or regex pattern within project source files |

### Analyze Options (PowerShell only)

| PowerShell | Description |
|---|---|
| `-DiskUsage` | Generic disk usage scan — no profile required. Shows drive capacity, system/hidden files, and remediation hints |
| `-Depth <n>` | Directory depth for `-DiskUsage` (default: 2) |
| `-Benchmark` | Benchmark build times instead of measuring disk space |

### Monitor Options (PowerShell only)

| PowerShell | Description |
|---|---|
| `-History` | Show run history only (past cleans and analyses) |

## Configuration

All profiles are defined in `main/config/profiles.toml`. See the file for full field documentation.

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

Add a section to `main/config/profiles.toml`:

```toml
[profiles.dotnet]
name = ".NET"
marker = "global.json"
alt_markers = ["Directory.Build.props"]
type = "command"
command = "dotnet clean"
clean_dir = "bin"
```

No script changes needed.

## JSON Output

Use `-JsonOutput` (PowerShell) or `--json` (Bash) for structured output. Each line is a JSON object with a `timestamp` and `event` field.

### Event Types

| Event | Description | Key Fields |
|---|---|---|
| `start` | Session begins | `command`, `profiles`, `path`, `dry_run`, `parallel` |
| `scan_start` | Profile scan begins | `profile`, `name`, `path` |
| `scan_complete` | Scan finished | `profile`, `found`, `to_clean`, `skipped` |
| `dry_run` | Dry run entry | `profile`, `project`, `command` or `targets` |
| `clean_complete` | Project cleaned | `profile`, `project`, `size_bytes`, `cumulative_bytes` |
| `profile_complete` | Profile finished | `profile`, `cleaned`, `freed_bytes`, `cumulative_total_bytes` |
| `cancelled` | User pressed Ctrl+C | — |
| `summary` | Session complete | `projects_found`, `projects_cleaned`, `total_freed_bytes` |

### Example

```bash
disk-cleaner clean --lang node --json | jq 'select(.event == "clean_complete")'
```

### WSL Compaction

The `compact-wsl` command requires an **elevated (Administrator) PowerShell terminal**. The script checks for admin privileges and exits with an error if not elevated — it cannot self-elevate interactively.

```powershell
# From an elevated PowerShell terminal:
disk-cleaner.ps1 compact-wsl -DryRun    # preview what would be compacted
disk-cleaner.ps1 compact-wsl            # compact all WSL virtual disks
```

**Manual alternative** — if you prefer not to run the script as Administrator, or need to compact a specific VHDX file directly:

```powershell
# 1. Shut down WSL
wsl --shutdown

# 2. Open an elevated PowerShell (right-click > Run as Administrator)
#    and run diskpart interactively:
diskpart

# 3. Inside diskpart, run these commands:
#    select vdisk file="C:\Users\<you>\AppData\Local\wsl\<distro-id>\ext4.vhdx"
#    attach vdisk readonly
#    compact vdisk
#    detach vdisk
#    exit
```

To find your VHDX paths, use `-DryRun` (which does not require admin):

```powershell
disk-cleaner.ps1 compact-wsl -DryRun
```

## Project Structure

```
disk-cleaner/
  disk-cleaner.ps1                    # PowerShell entry point
  bin/disk-cleaner                    # Bash entry point
  main/
    config/
      profiles.toml                   # Language profile configuration
      history.json                    # Run history (generated)
    src/lib/
      CleanerContext.ps1              # OOP context class
      CleanProfile.ps1                # Profile abstraction
      OutputWriter.ps1                # JSON/colored text output
      Spinner.ps1                     # Progress spinner
      TomlConfig.ps1                  # TOML parser (PowerShell)
      common.sh                       # Shared utilities (Bash)
      toml-parser.sh                  # TOML parser (Bash)
    features/
      clean/
        clean.ps1                     # Artifact cleaning (PowerShell)
        clean.sh                      # Artifact cleaning (Bash)
        tests/                        # Pester unit + integration tests
      search/
        search.ps1                    # Project search (PowerShell)
        search.sh                     # Project search (Bash)
        tests/                        # Pester unit + integration tests
      analyze/
        analyze.ps1                   # Disk space analysis (PowerShell only)
        tests/                        # Pester unit + integration tests
      monitor/
        monitor.ps1                   # Process monitoring (PowerShell only)
        tests/                        # Pester unit tests
      compact-wsl/
        compact-wsl.ps1               # WSL disk compaction (PowerShell only)
        tests/                        # Pester unit tests
  docs/
    executive-summary.md              # One-page project overview
    0-ideation/research/              # Research notes
```

## Supported Languages

| Language | Detection Marker(s) | Clean Strategy |
|----------|-------------------|----------------|
| Rust | `Cargo.lock` | `cargo clean` |
| Node.js | `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock` | Remove `node_modules`, `.next`, `.nuxt`, `dist` |
| Java (Maven) | `pom.xml` | `mvn clean` (supports `mvnw` wrapper) |
| Java (Gradle) | `build.gradle`, `build.gradle.kts` | `gradle clean` (supports `gradlew` wrapper) |
| Python | `pyproject.toml`, `setup.py`, `requirements.txt` | Remove `.venv`, `venv`, `__pycache__`, `.mypy_cache`, `.pytest_cache`, `.ruff_cache`, `dist`, `build` |

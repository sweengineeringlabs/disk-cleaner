# Executive Summary

## disk-cleaner

### Problem

Software development projects accumulate large build artifacts — compiled binaries, dependency caches, and intermediate outputs — that consume significant disk space. In a multi-project workspace, these artifacts can grow to tens of gigabytes without the developer noticing, degrading system performance and exhausting storage.

Manually cleaning each project is tedious: different languages use different build systems (`cargo clean`, `mvn clean`, deleting `node_modules`), and a workspace may contain dozens of projects across multiple languages.

### Solution

**disk-cleaner** is a configurable, multi-language build artifact cleaner. It recursively scans a directory tree, detects projects by marker files (e.g., `Cargo.lock`, `package-lock.json`, `pom.xml`), and cleans their build outputs — either by running the language's native clean command or by directly removing known artifact directories.

### Supported Languages

| Language | Detection | Clean Strategy |
|----------|-----------|----------------|
| Rust | `Cargo.lock` | `cargo clean` |
| Node.js | `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock` | Remove `node_modules`, `.next`, `.nuxt`, `dist` |
| Java (Maven) | `pom.xml` | `mvn clean` (supports `mvnw` wrapper) |
| Java (Gradle) | `build.gradle`, `build.gradle.kts` | `gradle clean` (supports `gradlew` wrapper) |
| Python | `pyproject.toml`, `setup.py`, `requirements.txt` | Remove `.venv`, `__pycache__`, `.mypy_cache`, etc. |

New languages can be added via the TOML configuration file without modifying any code.

### Key Capabilities

- **Dry run mode** — preview what would be cleaned and estimated space savings before committing
- **Include/Exclude filters** — target or skip specific projects by pattern
- **Parallel execution** — clean multiple projects concurrently
- **Instant cancellation** — Ctrl+C stops immediately with a partial summary of work done
- **Space tracking** — reports freed space per project, per language profile, and grand total
- **JSON output** — structured event stream for automation, logging, or integration with other tools

### Implementations

Two parallel implementations share a single TOML configuration:

- **PowerShell** (`disk-cleaner.ps1`) — primary implementation for Windows
- **Bash** (`bin/disk-cleaner`) — implementation for Linux/macOS

### Typical Impact

In a workspace with 74 Rust projects, a single run freed **~10 GiB** of disk space. Across all supported languages in a mixed workspace, savings of 10-30 GiB are common.

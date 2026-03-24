#!/bin/bash
# Build disk-cleaner Java implementation using justc.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JUSTC="${JUSTC:-justc}"

echo "Building disk-cleaner (Java/justc)..."

"$JUSTC" build "$SCRIPT_DIR/src/DiskCleaner.java" -o "$SCRIPT_DIR/disk-cleaner"

echo "Build complete: disk-cleaner"

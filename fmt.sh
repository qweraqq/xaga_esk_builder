#!/usr/bin/env bash
set -euo pipefail

# Check for shfmt command
command -v shfmt > /dev/null || {
    echo "shfmt not found"
    exit 127
}

# Format all scripts
mapfile -t scripts < <(git ls-files '*.sh')
shfmt -w -i 4 -ci -bn -sr "${scripts[@]}"

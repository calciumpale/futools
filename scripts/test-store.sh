#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
temporary_dir="$(mktemp -d -t promptdock-library-checks)"
trap 'rm -f "$temporary_dir/check-library"; rmdir "$temporary_dir"' EXIT

swiftc -swift-version 5 \
    "$project_dir/Sources/PromptDock/GlobalHotKey.swift" \
    "$project_dir/Sources/PromptDock/PromptStore.swift" \
    "$project_dir/Tests/PromptStoreChecks.swift" \
    -o "$temporary_dir/check-library"
"$temporary_dir/check-library"

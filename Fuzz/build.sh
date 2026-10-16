#!/usr/bin/env bash
# Builds the libFuzzer target (Linux, e.g. inside swift:6.4-noble).
# Output: Fuzz/.build/jp2k-fuzz
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
out_dir="$repo_root/Fuzz/.build"
mkdir -p "$out_dir"

sources=()
while IFS= read -r file; do
    sources+=("$file")
done < <(find "$repo_root/Sources/JP2K" -name '*.swift' | LC_ALL=C sort)

swiftc -swift-version 6 -parse-as-library -O -g \
    -sanitize=fuzzer,address \
    -module-name JP2KFuzz \
    "${sources[@]}" "$repo_root/Fuzz/JP2KFuzz/main.swift" \
    -o "$out_dir/jp2k-fuzz"
echo "built $out_dir/jp2k-fuzz"

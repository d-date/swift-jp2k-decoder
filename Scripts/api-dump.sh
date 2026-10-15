#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
mkdir -p .build/module-cache .build/cache

# SwiftPM writes the graph below its build directory and prints its location.
log_file=$(mktemp)
trap 'rm -f "$log_file"' EXIT
CLANG_MODULE_CACHE_PATH="$repo_root/.build/module-cache" \
    swift package --disable-sandbox --cache-path "$repo_root/.build/cache" \
    dump-symbol-graph --minimum-access-level public > "$log_file"
# SwiftPM prints "Files written to <dir>"; read JP2K.symbols.json from that dir.
graph_dir=$(sed -n 's/^Files written to //p' "$log_file" | tail -n 1)
graph_path=""
if [ -n "$graph_dir" ] && [ -f "$graph_dir/JP2K.symbols.json" ]; then
    graph_path="$graph_dir/JP2K.symbols.json"
fi
if [ -z "$graph_path" ] || [ ! -f "$graph_path" ]; then
    cat "$log_file" >&2
    echo "JP2K symbol graph was not generated" >&2
    exit 1
fi

python3 - "$graph_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as graph_file:
    graph = json.load(graph_file)

lines = []
for symbol in graph["symbols"]:
    path = ".".join(symbol["pathComponents"])
    declaration = "".join(
        fragment["spelling"] for fragment in symbol.get("declarationFragments", [])
    )
    lines.append(f"{path} | {declaration}")
for line in sorted(lines):
    print(line)
PY

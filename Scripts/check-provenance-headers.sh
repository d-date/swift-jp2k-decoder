#!/usr/bin/env bash
# Verifies that every Swift file marked "Ported from OpenJPEG v2.5.4: <file>.c"
# carries exactly the copyright lines of the referenced OpenJPEG sources.
# Usage: check-provenance-headers.sh [--fix]   (needs .reference/openjpeg)
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
source_root="${OPJ_SRC:-$repo_root/.reference/openjpeg}/src"
source_dir="$source_root/lib/openjp2"
if [[ ! -d "$source_dir" ]]; then
    echo "OpenJPEG source not found at $source_dir (set OPJ_SRC)" >&2
    exit 2
fi

python3 -I - "$repo_root" "$source_root" "${1:-}" <<'PY'
import pathlib, re, sys

repo, source_root, mode = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
copyright = re.compile(r"^ \* Copyright \(c\)")

def holders(c_file):
    source_file = source_root / ("bin/common" if c_file == "color.c" else "lib/openjp2") / c_file
    lines = source_file.read_text(encoding="utf-8", errors="replace").splitlines()
    return [line for line in lines[:60] if copyright.match(line)]

failed = False
for path in sorted((repo / "Sources").rglob("*.swift")):
    text = path.read_text(encoding="utf-8")
    marker = re.search(r"Ported from OpenJPEG v2\.5\.4: (.*)", text)
    if not marker:
        continue
    expected = []
    for c_file in re.findall(r"([A-Za-z0-9_]+\.c):", marker.group(1)):
        for line in holders(c_file):
            if line not in expected:
                expected.append(line)
    lines = text.splitlines()
    current = [i for i, line in enumerate(lines) if copyright.match(line)]
    if [lines[i] for i in current] == expected:
        continue
    if mode == "--fix" and current:
        first, last = current[0], current[-1]
        lines[first:last + 1] = expected
        path.write_text("\n".join(lines).rstrip("\n") + "\n", encoding="utf-8")
        print(f"fixed {path.relative_to(repo)}")
    else:
        print(f"mismatch {path.relative_to(repo)}", file=sys.stderr)
        failed = True
sys.exit(1 if failed else 0)
PY

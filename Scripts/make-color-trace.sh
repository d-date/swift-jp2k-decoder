#!/usr/bin/env bash
# Prints the first ten RGB pixels and the SHA-256 of the full PPM pixel data
# from OpenJPEG v2.5.4 output for the sYCC and palette conformance inputs.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
data_root=${JP2K_CONFORMANCE_DIR:-$repo_root/.reference/openjpeg-data}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
for name in file2 file3 file9; do
    opj_decompress -i "$data_root/input/conformance/$name.jp2" -o "$work_dir/$name.ppm" > /dev/null 2>&1
    python3 -I - "$work_dir/$name.ppm" "$name" <<'PY'
from pathlib import Path
import sys
import hashlib
raw = Path(sys.argv[1]).read_bytes()
if b"# OpenJPEG-2.5.4\n" not in raw[:64]:
    raise SystemExit("opj_decompress must be OpenJPEG v2.5.4")
start = raw.index(b"255\n") + 4
print(sys.argv[2], list(raw[start:start + 30]), hashlib.sha256(raw[start:]).hexdigest())
PY
done

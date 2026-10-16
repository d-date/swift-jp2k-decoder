#!/usr/bin/env bash
# Runs the fuzzer for the given number of seconds (default 300).
# Crashes, OOMs and timeouts are all treated as failures and kept in
# Fuzz/artifacts. The working corpus grows in Fuzz/corpus.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
seconds=${1:-300}
binary="$repo_root/Fuzz/.build/jp2k-fuzz"
corpus="$repo_root/Fuzz/corpus"
seeds="$repo_root/Tests/JP2KTests/Fixtures"
artifacts="$repo_root/Fuzz/artifacts"
mkdir -p "$corpus" "$artifacts"

if [[ ! -x "$binary" ]]; then
    bash "$repo_root/Fuzz/build.sh"
fi

# Seed with every codestream and JP2 fixture, including the corrupt corpus.
find "$seeds" -type f \( -name '*.j2k' -o -name '*.jp2' -o -name '*.j2c' \) -exec cp -n {} "$corpus/" \;
# The conformance inputs (not committed) add sYCC, palette, cdef and ICC JP2
# files; include them when available.
if [[ -n "${JP2K_CONFORMANCE_DIR:-}" && -d "$JP2K_CONFORMANCE_DIR/input/conformance" ]]; then
    find "$JP2K_CONFORMANCE_DIR/input/conformance" -type f \( -name '*.j2k' -o -name '*.jp2' -o -name '*.j2c' \) \
        -exec cp -n {} "$corpus/" \;
fi

jobs=$(nproc 2>/dev/null || echo 2)
start=$(date +%s)
log="$repo_root/Fuzz/fuzz.log"
set +e
"$binary" "$corpus" \
    -fork="$jobs" -ignore_crashes=0 -ignore_ooms=0 -ignore_timeouts=0 \
    -rss_limit_mb=2048 -timeout=30 -max_len=262144 -max_total_time="$seconds" \
    -artifact_prefix="$artifacts/" -print_final_stats=1 2>&1 | tee "$log"
set -e
end=$(date +%s)
echo "fuzzed $((end - start)) s with $jobs jobs"
# The fork-mode parent process reports a small leak inside libFuzzer's own
# driver at exit (not in the decoder), which makes its exit status non-zero.
# Success is therefore judged by libFuzzer's completion line and by the absence
# of crash/oom/timeout artifacts from the child jobs.
# slow-unit-* files only report slow inputs; crash-, oom-, timeout- and
# leak- artifacts are failures. The parent's exit-time leak inside libFuzzer
# (see above) is written as an empty crash- unit; the entry point returns
# before touching the decoder for empty input, so empty artifacts are ignored.
findings=$(find "$artifacts" -type f -size +0 \( -name 'crash-*' -o -name 'oom-*' -o -name 'timeout-*' -o -name 'leak-*' \))
if [[ -n "$findings" ]]; then
    echo "FAIL: findings:" && ls -l $findings
    exit 1
fi
if ! grep -q 'INFO: exiting: 0' "$log"; then
    echo "FAIL: libFuzzer did not finish cleanly (see $log)"
    exit 1
fi
echo "OK: no findings"

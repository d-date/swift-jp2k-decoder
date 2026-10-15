#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

cp "$repo_root/Tests/LintSelfTest/Violations.swift.txt" "$work_dir/Violations.swift"
# Use the repository rules while directing the self-test at its temporary input.
awk -v path="$work_dir/Violations.swift" '
    /^included:/ { print "included: [\"" path "\"]"; next }
    { print }
' "$repo_root/.swiftlint.yml" > "$work_dir/config.yml"

set +e
swiftlint lint --strict --config "$work_dir/config.yml" > "$work_dir/lint.log" 2>&1
lint_status=$?
set -e

cat "$work_dir/lint.log"
if [ "$lint_status" -eq 0 ]; then
    echo "Expected SwiftLint to reject the deliberate violations" >&2
    exit 1
fi

# Each forbidden form sits on its own line of the fixture; every line must be
# reported by the expected rule so a regex regression for one form is caught.
expected="
2 no_unsafe
6 force_unwrapping
7 force_try
8 force_cast
9 no_fatal_error
10 no_precondition
11 no_precondition
12 no_precondition
13 no_precondition
14 no_unsafe
15 no_unsafe
16 no_unsafe
"
failed=0
while read -r line rule; do
    [ -z "$line" ] && continue
    if ! grep -E "Violations\.swift:$line:[0-9]+:.*\($rule\)" "$work_dir/lint.log" > /dev/null; then
        echo "SwiftLint did not report $rule on fixture line $line" >&2
        failed=1
    fi
done <<< "$expected"
if [ "$failed" -ne 0 ]; then
    exit 1
fi

echo "SwiftLint self-test passed"

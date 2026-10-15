#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <architecture>-unknown-linux-android28" >&2
    exit 2
fi
triple=$1
case "$triple" in
    x86_64-unknown-linux-android28) architecture=x86_64; ndk_arch=x86_64 ;;
    aarch64-unknown-linux-android28) architecture=aarch64; ndk_arch=aarch64 ;;
    *) echo "Unsupported Android target: $triple" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
sdk_id=${SWIFT_ANDROID_SDK_ID:-$(swift sdk list | sed -n '/_android$/ { p; q; }')}
if [[ -z "$sdk_id" ]]; then
    echo "No Swift Android SDK is installed" >&2
    exit 1
fi

swift build --build-tests --swift-sdk "$sdk_id" --triple "$triple"
bin_path=$(swift build --show-bin-path --swift-sdk "$sdk_id" --triple "$triple")
# The native build system emits JP2KTests.xctest (an ELF executable); the
# Swift Build backend (default on macOS hosts) emits a test-runner executable
# that loads JP2KTests.so from its own directory.
test_files=()
if [[ -f "$bin_path/JP2KTests.xctest" ]]; then
    test_executable="$bin_path/JP2KTests.xctest"
elif [[ -f "$bin_path/JP2KTests-test-runner" && -f "$bin_path/JP2KTests.so" ]]; then
    test_executable="$bin_path/JP2KTests-test-runner"
    test_files+=("$bin_path/JP2KTests.so")
else
    echo "No Android test executable found in $bin_path" >&2
    exit 1
fi

sdk_roots=("${SWIFT_SDKS_DIR:-}" "$HOME/Library/org.swift.swiftpm/swift-sdks" "$HOME/.swiftpm/swift-sdks" "$HOME/.local/share/swift-sdks")
sdk_bundle=""
for root in "${sdk_roots[@]}"; do
    if [[ -n "$root" && -d "$root/$sdk_id.artifactbundle" ]]; then
        sdk_bundle="$root/$sdk_id.artifactbundle"
        break
    fi
done
if [[ -z "$sdk_bundle" ]]; then
    sdk_bundle=$(find "$HOME/.local/share" -maxdepth 5 -type d -name "$sdk_id.artifactbundle" -print -quit 2>/dev/null || true)
fi
if [[ -z "$sdk_bundle" ]]; then
    echo "Cannot find the installed SDK bundle for $sdk_id; set SWIFT_SDKS_DIR" >&2
    exit 1
fi
runtime="$sdk_bundle/swift-android/swift-resources/usr/lib/swift-$architecture/android"
if [[ ! -f "$runtime/libswiftCore.so" || ! -f "$runtime/libTesting.so" ]]; then
    echo "Missing Android Swift runtime in $runtime" >&2
    exit 1
fi

ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
if [[ -z "$ndk" ]]; then
    android_sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
    ndk=$(find "$android_sdk/ndk" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -V | tail -n 1)
fi
if [[ -z "$ndk" ]]; then
    echo "Android NDK not found; set ANDROID_NDK_HOME" >&2
    exit 1
fi
libcxx=$(find "$ndk/toolchains/llvm/prebuilt" -path "*/sysroot/usr/lib/$ndk_arch-linux-android/libc++_shared.so" -print -quit)
if [[ -z "$libcxx" ]]; then
    echo "libc++_shared.so not found in $ndk" >&2
    exit 1
fi

if ! adb devices | grep -q '^emulator-[0-9][0-9]*[[:space:]]*device$' && [[ -z ${ANDROID_SERIAL:-} ]]; then
    echo "No running emulator found (or set ANDROID_SERIAL)" >&2
    exit 1
fi
remote=/data/local/tmp/jp2k
adb shell "rm -rf $remote && mkdir -p $remote/lib $remote/Fixtures"
adb push "$test_executable" "$remote/tests.xctest" >/dev/null
for file in "${test_files[@]+"${test_files[@]}"}"; do
    adb push "$file" "$remote/" >/dev/null
done
adb push "$runtime/." "$remote/lib/" >/dev/null
adb push "$libcxx" "$remote/lib/libc++_shared.so" >/dev/null
adb push Tests/JP2KTests/Fixtures/. "$remote/Fixtures/" >/dev/null
# The suites use Swift Testing, which the runner only executes when asked.
# adb shell does not reliably propagate the exit status, so echo it and parse.
output=$(adb shell "chmod 755 $remote/tests.xctest; LD_LIBRARY_PATH=$remote:$remote/lib JP2K_FIXTURES_DIR=$remote/Fixtures $remote/tests.xctest --testing-library swift-testing 2>&1; echo jp2k-exit=\$?" | tr -d '\r')
echo "$output"
status=$(sed -n 's/^jp2k-exit=//p' <<< "$output" | tail -n 1)
if [[ "$status" != 0 ]]; then
    echo "Android tests failed (exit ${status:-unknown})" >&2
    exit 1
fi
if ! grep -Eq 'Test run with [1-9][0-9]* tests? .*passed' <<< "$output"; then
    echo "Android run did not report any passing Swift Testing tests" >&2
    exit 1
fi

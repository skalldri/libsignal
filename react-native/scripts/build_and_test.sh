#!/usr/bin/env bash
#
# Build testing binaries and run the full test suite on a connected Android emulator.
#
# This builds libsignal_ffi.so with the testing feature enabled (required for
# async tests), bundles the JS, builds the debug APK, installs it, and streams
# test results from logcat.
#
# Prerequisites:
#   - Rust + cargo-ndk + Android NDK
#   - Connected Android emulator or device (adb devices must show a device)
#   - npm dependencies installed (cd react-native && npm install)
#
# Usage:
#   ./scripts/build_and_test.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${RN_DIR}/.." && pwd)"

APP_PACKAGE="com.libsignaltestapp"

# ABIs required by the example app
ABIS=("x86_64-linux-android" "aarch64-linux-android")
ABI_DIRS=("x86_64" "arm64-v8a")

echo "============================================"
echo "  libsignal RN — Build & Test (Emulator)"
echo "============================================"
echo ""

# --- Step 0: Verify emulator is connected ---
echo "Step 0: Checking for connected device..."
if ! adb get-state >/dev/null 2>&1; then
    echo "ERROR: No Android device/emulator connected. Start one first." >&2
    exit 1
fi
echo "  ✓ Device connected"
echo ""

# --- Step 1: Build native .so with testing feature ---
echo "Step 1: Building libsignal_ffi.so with testing feature..."
FFI_CRATE="${REPO_ROOT}/rust/bridge/ffi"
for i in "${!ABIS[@]}"; do
    target="${ABIS[$i]}"
    abi="${ABI_DIRS[$i]}"
    echo "  Building ${target} (${abi})..."
    cd "${REPO_ROOT}"
    cargo ndk --target "${target}" \
        --manifest-path "${FFI_CRATE}/Cargo.toml" \
        -- build --features libsignal-bridge-testing --lib 2>&1 \
        | grep -E '(Compiling|Finished)' || true
    # Copy from target dir (cargo ndk -o can silently use stale copies)
    mkdir -p "${RN_DIR}/android/jniLibs/${abi}"
    cp "${REPO_ROOT}/target/${target}/debug/libsignal_ffi.so" \
       "${RN_DIR}/android/jniLibs/${abi}/libsignal_ffi.so"
done
echo "  ✓ Native libraries built"
echo ""

# Verify testing symbols are present
# Note: grep -c instead of grep -q to avoid SIGPIPE with pipefail
for i in "${!ABIS[@]}"; do
    abi="${ABI_DIRS[$i]}"
    SO="${RN_DIR}/android/jniLibs/${abi}/libsignal_ffi.so"
    MATCHES=$(nm -D "${SO}" 2>/dev/null | grep -c signal_testing_tokio_async_future || true)
    if [[ "${MATCHES}" -eq 0 ]]; then
        echo "ERROR: ${SO} is missing testing symbols!" >&2
        echo "  This means cargo used a cached build without --features libsignal-bridge-testing." >&2
        echo "  Run: cargo clean --target ${ABIS[$i]} && re-run this script." >&2
        exit 1
    fi
done
echo "  ✓ Testing symbols verified"
echo ""

# --- Step 2: Generate C++ header ---
echo "Step 2: Generating C++ header..."
cp "${REPO_ROOT}/swift/Sources/SignalFfi/signal_ffi.h" "${RN_DIR}/cpp/signal_ffi.h"
python3 "${RN_DIR}/scripts/patch_header_cpp.py" \
    "${RN_DIR}/cpp/signal_ffi.h" \
    "${RN_DIR}/cpp/signal_ffi_cpp.h"
echo "  ✓ signal_ffi_cpp.h generated"
echo ""

# --- Step 3: Compile TypeScript ---
echo "Step 3: Compiling TypeScript..."
cd "${RN_DIR}"
npx tsc 2>&1
echo "  ✓ TypeScript compiled"
echo ""

# --- Step 4: Bundle JS ---
echo "Step 4: Bundling JS for APK..."
cd "${RN_DIR}/example"
mkdir -p android/app/src/main/assets
npx react-native bundle \
    --platform android \
    --dev false \
    --entry-file index.js \
    --bundle-output android/app/src/main/assets/index.android.bundle \
    --assets-dest android/app/src/main/res/ 2>&1 | grep -v "^$" || true
echo "  ✓ JS bundle created"
echo ""

# --- Step 5: Build debug APK ---
echo "Step 5: Building debug APK (this may take several minutes)..."
cd "${RN_DIR}/example/android"
./gradlew assembleDebug 2>&1 | tail -3
echo "  ✓ APK built"
echo ""

# --- Step 6: Install and run ---
echo "Step 6: Installing and launching test app..."
APK="${RN_DIR}/example/android/app/build/outputs/apk/debug/app-debug.apk"
adb install -r "${APK}" 2>&1
adb logcat -c
adb shell am force-stop "${APP_PACKAGE}" 2>/dev/null || true
sleep 1
adb shell am start -n "${APP_PACKAGE}/.MainActivity" 2>&1
echo ""

# --- Step 7: Collect results ---
echo "Step 7: Waiting for test results..."
TIMEOUT=60
ELAPSED=0
RESULTS=""
while [[ $ELAPSED -lt $TIMEOUT ]]; do
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    RESULTS=$(adb logcat -d -s ReactNativeJS 2>&1 | grep "libsignal-test" || true)
    if echo "$RESULTS" | grep -q "passed.*failed"; then
        break
    fi
done

if [[ -z "$RESULTS" ]]; then
    echo "ERROR: No test output received within ${TIMEOUT}s" >&2
    echo "Check: adb logcat -s ReactNativeJS" >&2
    exit 1
fi

echo ""
echo "============================================"
echo "  Test Results"
echo "============================================"
echo "$RESULTS" | sed 's/.*ReactNativeJS: //'
echo ""

# Parse pass/fail counts
SUMMARY=$(echo "$RESULTS" | grep "passed.*failed" | head -1 | sed 's/.*ReactNativeJS: \[libsignal-test\] //')
FAILED=$(echo "$SUMMARY" | grep -oP '\d+ failed' | grep -oP '\d+')

if [[ "${FAILED:-0}" -gt 0 ]]; then
    echo "❌ ${SUMMARY}"
    exit 1
else
    echo "✅ ${SUMMARY}"
    exit 0
fi

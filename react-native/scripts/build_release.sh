#!/usr/bin/env bash
#
# Build release binaries for all Android ABIs.
#
# Produces stripped, release-optimized libsignal_ffi.so for all 4 standard
# Android architectures, generates the C++ header, and compiles TypeScript.
# The output is ready for AAR packaging or direct inclusion.
#
# Prerequisites:
#   - Rust + cargo-ndk + Android NDK
#   - Rust targets installed:
#       rustup target add aarch64-linux-android armv7-linux-androideabi \
#                         x86_64-linux-android i686-linux-android
#   - npm dependencies installed (cd react-native && npm install)
#
# Usage:
#   ./scripts/build_release.sh
#
# Output:
#   android/jniLibs/{arm64-v8a,armeabi-v7a,x86_64,x86}/libsignal_ffi.so
#   cpp/signal_ffi_cpp.h
#   lib/  (compiled TypeScript)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${RN_DIR}/.." && pwd)"

echo "============================================"
echo "  libsignal RN — Release Build"
echo "============================================"
echo ""

# --- Step 1: Build all 4 ABIs ---
echo "Step 1: Building release native libraries (all ABIs)..."
"${SCRIPT_DIR}/build_android.sh" --release --strip
echo ""

# --- Step 2: Verify outputs ---
echo "Step 2: Verifying outputs..."
EXPECTED_ABIS=("arm64-v8a" "armeabi-v7a" "x86_64" "x86")
for abi in "${EXPECTED_ABIS[@]}"; do
    SO="${RN_DIR}/android/jniLibs/${abi}/libsignal_ffi.so"
    if [[ ! -f "${SO}" ]]; then
        echo "ERROR: Missing ${SO}" >&2
        exit 1
    fi
    SIZE=$(stat -c%s "${SO}" 2>/dev/null || stat -f%z "${SO}")
    echo "  ✓ ${abi}/libsignal_ffi.so ($(( SIZE / 1024 / 1024 ))MB)"
done
echo ""

# Verify NO testing symbols in release (these should not be present)
for abi in "${EXPECTED_ABIS[@]}"; do
    SO="${RN_DIR}/android/jniLibs/${abi}/libsignal_ffi.so"
    MATCHES=$(nm -D "${SO}" 2>/dev/null | grep -c signal_testing_tokio_async_future || true)
    if [[ "${MATCHES}" -gt 0 ]]; then
        echo "WARNING: ${abi}/libsignal_ffi.so contains testing symbols — this is a release build!" >&2
    fi
done

# --- Step 3: Compile TypeScript ---
echo "Step 3: Compiling TypeScript..."
cd "${RN_DIR}"
npx tsc 2>&1
echo "  ✓ TypeScript compiled to lib/"
echo ""

echo "============================================"
echo "  Release build complete!"
echo "============================================"
echo ""
echo "Artifacts:"
echo "  Native:  react-native/android/jniLibs/<abi>/libsignal_ffi.so"
echo "  Header:  react-native/cpp/signal_ffi_cpp.h"
echo "  JS/TS:   react-native/lib/"

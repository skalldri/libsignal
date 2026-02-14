#!/usr/bin/env bash
#
# Builds libsignal_ffi.a for iOS targets (device + simulator).
#
# Prerequisites:
#   - Rust toolchain with iOS targets:
#       rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#   - Xcode command line tools
#
# Usage:
#   ./scripts/build_ios.sh [--release]
#
# Output:
#   ios/libsignal_ffi.a (universal fat binary)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${RN_DIR}/.." && pwd)"
FFI_CRATE="${REPO_ROOT}/rust/bridge/ffi"

BUILD_TYPE="debug"
CARGO_PROFILE=""
if [[ "${1:-}" == "--release" ]]; then
    BUILD_TYPE="release"
    CARGO_PROFILE="--release"
fi

IOS_TARGETS=(
    "aarch64-apple-ios"
    "aarch64-apple-ios-sim"
    "x86_64-apple-ios"
)

# iOS-specific environment (mirrors swift/build_ffi.sh)
export IPHONEOS_DEPLOYMENT_TARGET=15

echo "Building libsignal_ffi for iOS (${BUILD_TYPE})..."

BUILT_LIBS=()
for target in "${IOS_TARGETS[@]}"; do
    echo "  Building for ${target}..."

    # Set RUSTFLAGS per-target to match upstream build
    TARGET_RUSTFLAGS="--cfg aes_armv8 --cfg tokio_unstable"

    # Features: enable testing for non-device targets
    FEATURES_ARG=""
    if [[ "${target}" != "aarch64-apple-ios" ]]; then
        FEATURES_ARG="--features libsignal-bridge-testing"
    fi

    CARGO_BUILD_TARGET="${target}" RUSTFLAGS="${TARGET_RUSTFLAGS}" \
    cargo build ${CARGO_PROFILE} \
        --manifest-path "${FFI_CRATE}/Cargo.toml" \
        --target "${target}" \
        ${FEATURES_ARG} \
        --lib

    LIB_FILE="${REPO_ROOT}/target/${target}/${BUILD_TYPE}/libsignal_ffi.a"
    if [[ ! -f "${LIB_FILE}" ]]; then
        echo "ERROR: Expected ${LIB_FILE} not found" >&2
        exit 1
    fi
    BUILT_LIBS+=("${LIB_FILE}")
done

# Create a universal (fat) library using lipo
echo "Creating universal library..."
mkdir -p "${RN_DIR}/ios"

# Separate device and simulator libs for xcframework-compatible approach
DEVICE_LIB="${REPO_ROOT}/target/aarch64-apple-ios/${BUILD_TYPE}/libsignal_ffi.a"
SIM_LIBS=()
for target in "aarch64-apple-ios-sim" "x86_64-apple-ios"; do
    SIM_LIBS+=("${REPO_ROOT}/target/${target}/${BUILD_TYPE}/libsignal_ffi.a")
done

# Create fat simulator lib (use same binary name as device for XCFramework compatibility)
SIM_FAT_DIR="${RN_DIR}/ios/.sim_staging"
rm -rf "${SIM_FAT_DIR}"
mkdir -p "${SIM_FAT_DIR}"
lipo -create "${SIM_LIBS[@]}" -output "${SIM_FAT_DIR}/libsignal_ffi.a"

# Copy device lib
cp "${DEVICE_LIB}" "${RN_DIR}/ios/libsignal_ffi.a"

echo "  Device lib: ios/libsignal_ffi.a"
echo "  Simulator lib: (staged for XCFramework)"

# Create XCFramework for clean device/simulator resolution
echo "Creating XCFramework..."
XCFW="${RN_DIR}/ios/libsignal_ffi.xcframework"
rm -rf "${XCFW}"

# Create temporary header directories for the XCFramework
HEADER_DIR_DEVICE="${RN_DIR}/ios/.headers_device"
HEADER_DIR_SIM="${RN_DIR}/ios/.headers_sim"
rm -rf "${HEADER_DIR_DEVICE}" "${HEADER_DIR_SIM}"
mkdir -p "${HEADER_DIR_DEVICE}" "${HEADER_DIR_SIM}"
cp "${REPO_ROOT}/swift/Sources/SignalFfi/signal_ffi.h" "${HEADER_DIR_DEVICE}/"
cp "${REPO_ROOT}/swift/Sources/SignalFfi/signal_ffi.h" "${HEADER_DIR_SIM}/"

xcodebuild -create-xcframework \
    -library "${RN_DIR}/ios/libsignal_ffi.a" -headers "${HEADER_DIR_DEVICE}" \
    -library "${SIM_FAT_DIR}/libsignal_ffi.a" -headers "${HEADER_DIR_SIM}" \
    -output "${XCFW}"

rm -rf "${HEADER_DIR_DEVICE}" "${HEADER_DIR_SIM}" "${SIM_FAT_DIR}"
echo "  XCFramework: ios/libsignal_ffi.xcframework"

# Copy the header file for C++ compilation
echo "Copying signal_ffi.h..."
cp "${REPO_ROOT}/swift/Sources/SignalFfi/signal_ffi.h" "${RN_DIR}/cpp/signal_ffi.h"

# Generate C++ compatible header
echo "Generating signal_ffi_cpp.h..."
python3 "${SCRIPT_DIR}/patch_header_cpp.py" "${RN_DIR}/cpp/signal_ffi.h" "${RN_DIR}/cpp/signal_ffi_cpp.h"

echo "Done! iOS libraries ready."

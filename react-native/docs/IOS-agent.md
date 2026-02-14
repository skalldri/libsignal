# iOS Implementation Plan — React Native libsignal

This document is the coding implementation plan for adding iOS support to the React Native libsignal bindings. It assumes the Mac Mini has been set up per `IOS-human.md`.

## Current State

The iOS scaffolding is **already partially built**:

| Component | Status | Notes |
|-----------|--------|-------|
| `ios/LibsignalInstaller.mm` | ✅ Exists | Obj-C++ bridge, calls `LibsignalModule::install()` |
| `react-native-libsignal.podspec` | ✅ Exists | CocoaPods spec, references `ios/`, `cpp/`, vendors `libsignal_ffi.a` |
| `scripts/build_ios.sh` | ✅ Exists | Builds `libsignal_ffi.a` for device + simulator via cargo |
| `cpp/LibsignalTurboModule.{h,cpp}` | ✅ Shared | Same C++ code used by Android — platform-agnostic JSI |
| `cpp/generated_jsi_bindings.cpp` | ✅ Shared | Auto-generated, platform-agnostic |
| `ios/libsignal_ffi.a` | ❌ Not built | Must be compiled from Rust on macOS |
| `ios/libsignal_ffi_sim.a` | ❌ Not built | Simulator fat binary (arm64 + x86_64) |
| `cpp/signal_ffi_cpp.h` | ⚠️ Generated | Exists from Android builds, may need regeneration |
| Example iOS project | ❌ Does not exist | Need Xcode project + Podfile in `example/ios/` |
| CallInvoker on iOS | ⚠️ Missing | Installer doesn't pass CallInvoker → async Promises are no-ops |
| CI workflow | ❌ Does not exist | Need GitHub Actions macOS workflow |

## Architecture

The iOS path mirrors Android exactly at the C++ layer:

```
JS (App.tsx) → Hermes/JSC Runtime
  → LibsignalInstaller.mm (Obj-C++ bridge, calls install())
    → LibsignalTurboModule.cpp (shared C++ JSI HostObject)
      → libsignal_ffi.a (Rust static library, linked at build time)
```

Key difference from Android:
- **Android**: `.so` shared library, loaded at runtime via `System.loadLibrary()`
- **iOS**: `.a` static library, linked into the app binary at compile time via Xcode

## Implementation Phases

### Phase 1: Build Rust Static Libraries

**Goal**: Produce `libsignal_ffi.a` for device and simulator.

- [ ] 1.1 — Install Rust iOS targets on the Mac Mini
  ```bash
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  ```

- [ ] 1.2 — Run the existing `build_ios.sh` script and fix any issues
  ```bash
  cd react-native && ./scripts/build_ios.sh
  ```
  This should produce:
  - `ios/libsignal_ffi.a` (device, aarch64)
  - `ios/libsignal_ffi_sim.a` (simulator, aarch64 + x86_64 fat binary)

- [ ] 1.3 — Generate the C++ header
  ```bash
  cp ../swift/Sources/SignalFfi/signal_ffi.h cpp/signal_ffi.h
  python3 scripts/patch_header_cpp.py cpp/signal_ffi.h cpp/signal_ffi_cpp.h
  ```

- [ ] 1.4 — Verify the `.a` files have expected symbols
  ```bash
  nm ios/libsignal_ffi.a | grep signal_hkdf_derive | head -3
  ```

**Estimated difficulty**: Low — script exists, should work on Apple Silicon natively.

---

### Phase 2: Fix the iOS Installer (CallInvoker)

**Goal**: Pass a `CallInvoker` to `LibsignalModule::install()` so async Promises work.

The current `LibsignalInstaller.mm` does NOT pass a CallInvoker:
```objc
libsignal::LibsignalModule::install(*runtime);  // Missing CallInvoker!
```

Without it, all async functions (Tokio-based Promises) silently fail to resolve.

- [ ] 2.1 — Update `LibsignalInstaller.mm` to extract the CallInvoker from the bridge

  The fix requires getting the `jsCallInvoker` from the bridge. On RN 0.71+:
  ```objc
  #import <ReactCommon/RCTTurboModuleManager.h>

  RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(install) {
      RCTBridge *bridge = [RCTBridge currentBridge];
      RCTCxxBridge *cxxBridge = (RCTCxxBridge *)bridge;
      if (!cxxBridge) return @(NO);

      auto runtime = (facebook::jsi::Runtime *)cxxBridge.runtime;
      if (!runtime) return @(NO);

      auto callInvoker = bridge.jsCallInvoker;
      libsignal::LibsignalModule::install(*runtime, callInvoker);
      return @(YES);
  }
  ```

  **Note**: `bridge.jsCallInvoker` availability depends on the RN version. If not available, try `cxxBridge.jsCallInvoker` or investigate the TurboModule manager path. This will require experimentation on the actual build to find the correct header/API.

- [ ] 2.2 — Verify async tests pass on iOS (tests 14-16 in App.tsx test Tokio async)

**Estimated difficulty**: Medium — may require some experimentation with RN internal APIs.

---

### Phase 3: Create iOS Example Project

**Goal**: Add an iOS Xcode project to the existing `example/` directory so both platforms share the same `App.tsx` and tests.

- [ ] 3.1 — Initialize the iOS project inside `example/`
  
  Option A (recommended): Use `npx react-native init` to scaffold a temporary project and copy the `ios/` directory into our `example/`.
  
  Option B: Manually create the Xcode project and Podfile.

- [ ] 3.2 — Create/configure `example/ios/Podfile`
  ```ruby
  require_relative '../node_modules/react-native/scripts/react_native_pods'
  require_relative '../node_modules/@react-native-community/cli-platform-ios/native_modules'

  platform :ios, '15.0'

  target 'LibsignalTestApp' do
    config = use_native_modules!
    use_react_native!(
      :path => config[:reactNativePath],
      :hermes_enabled => true,
    )

    # Our library — reference the podspec one level up
    pod 'react-native-libsignal', :path => '../../'

    post_install do |installer|
      react_native_post_install(installer)
    end
  end
  ```

- [ ] 3.3 — Handle the simulator vs device library linking

  The podspec currently vendors only `ios/libsignal_ffi.a` (device). For simulator builds, we need `libsignal_ffi_sim.a`. Options:
  
  **Option A** — XCFramework (preferred): Create an XCFramework that bundles both:
  ```bash
  xcodebuild -create-xcframework \
    -library ios/libsignal_ffi.a -headers cpp/ \
    -library ios/libsignal_ffi_sim.a -headers cpp/ \
    -output ios/libsignal_ffi.xcframework
  ```
  Then update the podspec: `s.vendored_frameworks = "ios/libsignal_ffi.xcframework"`
  
  **Option B** — Conditional linking in podspec using `s.pod_target_xcconfig` with SDK-conditional library paths.

  **Option C** — Build a single fat library (not recommended — `lipo` can't merge two arm64 slices for device vs simulator).

- [ ] 3.4 — Add system library dependencies to podspec
  
  The Rust library depends on system libs. From the upstream `LibSignalClient.podspec`:
  ```ruby
  s.libraries = "z"  # zlib for WebSocket compression
  ```

- [ ] 3.5 — Configure the Xcode project
  - Set deployment target to iOS 15.0+
  - Ensure `ENABLE_BITCODE = NO` (Rust doesn't support bitcode)
  - Set `OTHER_LDFLAGS` to link `libsignal_ffi.a` and `-lz`
  - Ensure C++17 is enabled

- [ ] 3.6 — Run `pod install` and verify the project opens in Xcode

- [ ] 3.7 — Build and run on iOS Simulator
  ```bash
  cd example/ios && pod install
  npx react-native run-ios
  ```

**Estimated difficulty**: Medium-High — Xcode project setup has many moving parts.

---

### Phase 4: Run Tests on iOS

**Goal**: All 33 tests passing on iOS Simulator, matching Android results.

- [ ] 4.1 — Build and launch on iOS Simulator

- [ ] 4.2 — Verify synchronous tests pass (1-13, 17-30)
  - These use the same C++ code path as Android
  - If the static library links correctly, these should just work

- [ ] 4.3 — Verify async tests pass (14-16)
  - These require the CallInvoker fix from Phase 2
  - The Tokio async runtime must initialize correctly on iOS

- [ ] 4.4 — Verify SenderKey tests pass (27-30, our new ones)
  - These use synchronous C callback bridges
  - Should work identically to Android since the C++ is shared

- [ ] 4.5 — Test on a physical device (if available via the Mac Mini)

**Estimated difficulty**: Low if Phases 1-3 succeed — the C++ is platform-agnostic.

---

### Phase 5: Build Scripts and CI

**Goal**: Single-command iOS builds and a GitHub Actions workflow.

- [ ] 5.1 — Update `build_ios.sh` to also produce an XCFramework
  - Add `--xcframework` flag
  - Output: `ios/libsignal_ffi.xcframework`

- [ ] 5.2 — Create `scripts/build_and_test_ios.sh` (mirroring `build_and_test.sh` for Android)
  ```bash
  # Builds Rust, generates headers, pod install, xcodebuild, run on simulator, collect results
  ```

- [ ] 5.3 — Create `scripts/build_release_ios.sh`
  - Builds release-optimized `.a` for all 3 targets
  - Strips debug symbols
  - Creates XCFramework
  - Compiles TypeScript

- [ ] 5.4 — Update the GitHub Actions release workflow
  - Add a macOS job for iOS builds
  - Build Rust for all iOS targets
  - Package the XCFramework + headers into the release zip
  - The release zip should contain both Android `.so` files AND iOS XCFramework

- [ ] 5.5 — Update `INTEGRATION.md` with iOS integration instructions

**Estimated difficulty**: Medium — macOS runners on GitHub Actions are slow and expensive.

---

### Phase 6: Podspec Refinement

**Goal**: Make the podspec production-ready for source-include and prebuilt-binary distribution.

- [ ] 6.1 — Support both prebuilt and build-from-source modes in the podspec
  - If `ios/libsignal_ffi.xcframework` exists, use it
  - Otherwise, run `scripts/build_ios.sh` as a `prepare_command`

- [ ] 6.2 — Test the podspec in a fresh React Native project
  ```bash
  pod lib lint react-native-libsignal.podspec
  ```

- [ ] 6.3 — Verify the library works when included as a local pod in a real app

**Estimated difficulty**: Low-Medium.

---

## Key Technical Risks

| Risk | Mitigation |
|------|-----------|
| Rust compilation fails on macOS for iOS targets | Upstream libsignal already supports iOS via `swift/build_ffi.sh` — same crate, proven to work |
| CallInvoker not accessible on iOS | Fallback: mark async tests as iOS-skipped; sync functions (95%+ of API) still work |
| XCFramework complexity | Can fall back to separate device/sim `.a` files with conditional podspec linking |
| `signal_ffi_cpp.h` C++ enum patching differs on macOS clang | The `patch_header_cpp.py` script is clang-version independent — it does text transforms |
| Static library linking conflicts with other pods | Unlikely — `libsignal_ffi` has a unique symbol namespace (`signal_*` prefix) |
| iOS Simulator arm64 vs device arm64 confusion | XCFramework solves this cleanly — each slice has its own platform tag |

## File Changes Summary

| File | Action | Description |
|------|--------|-------------|
| `ios/LibsignalInstaller.mm` | Modify | Add CallInvoker extraction |
| `react-native-libsignal.podspec` | Modify | XCFramework support, add `-lz`, fix header paths |
| `scripts/build_ios.sh` | Modify | Add XCFramework generation step |
| `scripts/build_and_test_ios.sh` | Create | Single-command iOS build + test |
| `scripts/build_release_ios.sh` | Create | Single-command iOS release build |
| `example/ios/Podfile` | Create | CocoaPods config for example app |
| `example/ios/LibsignalTestApp/` | Create | Xcode project files |
| `.github/workflows/react_native_release.yml` | Modify | Add macOS iOS build job |
| `docs/INTEGRATION.md` | Modify | Add iOS integration section |

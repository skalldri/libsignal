# Mac Mini Setup Guide — Human Helper

This document describes what you (the human) need to set up on the Mac Mini before the coding agent can begin iOS implementation work.

## Hardware Requirements

- Mac Mini with Apple Silicon (M1/M2/M3/M4) — confirmed ✅
- At least 16GB RAM (Rust compilation is memory-hungry)
- At least 50GB free disk space (Xcode ~15GB, Rust toolchains ~5GB, build artifacts ~20GB)

## Setup Checklist

Complete these in order. Each section notes whether it blocks the agent or not.

---

### 1. macOS Basics

- [ ] **macOS version**: Ensure macOS 14 (Sonoma) or newer. macOS 15 (Sequoia) is preferred.
- [ ] **Admin access**: The agent will need `sudo` for some Homebrew and system operations.
- [ ] **Shell**: Confirm the default shell is `zsh` (standard on modern macOS).

---

### 2. Xcode (BLOCKS EVERYTHING)

This is the single largest install and the most critical dependency.

- [ ] **Install Xcode** from the Mac App Store (or via `xcode-select`)
  - Xcode 15.x or 16.x (whichever is current)
  - This includes the iOS SDK, Simulator runtimes, and `xcodebuild`
  - ⚠️ This download is ~12-15GB and can take a long time

- [ ] **Accept the license**:
  ```bash
  sudo xcodebuild -license accept
  ```

- [ ] **Install Command Line Tools** (may already be included):
  ```bash
  xcode-select --install
  ```

- [ ] **Verify**:
  ```bash
  xcodebuild -version
  # Should show: Xcode 15.x or 16.x
  xcrun simctl list devices available | head -20
  # Should show available iOS Simulator devices
  ```

- [ ] **Install an iOS Simulator runtime** (if not included):
  - Open Xcode → Settings → Platforms → download iOS 17 or iOS 18 Simulator

---

### 3. Homebrew

- [ ] **Install Homebrew** (if not already present):
  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```

- [ ] **Add to PATH** (Apple Silicon uses `/opt/homebrew`):
  ```bash
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
  eval "$(/opt/homebrew/bin/brew shellenv)"
  ```

- [ ] **Verify**: `brew --version`

---

### 4. Rust Toolchain (BLOCKS PHASE 1)

- [ ] **Install Rust**:
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  source ~/.cargo/env
  ```

- [ ] **Install the specific nightly version** this project requires:
  ```bash
  # Check the rust-toolchain file in the repo root for the exact version
  cat rust-toolchain
  # Then install it — rustup will do this automatically when you build,
  # but pre-installing avoids surprises
  rustup toolchain install nightly-2025-09-24
  ```

- [ ] **Add iOS cross-compilation targets**:
  ```bash
  rustup target add aarch64-apple-ios        # Physical devices (ARM64)
  rustup target add aarch64-apple-ios-sim    # Simulator on Apple Silicon
  rustup target add x86_64-apple-ios         # Simulator on Intel Macs
  ```

- [ ] **Verify**:
  ```bash
  rustup show
  # Should list all 3 iOS targets as installed
  cargo --version
  ```

---

### 5. Node.js & npm (BLOCKS PHASE 3)

- [ ] **Install Node.js 18 or 20 LTS** (via Homebrew or nvm):
  ```bash
  # Option A: Homebrew
  brew install node@20

  # Option B: nvm (recommended for flexibility)
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash
  nvm install 20
  nvm use 20
  ```

- [ ] **Verify**:
  ```bash
  node --version   # v20.x.x
  npm --version    # 10.x.x
  ```

---

### 6. CocoaPods (BLOCKS PHASE 3)

- [ ] **Install CocoaPods**:
  ```bash
  # Option A: Homebrew (simpler)
  brew install cocoapods

  # Option B: Ruby gem (may need sudo)
  sudo gem install cocoapods
  ```

- [ ] **Verify**:
  ```bash
  pod --version  # 1.15.x or newer
  ```

---

### 7. Python 3 (BLOCKS HEADER GENERATION)

- [ ] **Verify Python 3 is available** (macOS ships with it, or install via Homebrew):
  ```bash
  python3 --version  # 3.9+ required
  ```

  If not present:
  ```bash
  brew install python3
  ```

---

### 8. Git & Repository Clone

- [ ] **Git** should be pre-installed with Xcode CLT. Verify: `git --version`

- [ ] **Clone the repository**:
  ```bash
  git clone https://github.com/skalldri/libsignal.git
  cd libsignal
  git checkout react-native-ios-android
  ```

- [ ] **Install npm dependencies**:
  ```bash
  cd react-native
  npm install
  cd example
  npm install
  ```

---

### 9. Copilot CLI Agent Setup

- [ ] **Install the GitHub Copilot CLI agent** so I can run on the Mac Mini.
  Follow whatever method you've been using to start sessions — VS Code with the Copilot extension, or the standalone CLI.

- [ ] **Open the workspace**: Open the `libsignal/` repo root in VS Code (or your preferred editor).

- [ ] **Verify I have access** by starting a session and asking me to run `uname -a` — I should see `Darwin` and `arm64`.

---

### 10. CMake

- [ ] **Cmake** `brew install cmake`

---

### 11. Quick Smoke Test (Optional but Recommended)

Before handing off to the agent, verify the Rust build works:

```bash
cd libsignal/react-native
./scripts/build_ios.sh
```

This should:
1. Compile Rust for 3 iOS targets (takes 5-15 minutes on first build)
2. Create `ios/libsignal_ffi.a` and `ios/libsignal_ffi_sim.a`
3. Copy `signal_ffi.h` to `cpp/`

If it succeeds, the Mac Mini is ready for the agent.

If it fails, common issues:
- **Missing Xcode**: `xcrun: error: unable to find utility "clang"` → Install Xcode + CLT
- **Missing iOS SDK**: `ld: library not found for -lSystem` → `xcode-select -p` should point to Xcode.app
- **Wrong Rust toolchain**: Check `cat rust-toolchain` and ensure that nightly is installed

---

## Summary of Installs

| Tool | Install Command | Approx Size | Blocks |
|------|----------------|-------------|--------|
| Xcode + CLT | Mac App Store | ~15 GB | Everything |
| Homebrew | curl script | ~200 MB | Most installs |
| Rust + targets | rustup.rs | ~2 GB | Phase 1 (Rust builds) |
| Node.js 20 | `brew install node@20` | ~100 MB | Phase 3 (JS/RN) |
| CocoaPods | `brew install cocoapods` | ~50 MB | Phase 3 (iOS project) |
| Python 3 | Usually pre-installed | ~50 MB | Header generation |
| Git | Included with Xcode CLT | — | Repository access |

**Total estimated time**: 30-60 minutes (dominated by Xcode download).

---

## What the Agent Will Do

Once you hand off, the agent will:

1. Verify the environment (all tools present and working)
2. Build Rust static libraries for iOS (`build_ios.sh`)
3. Fix the iOS native module installer (CallInvoker)
4. Create the iOS Xcode project in `example/ios/`
5. Run all 33 tests on the iOS Simulator
6. Create build/test scripts
7. Update the GitHub Actions release workflow

You should not need to do anything further unless the agent encounters issues it can't resolve (e.g., Xcode signing, Apple Developer account requirements).

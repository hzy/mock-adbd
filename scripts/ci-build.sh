#!/bin/bash
# CI build script for mock-adbd
# Builds the self-extracting dist/mock-adbd.sh from scratch on a clean Linux CI runner.
#
# Prerequisites (usually pre-installed on CI):
#   - bash, curl, tar, gzip, cpio, awk
#
# Everything else (Rust toolchain, musl target, Alpine assets) is auto-installed/downloaded.
#
# Usage:
#   bash scripts/ci-build.sh              # Build dist/mock-adbd.sh
#   bash scripts/ci-build.sh --test       # Build + run integration tests (needs qemu)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUN_TESTS=false

[ "${1:-}" = "--test" ] && RUN_TESTS=true

cd "$PROJECT_DIR"

echo "=== mock-adbd CI build ==="
echo ""

# --- Step 1: Ensure Rust toolchain ---
if ! command -v rustc &>/dev/null; then
    echo "[1/4] Installing Rust toolchain..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal 2>&1 | tail -3
    source "$HOME/.cargo/env"
else
    echo "[1/4] Rust toolchain: $(rustc --version)"
fi

# Ensure musl target
if ! rustup target list --installed 2>/dev/null | grep -q x86_64-unknown-linux-musl; then
    echo "  Adding x86_64-unknown-linux-musl target..."
    rustup target add x86_64-unknown-linux-musl
fi

# --- Step 2: Ensure cpio (the only non-obvious dep) ---
if ! command -v cpio &>/dev/null; then
    echo "[!] cpio not found. Installing..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq cpio
    elif command -v yum &>/dev/null; then
        sudo yum install -y cpio
    elif command -v apk &>/dev/null; then
        apk add cpio
    else
        echo "ERROR: cpio not found and no known package manager to install it" >&2
        exit 1
    fi
fi

# --- Step 3: Build ---
echo "[2/4] Building Rust binary..."
cd "$PROJECT_DIR/guest-adbd"
cargo build --target x86_64-unknown-linux-musl --release 2>&1 | tail -5
echo "  Binary: $(ls -lh target/x86_64-unknown-linux-musl/release/mock-adbd | awk '{print $5}')"

echo "[3/4] Building rootfs + initramfs..."
cd "$PROJECT_DIR"
bash scripts/build-rootfs.sh 2>&1 | grep -E "^(===|  |Binary|Kernel|Initramfs|Installed|Extracting|Creating|Downloading)"

echo "[4/4] Packaging..."
bash scripts/package.sh
echo ""

DIST="$PROJECT_DIR/dist/mock-adbd.sh"
echo "=== Build complete ==="
echo "  Output: $DIST"
echo "  Size:   $(ls -lh "$DIST" | awk '{print $5}')"
echo "  SHA256: $(sha256sum "$DIST" | awk '{print $1}')"

# --- Optional: integration tests ---
if $RUN_TESTS; then
    echo ""
    echo "=== Running integration tests ==="
    if ! command -v qemu-system-x86_64 &>/dev/null; then
        echo "ERROR: qemu-system-x86_64 not found. Install QEMU to run tests." >&2
        echo "  apt: sudo apt install qemu-system-x86"
        exit 1
    fi
    if ! command -v adb &>/dev/null; then
        echo "ERROR: adb not found. Install Android platform-tools to run tests." >&2
        exit 1
    fi
    bash tests/integration_test.sh
fi

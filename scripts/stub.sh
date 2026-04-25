#!/bin/bash
# mock-adbd — Self-contained ADB mock device
#
# Usage:
#   ./mock-adbd.sh                    # Start on default port 5555
#   ./mock-adbd.sh -p 5556            # Start on custom port
#   ./mock-adbd.sh -p 5555 -m 256M    # Custom port + memory
#   ./mock-adbd.sh --extract DIR      # Extract payload only (no run)
#   ./mock-adbd.sh --help
#
# Then:  adb connect localhost:5555
#        adb shell
#
# Supports: Linux x86_64, macOS (Intel + Apple Silicon)
# Requirements: qemu-system-x86_64 (brew install qemu / apt install qemu-system-x86)

set -euo pipefail

VERSION="1.1.0"
ADB_PORT=5555
QEMU_MEM=128M
EXTRACT_ONLY=""
CLEANUP=true
VERBOSE=false

usage() {
    cat <<EOF
mock-adbd v${VERSION} — Self-contained ADB mock device

Usage: $0 [OPTIONS]

Options:
  -p, --port PORT     ADB port to expose (default: 5555)
  -m, --mem SIZE      VM memory (default: 128M)
  --extract DIR       Extract payload to DIR and exit
  -v, --verbose       Show VM boot logs
  -h, --help          Show this help

Examples:
  $0                  # Run on port 5555
  $0 -p 15555        # Run on port 15555

After starting:
  adb connect localhost:5555
  adb shell echo hello
  adb shell
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--port)    ADB_PORT="$2"; shift 2 ;;
        -m|--mem)     QEMU_MEM="$2"; shift 2 ;;
        --extract)    EXTRACT_ONLY="$2"; CLEANUP=false; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help)    usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# --- Locate payload ---
ARCHIVE_LINE=$(awk '/^__PAYLOAD_BEGINS__$/{print NR + 1; exit 0;}' "$0")
if [ -z "$ARCHIVE_LINE" ]; then
    echo "ERROR: Payload marker not found. File may be corrupted." >&2
    exit 1
fi

# --- Extract only ---
if [ -n "$EXTRACT_ONLY" ]; then
    echo "Extracting to $EXTRACT_ONLY ..."
    mkdir -p "$EXTRACT_ONLY"
    tail -n +"$ARCHIVE_LINE" "$0" | tar xzf - -C "$EXTRACT_ONLY"
    echo "Done. Files:"
    ls -lh "$EXTRACT_ONLY"/
    exit 0
fi

# --- Check QEMU ---
QEMU_BIN="qemu-system-x86_64"
if ! command -v "$QEMU_BIN" &>/dev/null; then
    echo "ERROR: '$QEMU_BIN' not found." >&2
    echo "" >&2
    case "$(uname -s)" in
        Darwin) echo "Install: brew install qemu" >&2 ;;
        Linux)  echo "Install: sudo apt install qemu-system-x86" >&2 ;;
        *)      echo "Please install QEMU." >&2 ;;
    esac
    exit 1
fi

# --- Extract to temp dir ---
TMPDIR=$(mktemp -d -t mock-adbd.XXXXXX)
cleanup() { $CLEANUP && rm -rf "$TMPDIR"; }
trap cleanup EXIT

tail -n +"$ARCHIVE_LINE" "$0" | tar xzf - -C "$TMPDIR"

KERNEL="$TMPDIR/vmlinuz"
INITRAMFS="$TMPDIR/initramfs.cpio.gz"

[ -f "$KERNEL" ] && [ -f "$INITRAMFS" ] || {
    echo "ERROR: Extracted payload is incomplete." >&2; exit 1
}

# --- Build QEMU command ---
KERNEL_APPEND="console=ttyS0 panic=1 net.ifnames=0"
$VERBOSE || KERNEL_APPEND="$KERNEL_APPEND quiet"

QEMU_CMD=(
    "$QEMU_BIN"
    -m "$QEMU_MEM" -nographic -no-reboot
    -kernel "$KERNEL" -initrd "$INITRAMFS"
    -append "$KERNEL_APPEND"
    -nic "user,model=virtio-net-pci,hostfwd=tcp::${ADB_PORT}-:5555"
)

# --- Launch ---
echo "mock-adbd v${VERSION}"
echo "  Port:   $ADB_PORT"
echo "  Memory: $QEMU_MEM"
echo ""
echo "Booting VM... (Ctrl+C to stop)"
echo "After boot:  adb connect localhost:${ADB_PORT}"
echo ""

exec "${QEMU_CMD[@]}"

# This line must be last before the binary payload
__PAYLOAD_BEGINS__

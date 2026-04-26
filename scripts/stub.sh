#!/bin/bash
# mock-adbd — Self-contained ADB mock device
#
# Usage:
#   ./mock-adbd.sh                         # Start on default port 5555
#   ./mock-adbd.sh -p 0                    # Auto-select a free port
#   ./mock-adbd.sh -p 0 --reply-fd 5       # Write selected port to fd 5
#   ./mock-adbd.sh --extract DIR           # Extract payload only
#   ./mock-adbd.sh --help
#
# Then:  adb connect localhost:<port>
#        adb shell
#
# Supports: Linux x86_64, macOS (Intel + Apple Silicon)
# Requirements: qemu-system-x86_64 (brew install qemu / apt install qemu-system-x86)

set -euo pipefail

VERSION="1.2.0"
ADB_PORT=5555
QEMU_MEM=128M
REPLY_FD=""
EXTRACT_ONLY=""
CLEANUP=true
VERBOSE=false

usage() {
    cat <<EOF
mock-adbd v${VERSION} — Self-contained ADB mock device

Usage: $0 [OPTIONS]

Options:
  -p, --port PORT       ADB port (default: 5555, use 0 for auto-select)
  --reply-fd FD         Write the selected port to this fd (for programmatic use)
  -m, --mem SIZE        VM memory (default: 128M)
  --extract DIR         Extract payload to DIR and exit
  -v, --verbose         Show VM boot logs
  -h, --help            Show this help

Examples:
  $0                            # Run on port 5555
  $0 -p 0                      # Auto-select a free port, print to stderr
  $0 -p 0 --reply-fd 5         # Write port to fd 5 (like adb --reply-fd)

Programmatic usage (bash):
  exec 5< <(\$0 -p 0 --reply-fd 4 4>&1 >&2)
  PORT=\$(head -1 <&5)
  adb connect localhost:\$PORT

After starting:
  adb connect localhost:<port>
  adb shell
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--port)      ADB_PORT="$2"; shift 2 ;;
        --reply-fd)     REPLY_FD="$2"; shift 2 ;;
        -m|--mem)       QEMU_MEM="$2"; shift 2 ;;
        --extract)      EXTRACT_ONLY="$2"; CLEANUP=false; shift 2 ;;
        -v|--verbose)   VERBOSE=true; shift ;;
        -h|--help)      usage ;;
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
    case "$(uname -s)" in
        Darwin) echo "Install: brew install qemu" >&2 ;;
        Linux)  echo "Install: sudo apt install qemu-system-x86" >&2 ;;
    esac
    exit 1
fi

# --- Auto-select port if port=0 ---
if [ "$ADB_PORT" = "0" ]; then
    # Try python3 first (atomic kernel allocation, no TOCTOU)
    ADB_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()" 2>/dev/null || true)
    # Fallback: bash /dev/tcp probe
    if [ -z "$ADB_PORT" ] || [ "$ADB_PORT" = "0" ]; then
        ADB_PORT=0
        for _candidate in $(shuf -i 49152-65000 -n 200); do
            if ! (echo >/dev/tcp/localhost/$_candidate) 2>/dev/null; then
                ADB_PORT=$_candidate
                break
            fi
        done
    fi
    if [ "$ADB_PORT" = "0" ]; then
        echo "ERROR: Could not find a free port." >&2
        exit 1
    fi
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
echo "mock-adbd v${VERSION}" >&2
echo "  Port:   $ADB_PORT" >&2
echo "  Memory: $QEMU_MEM" >&2
echo "" >&2
echo "Booting VM... (Ctrl+C to stop)" >&2
echo "After boot:  adb connect localhost:${ADB_PORT}" >&2
echo "" >&2

"${QEMU_CMD[@]}" </dev/null &
QEMU_PID=$!

# Wait for adbd to be ready (port accepting connections)
_ready=false
for _i in $(seq 1 120); do
    if (echo >/dev/tcp/localhost/"$ADB_PORT") 2>/dev/null; then
        _ready=true
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "ERROR: QEMU exited before adbd was ready." >&2
        exit 1
    fi
    sleep 0.5
done

if ! $_ready; then
    echo "ERROR: Timed out waiting for adbd to start on port $ADB_PORT." >&2
    kill "$QEMU_PID" 2>/dev/null
    exit 1
fi

# --- Reply with port ---
if [ -n "$REPLY_FD" ]; then
    # Write port to the specified fd
    echo "$ADB_PORT" >&"$REPLY_FD"
fi

echo "Ready: adb connect localhost:${ADB_PORT}" >&2

# --- Wait for QEMU ---
shutdown() {
    echo "" >&2
    echo "Shutting down..." >&2
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    exit 0
}
trap shutdown INT TERM

while kill -0 "$QEMU_PID" 2>/dev/null; do
    wait "$QEMU_PID" 2>/dev/null || true
done

# This line must be last before the binary payload
__PAYLOAD_BEGINS__

#!/bin/bash
# Launch the ADB mock QEMU VM (dev mode)
# Usage: ./run.sh [--port PORT] [--reply-fd FD] [--mem SIZE] [--debug]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

ADB_PORT="${ADB_PORT:-5555}"
QEMU_MEM="${QEMU_MEM:-128M}"
REPLY_FD=""
DEBUG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --port|-p)    ADB_PORT="$2"; shift 2 ;;
        --reply-fd)   REPLY_FD="$2"; shift 2 ;;
        --mem|-m)     QEMU_MEM="$2"; shift 2 ;;
        --debug)      DEBUG=true; shift ;;
        *) echo "Usage: $0 [--port PORT] [--reply-fd FD] [--mem SIZE] [--debug]"; exit 1 ;;
    esac
done

KERNEL="$BUILD_DIR/vmlinuz"
INITRAMFS="$BUILD_DIR/initramfs.cpio.gz"

if [ ! -f "$KERNEL" ] || [ ! -f "$INITRAMFS" ]; then
    echo "Build artifacts not found. Running build-rootfs.sh..." >&2
    bash "$SCRIPT_DIR/build-rootfs.sh"
fi

# Auto-select port if port=0
if [ "$ADB_PORT" = "0" ]; then
    ADB_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()" 2>/dev/null || true)
    if [ -z "$ADB_PORT" ] || [ "$ADB_PORT" = "0" ]; then
        ADB_PORT=0
        for _c in $(shuf -i 49152-65000 -n 200); do
            if ! (echo >/dev/tcp/localhost/$_c) 2>/dev/null; then
                ADB_PORT=$_c; break
            fi
        done
    fi
    [ "$ADB_PORT" = "0" ] && { echo "ERROR: Could not find a free port." >&2; exit 1; }
fi

KERNEL_APPEND="console=ttyS0 panic=1 net.ifnames=0"
$DEBUG || KERNEL_APPEND="$KERNEL_APPEND quiet"

QEMU_CMD=(
    qemu-system-x86_64
    -m "$QEMU_MEM" -nographic -no-reboot
    -kernel "$KERNEL" -initrd "$INITRAMFS"
    -append "$KERNEL_APPEND"
    -nic "user,model=virtio-net-pci,hostfwd=tcp::${ADB_PORT}-:5555"
)

echo "Starting mock-adbd..." >&2
echo "  Port:    $ADB_PORT" >&2
echo "  Memory:  $QEMU_MEM" >&2
echo "  Connect: adb connect localhost:$ADB_PORT" >&2
echo "" >&2

"${QEMU_CMD[@]}" </dev/null &
QEMU_PID=$!

# Wait for adbd to be ready
for _i in $(seq 1 120); do
    if (echo >/dev/tcp/localhost/"$ADB_PORT") 2>/dev/null; then break; fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "ERROR: QEMU exited before adbd was ready." >&2; exit 1
    fi
    sleep 0.5
done

# Reply with port
if [ -n "$REPLY_FD" ]; then
    echo "$ADB_PORT" >&"$REPLY_FD"
fi

echo "Ready: adb connect localhost:${ADB_PORT}" >&2

trap 'echo "" >&2; echo "Shutting down..." >&2; kill $QEMU_PID 2>/dev/null; wait $QEMU_PID 2>/dev/null; exit 0' INT TERM
while kill -0 "$QEMU_PID" 2>/dev/null; do
    wait "$QEMU_PID" 2>/dev/null || true
done

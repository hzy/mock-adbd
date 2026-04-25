#!/bin/bash
# Launch the ADB mock QEMU VM
# Usage: ./run.sh [--port PORT] [--mem SIZE] [--debug]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

ADB_PORT="${ADB_PORT:-5555}"
QEMU_MEM="${QEMU_MEM:-128M}"
DEBUG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --port|-p) ADB_PORT="$2"; shift 2 ;;
        --mem|-m)  QEMU_MEM="$2"; shift 2 ;;
        --debug)   DEBUG=true; shift ;;
        *) echo "Usage: $0 [--port PORT] [--mem SIZE] [--debug]"; exit 1 ;;
    esac
done

KERNEL="$BUILD_DIR/vmlinuz"
INITRAMFS="$BUILD_DIR/initramfs.cpio.gz"

if [ ! -f "$KERNEL" ] || [ ! -f "$INITRAMFS" ]; then
    echo "Build artifacts not found. Running build-rootfs.sh..."
    bash "$SCRIPT_DIR/build-rootfs.sh"
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

echo "Starting ADB mock VM..."
echo "  Port:    $ADB_PORT"
echo "  Memory:  $QEMU_MEM"
echo "  Connect: adb connect localhost:$ADB_PORT"
echo ""

exec "${QEMU_CMD[@]}"

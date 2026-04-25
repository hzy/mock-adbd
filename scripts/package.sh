#!/bin/bash
# Package mock-adbd into a single self-extracting script
# Usage: bash scripts/package.sh [output_file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
OUTPUT="${1:-$PROJECT_DIR/dist/mock-adbd.sh}"

if [ ! -f "$BUILD_DIR/vmlinuz" ] || [ ! -f "$BUILD_DIR/initramfs.cpio.gz" ]; then
    echo "Build artifacts not found. Run build-rootfs.sh first."
    exit 1
fi

PAYLOAD=$(mktemp /tmp/mock-adbd-payload.XXXXXX.tar.gz)
trap "rm -f '$PAYLOAD'" EXIT

echo "Creating payload..."
cd "$BUILD_DIR"
tar czf "$PAYLOAD" vmlinuz initramfs.cpio.gz
echo "  Payload: $(ls -lh "$PAYLOAD" | awk '{print $5}')"

mkdir -p "$(dirname "$OUTPUT")"
cat "$SCRIPT_DIR/stub.sh" "$PAYLOAD" > "$OUTPUT"
chmod +x "$OUTPUT"

echo "  Output:  $OUTPUT ($(ls -lh "$OUTPUT" | awk '{print $5}'))"
echo ""
echo "Usage:"
echo "  ./$(basename "$OUTPUT")              # port 5555"
echo "  ./$(basename "$OUTPUT") -p 15555     # custom port"
echo "  ./$(basename "$OUTPUT") --help"

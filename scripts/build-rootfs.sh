#!/bin/bash
# Build a minimal Alpine Linux rootfs for the ADB mock VM (x86_64)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${1:-$PROJECT_DIR/build}"
ROOTFS_DIR="$OUTPUT_DIR/rootfs"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_ARCH="x86_64"
RUST_TARGET="x86_64-unknown-linux-musl"
GUEST_SHELL="${GUEST_SHELL:-/bin/sh}"
ADBD_BINARY="$PROJECT_DIR/guest-adbd/target/${RUST_TARGET}/release/mock-adbd"

echo "=== Building Alpine rootfs for ADB mock ==="

# --- Step 1: Build Rust binary ---
if [ ! -f "$ADBD_BINARY" ]; then
    echo "Building mock-adbd ($RUST_TARGET)..."
    cd "$PROJECT_DIR/guest-adbd"
    cargo build --target "$RUST_TARGET" --release 2>&1 | tail -3
fi
echo "Binary: $(ls -lh "$ADBD_BINARY" | awk '{print $5}') (static)"

mkdir -p "$OUTPUT_DIR"

# --- Step 2: Download Alpine virt kernel ---
KERNEL_FILE="$OUTPUT_DIR/vmlinuz"
KERNEL_APK="$OUTPUT_DIR/kernel.apk"
if [ ! -f "$KERNEL_FILE" ] || [ ! -f "$KERNEL_APK" ]; then
    echo "Downloading Alpine virt kernel..."
    KERNEL_PKG=$(curl -fsSL "$ALPINE_MIRROR/v3.21/main/$ALPINE_ARCH/" 2>/dev/null \
        | grep -o 'linux-virt-[0-9][^"]*\.apk' | sort -V | tail -1)
    [ -z "$KERNEL_PKG" ] && { echo "ERROR: Could not find linux-virt package"; exit 1; }
    echo "  $KERNEL_PKG"
    curl -fsSL -o "$KERNEL_APK" "$ALPINE_MIRROR/v3.21/main/$ALPINE_ARCH/$KERNEL_PKG"
    KTMP="$OUTPUT_DIR/kernel-tmp"
    mkdir -p "$KTMP" && cd "$KTMP"
    tar xzf "$KERNEL_APK" 2>/dev/null || true
    VMLINUZ=$(find . -name 'vmlinuz*' | head -1)
    [ -z "$VMLINUZ" ] && { echo "ERROR: vmlinuz not found"; exit 1; }
    cp "$VMLINUZ" "$KERNEL_FILE"
    cd "$PROJECT_DIR" && rm -rf "$KTMP"
fi
echo "Kernel: $(ls -lh "$KERNEL_FILE" | awk '{print $5}')"

# --- Step 3: Download Alpine minirootfs ---
MINIROOTFS=""
for ver in "3.21.3" "3.21.2" "3.21.1" "3.21.0"; do
    fname="alpine-minirootfs-${ver}-${ALPINE_ARCH}.tar.gz"
    [ -f "$OUTPUT_DIR/$fname" ] && { MINIROOTFS="$fname"; break; }
    url="$ALPINE_MIRROR/v${ver%.*}/releases/$ALPINE_ARCH/$fname"
    if curl -fsSL -o "$OUTPUT_DIR/$fname" "$url" 2>/dev/null; then
        MINIROOTFS="$fname"; break
    fi
    rm -f "$OUTPUT_DIR/$fname"
done
[ -z "$MINIROOTFS" ] && { echo "ERROR: Failed to download Alpine minirootfs"; exit 1; }

# --- Step 4: Assemble rootfs ---
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
echo "Extracting rootfs..."
tar xzf "$OUTPUT_DIR/$MINIROOTFS" -C "$ROOTFS_DIR"

cp "$ADBD_BINARY" "$ROOTFS_DIR/usr/bin/mock-adbd"
chmod 755 "$ROOTFS_DIR/usr/bin/mock-adbd"

# --- Step 5: Install kernel modules for virtio-net ---
echo "Installing kernel modules..."
KTMP="$OUTPUT_DIR/km-tmp"
rm -rf "$KTMP" && mkdir -p "$KTMP" && cd "$KTMP"
tar xzf "$KERNEL_APK" 2>/dev/null || true
KVER=$(ls lib/modules/ 2>/dev/null | head -1)
if [ -n "$KVER" ]; then
    MODDIR="$ROOTFS_DIR/lib/modules/$KVER"
    mkdir -p "$MODDIR/kernel/drivers/net" "$MODDIR/kernel/net/core"
    cp "lib/modules/$KVER/kernel/drivers/net/virtio_net.ko.gz"    "$MODDIR/kernel/drivers/net/"  2>/dev/null || true
    cp "lib/modules/$KVER/kernel/drivers/net/net_failover.ko.gz"  "$MODDIR/kernel/drivers/net/"  2>/dev/null || true
    cp "lib/modules/$KVER/kernel/net/core/failover.ko.gz"         "$MODDIR/kernel/net/core/"     2>/dev/null || true
    for f in modules.dep modules.dep.bin modules.alias modules.alias.bin \
             modules.builtin modules.builtin.bin modules.order \
             modules.symbols modules.symbols.bin; do
        cp "lib/modules/$KVER/$f" "$MODDIR/" 2>/dev/null || true
    done
    echo "  virtio_net (+deps) for kernel $KVER"
fi
cd "$PROJECT_DIR" && rm -rf "$KTMP"

# --- Step 6: Create init script ---
cat > "$ROOTFS_DIR/init" <<'INIT_EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mkdir -p /dev/pts /dev/shm /tmp /root
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /tmp
hostname localhost

KVER=$(uname -r)
for mod in failover net_failover virtio_net; do
    f=$(find /lib/modules/$KVER -name "${mod}.ko.gz" 2>/dev/null | head -1)
    if [ -n "$f" ]; then
        gzip -d -c "$f" > /tmp/${mod}.ko 2>/dev/null
        insmod /tmp/${mod}.ko 2>/dev/null && echo "Loaded $mod" || echo "Failed $mod"
        rm -f /tmp/${mod}.ko
    fi
done
sleep 1

ip link set lo up
NET_IF=""
for iface in /sys/class/net/*; do
    name=$(basename "$iface")
    [ "$name" = "lo" ] && continue
    NET_IF="$name"; break
done
if [ -n "$NET_IF" ]; then
    echo "Configuring network on $NET_IF"
    ip link set "$NET_IF" up
    ip addr add 10.0.2.15/24 dev "$NET_IF"
    ip route add default via 10.0.2.2
else
    echo "WARNING: No network interface found"
fi

echo "=== ADB Mock VM ready ==="
exec /usr/bin/mock-adbd
INIT_EOF
chmod 755 "$ROOTFS_DIR/init"

echo "root:x:0:0:root:/root:${GUEST_SHELL}" > "$ROOTFS_DIR/etc/passwd"
echo 'root:x:0:root' > "$ROOTFS_DIR/etc/group"
echo 'localhost' > "$ROOTFS_DIR/etc/hostname"

# --- Step 7: Create initramfs ---
echo "Creating initramfs..."
cd "$ROOTFS_DIR"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$OUTPUT_DIR/initramfs.cpio.gz"
echo "Initramfs: $(ls -lh "$OUTPUT_DIR/initramfs.cpio.gz" | awk '{print $5}')"

echo ""
echo "=== Build complete ==="
echo "  Kernel:    $KERNEL_FILE"
echo "  Initramfs: $OUTPUT_DIR/initramfs.cpio.gz"
echo "  Run:       ./scripts/run.sh"

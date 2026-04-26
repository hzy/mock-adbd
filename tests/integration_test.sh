#!/bin/bash
# Integration test for ADB mock
# Launches QEMU VM, connects via ADB, runs tests, reports results.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

ADB_PORT="${ADB_PORT:-15555}"
ADB_SERIAL="localhost:$ADB_PORT"
QEMU_PID=""
PASS=0
FAIL=0
TOTAL=0

cleanup() {
    if [ -n "$QEMU_PID" ]; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    adb disconnect "$ADB_SERIAL" 2>/dev/null || true
}
trap cleanup EXIT

log_pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  ✅ PASS: $1"; }
log_fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  ❌ FAIL: $1"; [ -n "${2:-}" ] && echo "         $2"; }

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    echo "$haystack" | grep -qF "$needle" && log_pass "$desc" || log_fail "$desc" "expected '$needle' in: $haystack"
}

assert_exit_code() {
    local desc="$1" expected="$2" actual="$3"
    [ "$expected" = "$actual" ] && log_pass "$desc" || log_fail "$desc" "expected exit $expected, got $actual"
}

# ============================================================
echo "=== ADB Mock Integration Tests ==="
echo ""

# --- Build check ---
echo "[1/9] Checking build artifacts..."
if [ ! -f "$BUILD_DIR/vmlinuz" ] || [ ! -f "$BUILD_DIR/initramfs.cpio.gz" ]; then
    echo "Build artifacts not found. Building..."
    bash "$PROJECT_DIR/scripts/build-rootfs.sh"
fi
[ -f "$BUILD_DIR/vmlinuz" ] && log_pass "vmlinuz exists" || log_fail "vmlinuz missing"
[ -f "$BUILD_DIR/initramfs.cpio.gz" ] && log_pass "initramfs exists" || log_fail "initramfs missing"

# --- Start QEMU ---
echo ""
echo "[2/9] Starting QEMU VM (port $ADB_PORT)..."
QEMU_ARGS=(
    qemu-system-x86_64
    -m 128M -nographic -no-reboot
    -kernel "$BUILD_DIR/vmlinuz"
    -initrd "$BUILD_DIR/initramfs.cpio.gz"
    -append "console=ttyS0 panic=1 net.ifnames=0 quiet"
    -nic "user,model=virtio-net-pci,hostfwd=tcp::${ADB_PORT}-:5555"
)
"${QEMU_ARGS[@]}" &>/dev/null &
QEMU_PID=$!
echo "  QEMU PID: $QEMU_PID"

# Wait for VM to boot
echo "  Waiting for VM to boot..."
for i in $(seq 1 60); do
    if adb connect "$ADB_SERIAL" 2>&1 | grep -q "connected"; then break; fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        log_fail "QEMU died during boot"; exit 1
    fi
    sleep 1
done

sleep 2
DEVICES_OUTPUT=$(adb devices 2>&1)
if echo "$DEVICES_OUTPUT" | grep -q "$ADB_SERIAL.*device"; then
    log_pass "adb connect + device visible"
else
    log_fail "adb connect" "devices: $DEVICES_OUTPUT"
    echo "FATAL: Cannot connect, aborting"; exit 1
fi

# --- Test 3: Shell single command ---
echo ""
echo "[3/9] Shell single command..."
OUTPUT=$(timeout 10 adb -s "$ADB_SERIAL" shell "echo hello_world" 2>&1)
assert_contains "echo command" "hello_world" "$OUTPUT"

OUTPUT=$(timeout 10 adb -s "$ADB_SERIAL" shell "uname -s" 2>&1)
assert_contains "uname -s" "Linux" "$OUTPUT"

OUTPUT=$(timeout 10 adb -s "$ADB_SERIAL" shell "pwd" 2>&1)
assert_contains "pwd" "/" "$OUTPUT"

OUTPUT=$(timeout 10 adb -s "$ADB_SERIAL" shell "ls /usr/bin/mock-adbd" 2>&1)
assert_contains "mock-adbd in rootfs" "mock-adbd" "$OUTPUT"

# --- Test 4: Exit code propagation ---
echo ""
echo "[4/9] Exit code propagation..."
timeout 10 adb -s "$ADB_SERIAL" shell "true" 2>&1
assert_exit_code "exit 0 (true)" "0" "$?"

EC=0; timeout 10 adb -s "$ADB_SERIAL" shell "exit 42" 2>&1 || EC=$?
assert_exit_code "exit 42" "42" "$EC"

EC=0; timeout 10 adb -s "$ADB_SERIAL" shell "exit 1" 2>&1 || EC=$?
assert_exit_code "exit 1" "1" "$EC"

# --- Test 5: Interactive shell ---
echo ""
echo "[5/9] Interactive shell..."
OUTPUT=$(echo -e "echo interactive_ok\nexit" | timeout 10 adb -s "$ADB_SERIAL" shell 2>&1)
assert_contains "interactive echo" "interactive_ok" "$OUTPUT"

# --- Test 6: Complex commands ---
echo ""
echo "[6/9] Complex commands..."
OUTPUT=$(timeout 10 adb -s "$ADB_SERIAL" shell "echo 'a b c' | wc -w" 2>&1)
assert_contains "pipe wc" "3" "$OUTPUT"

OUTPUT=$(timeout 10 adb -s "$ADB_SERIAL" shell "for i in 1 2 3; do echo \$i; done" 2>&1)
assert_contains "for loop" "1" "$OUTPUT"
assert_contains "for loop" "3" "$OUTPUT"

OUTPUT=$(timeout 10 adb -s "$ADB_SERIAL" shell "cat /etc/hostname" 2>&1)
assert_contains "cat hostname" "localhost" "$OUTPUT"

# --- Test 7: Concurrent connections ---
echo ""
echo "[7/9] Concurrent connections..."
OUT1_FILE=$(mktemp); OUT2_FILE=$(mktemp)
timeout 15 adb -s "$ADB_SERIAL" shell "echo conn1_ok; sleep 1; echo conn1_done" > "$OUT1_FILE" 2>&1 &
PID1=$!
timeout 15 adb -s "$ADB_SERIAL" shell "echo conn2_ok; sleep 1; echo conn2_done" > "$OUT2_FILE" 2>&1 &
PID2=$!
wait $PID1 $PID2 2>/dev/null || true

OUT1=$(cat "$OUT1_FILE"); OUT2=$(cat "$OUT2_FILE")
rm -f "$OUT1_FILE" "$OUT2_FILE"

assert_contains "concurrent conn1" "conn1_ok" "$OUT1"
assert_contains "concurrent conn2" "conn2_ok" "$OUT2"
assert_contains "concurrent conn1 done" "conn1_done" "$OUT1"
assert_contains "concurrent conn2 done" "conn2_done" "$OUT2"

# --- Test 8: Rapid sequential ---
echo ""
echo "[8/9] Rapid sequential commands..."
ALL_OK=true
for i in $(seq 1 5); do
    OUT=$(timeout 10 adb -s "$ADB_SERIAL" shell "echo seq_$i" 2>&1)
    echo "$OUT" | grep -qF "seq_$i" || { ALL_OK=false; log_fail "rapid $i" "$OUT"; }
done
$ALL_OK && log_pass "5 rapid sequential commands"

# --- Test 9: Port 0 + reply-fd (instant connect) ---
echo ""
echo "[9/9] Port 0 + reply-fd (instant connect)..."

# Create a named pipe for reply-fd
REPLY_PIPE=$(mktemp -u)
mkfifo "$REPLY_PIPE"

# Start a second mock-adbd with port 0, reply-fd 5 → pipe
bash "$PROJECT_DIR/scripts/run.sh" --port 0 --reply-fd 5 5>"$REPLY_PIPE" &
MOCK2_PID=$!

# Read port from reply-fd (blocks until ready)
MOCK2_PORT=$(head -1 "$REPLY_PIPE")
rm -f "$REPLY_PIPE"
MOCK2_SERIAL="localhost:$MOCK2_PORT"
echo "  Reply-fd returned port: $MOCK2_PORT"

# Instant connect — zero sleep after reply-fd
CONN_OUT=$(adb connect "$MOCK2_SERIAL" 2>&1)
assert_contains "reply-fd instant connect" "connected" "$CONN_OUT"

# Run a command to verify it actually works
OUTPUT=$(timeout 10 adb -s "$MOCK2_SERIAL" shell "echo replyfd_ok" 2>&1)
assert_contains "reply-fd shell" "replyfd_ok" "$OUTPUT"

# Cleanup second mock
adb disconnect "$MOCK2_SERIAL" 2>/dev/null || true
kill "$MOCK2_PID" 2>/dev/null || true
wait "$MOCK2_PID" 2>/dev/null || true

# ============================================================
echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed (total $TOTAL)"
echo "========================================"

[ "$FAIL" -gt 0 ] && exit 1
echo ""
echo "All tests passed! 🎉"

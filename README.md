# mock-adbd

A lightweight ADB daemon mock running inside a QEMU VM. One 16MB self-extracting script — just run it.

Supports `adb connect`, `adb shell` (interactive + single-command), shell v2, exit code propagation, concurrent connections.

## Quick Start

```bash
# macOS
brew install qemu

# Linux
sudo apt install qemu-system-x86

# Run
./mock-adbd.sh

# Connect
adb connect localhost:5555
adb shell
```

### Options

```
./mock-adbd.sh -p 15555     # Custom port
./mock-adbd.sh -m 256M      # More memory
./mock-adbd.sh -v            # Show boot logs
./mock-adbd.sh --extract .   # Extract without running
./mock-adbd.sh --help
```

## Platform Support

Works anywhere `qemu-system-x86_64` runs (TCG, no hardware virtualization needed):
- Linux x86_64
- macOS Intel / Apple Silicon
- CI environments (GitHub Actions, GitLab CI, etc.)

## Architecture

```
Host                                 QEMU VM (Alpine Linux x86_64)
┌─────────────────┐    TCP 5555     ┌──────────────────────┐
│  adb server(s)  │ ◄────────────► │  mock-adbd (Rust)     │
│  adb connect    │   SLIRP        │    ├── PTY + /bin/sh  │
│  adb shell      │   hostfwd      │    ├── Shell v1 + v2  │
└─────────────────┘                │    └── Multi-session  │
                                   └──────────────────────┘
```

- **Guest binary**: Static Rust binary (`x86_64-unknown-linux-musl`), ~1.3 MB
- **VM**: Alpine Linux initramfs, ~4 MB
- **Network**: QEMU SLIRP — zero host privileges needed
- **Single file**: 16 MB self-extracting bash script

## Features

- ✅ `adb shell <command>` + `adb shell` (interactive PTY)
- ✅ Shell v2 protocol (stdout/stderr separation, exit code)
- ✅ Exit code propagation
- ✅ Multiple concurrent ADB connections
- ✅ macOS + Linux
- ✅ No root / no sudo / no tap / no bridge

## Building from Source

```bash
# Prerequisites: Rust + x86_64-unknown-linux-musl target, curl, cpio, gzip
rustup target add x86_64-unknown-linux-musl

# Build
bash scripts/build-rootfs.sh

# Package
bash scripts/package.sh          # → dist/mock-adbd.sh

# Test
bash tests/integration_test.sh   # 20/20
```

## CI

```bash
bash scripts/ci-build.sh          # Build dist/mock-adbd.sh
bash scripts/ci-build.sh --test   # Build + integration tests (needs qemu + adb)
```

## Project Structure

```
mock-adbd/
├── guest-adbd/src/          # Rust ADB daemon (protocol.rs, session.rs, shell_v2.rs)
├── scripts/
│   ├── build-rootfs.sh      # Build Alpine rootfs + initramfs
│   ├── run.sh               # Dev-mode QEMU launcher
│   ├── stub.sh              # Self-extracting script template
│   ├── package.sh           # Assemble stub + payload → dist/mock-adbd.sh
│   └── ci-build.sh          # CI build (auto-installs deps)
├── tests/integration_test.sh
└── README.md
```

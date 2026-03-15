# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Dual-architecture (x86_64 + Raspberry Pi 5) unattended k3s cluster installer. Plug a USB/eSATA drive into a machine, power on, walk away. First node becomes the k3s server (discovered via mDNS); subsequent nodes auto-join as agents.

## Architecture

### Boot Flows

**x86_64:** USB UEFI → GRUB (ESP Part 1) → Ubuntu autoinstall from Part 2 → `late-commands` inject scripts to target disk → poweroff → remove USB → internal disk boot → `k3s-first-boot.service` → k3s running

**Pi 5:** USB boot → cloud-init → `pi-clone-to-nvme.sh` clones to NVMe → poweroff → remove USB → NVMe boot → `k3s-first-boot.service` → k3s running

**PXE (x86):** Network boot → dnsmasq TFTP serves GRUB EFI → HTTP serves ISO + autoinstall → same flow as USB x86

### Key Design Decisions

- **All scripts are embedded inside user-data template files** (`user-data-x86.template`, `user-data-pi.template`). There are no standalone script files deployed to target machines — everything is injected via cloud-init `write_files` (Pi) or autoinstall `late-commands` (x86).
- **Cluster isolation via mDNS**: Each cluster gets a unique mDNS service type (`_k3s-<name>._tcp`) so nodes on the same network only discover their own cluster.
- **Template substitution**: `lib/cluster.sh:apply_cluster_to_template` replaces `%%PLACEHOLDER%%` tokens in templates with values from `clusters/<name>.env` at prep time.
- **Sentinel files** control boot behavior: `.first-boot-pending` triggers k3s install, `.nvme-clone-done` (Pi only) gates first-boot until clone is complete.
- **Server installs Longhorn** for distributed persistent storage after k3s is ready.

### Script Roles

| Script | Runs on | Purpose |
|---|---|---|
| `prepare-usb.sh` | Linux | Creates 4-partition dual-arch drive (ESP, x86 installer, Pi boot, Pi root) |
| `prepare-pi-usb.sh` | macOS | Writes Pi image to USB via `dd`, injects cloud-init |
| `start-pxe-server.sh` | macOS/Linux | Runs dnsmasq (TFTP+DHCP proxy) + Python HTTP server for network boot |
| `fetch-kubeconfig.sh` | macOS/Linux | Discovers server via mDNS, SSHes in, fetches k3s.yaml |
| `lib/cluster.sh` | sourced | Shared library: `select_cluster`, `create_cluster`, `apply_cluster_to_template` |

### Drive Partition Layout (Dual-Arch)

```
Part 1:  1 GB    FAT32  ESP         — GRUB EFI for x86 UEFI boot
Part 2:  6 GB    ext4   x86-install — Ubuntu ISO contents + autoinstall user-data
Part 3:  300 MB  FAT32  pi-boot     — Pi firmware, kernel, config.txt, cloud-init
Part 4:  8 GB    ext4   pi-root     — Pi Ubuntu root filesystem
```

## Working with Templates

When modifying bootstrap behavior, edit the template files — not standalone scripts:
- `user-data-x86.template` — Ubuntu autoinstall format with `late-commands` that `cat` scripts into `/target/opt/k3s-bootstrap/`
- `user-data-pi.template` — cloud-init format with `write_files` sections

Both templates contain identical copies of `first-boot.sh`, `every-boot.sh`, and `k3s-config.env`. Changes to bootstrap logic must be applied to **both templates** to keep architectures in sync.

Placeholder format: `%%VARIABLE_NAME%%` (e.g., `%%CLUSTER_NAME%%`, `%%K3S_TOKEN%%`, `%%K3S_MDNS_SERVICE%%`)

## Cluster Profiles

Stored in `clusters/<name>.env`. Key variables: `CLUSTER_NAME`, `K3S_TOKEN`, `K3S_MDNS_SERVICE`, `K3S_EXTRA_SERVER_ARGS`, `K3S_EXTRA_AGENT_ARGS`, `K3S_VERSION`, `LONGHORN_VERSION`. The `example.env` is a template and is skipped by `select_cluster`.

## Common Commands

```bash
# Flash dual-arch USB (Linux only, requires root)
sudo bash prepare-usb.sh
sudo bash prepare-usb.sh --cluster mes-edge /dev/sdX

# Flash Pi-only USB (macOS)
sudo bash prepare-pi-usb.sh

# PXE boot server (macOS/Linux)
sudo bash start-pxe-server.sh

# Fetch kubeconfig after first node is up
./fetch-kubeconfig.sh --cluster mes-edge
./fetch-kubeconfig.sh --cluster mes-edge 192.168.8.188
```

## Shell Conventions

All scripts use `set -euo pipefail`, colored log/warn/die helpers, and interactive selection menus with auto-select when only one option exists. All prep scripts source `lib/cluster.sh` for cluster profile management.

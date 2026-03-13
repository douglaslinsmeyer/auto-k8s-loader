# K3s Auto-Installer USB (Dual-Arch)

One USB drive that auto-installs Ubuntu 24.04 + k3s on both x86_64 PCs and Raspberry Pi 5 (with NVMe). First node creates the cluster; subsequent nodes auto-join via mDNS.

## Architecture Support

| Target | Boot method | Install target | How it works |
|---|---|---|---|
| x86_64 (Intel/AMD) | UEFI boot from USB | Internal disk (SSD/HDD) | Ubuntu autoinstall → poweroff → remove USB → k3s on first boot |
| Raspberry Pi 5 | Pi bootloader from USB | NVMe (via M.2 HAT) | Boots Ubuntu from USB → clones to NVMe → poweroff → remove USB → k3s on first boot |

## Files

| File | Purpose |
|---|---|
| `prepare-usb.sh` | Flashes the USB drive (**run from Linux**) |
| `user-data` | x86_64 Ubuntu autoinstall config |
| `user-data-pi` | Pi 5 cloud-init config |
| `meta-data` | Empty file required by cloud-init |
| `k3s-config.env` | Cluster settings — **edit before flashing** |
| `first-boot.sh` | Runs once: installs k3s, discovers or creates cluster |
| `every-boot.sh` | Runs every boot: health checks, service restart, cleanup |
| `pi-clone-to-nvme.sh` | Pi-only: clones USB system to NVMe SSD |

## USB Drive Partition Layout

```
Part 1:  1 GB   FAT32  EFI System Partition (GRUB for x86 + shared configs)
Part 2:  6 GB   ext4   x86_64 Ubuntu installer files
Part 3:  300 MB FAT32  Pi 5 boot partition (firmware, kernel, config.txt)
Part 4:  6 GB   ext4   Pi 5 root filesystem
         ~240 GB        (unused / free)
```

The Pi bootloader scans for FAT32 partitions with `config.txt` — it finds Part 3. x86 UEFI scans for an ESP with `EFI/BOOT/BOOTX64.EFI` — it finds Part 1. They don't interfere.

## Quick Start

### 1. Edit the config

```bash
nano k3s-config.env
```

`K3S_TOKEN` is already set. Verify the other settings are what you want.

### 2. Run prepare-usb.sh from Linux

This script **must run from Linux** because it creates ext4 partitions. Options:

- Run from an existing Ubuntu machine
- Boot any PC from a Ubuntu live USB and run from there
- Use a VM with USB passthrough

```bash
# Install prerequisites
sudo apt install -y parted dosfstools e2fsprogs grub-efi-amd64-bin \
                    xorriso rsync curl xz-utils

# Flash the drive (replace /dev/sdX with your USB device)
sudo bash prepare-usb.sh /dev/sdX
```

This downloads ~4.6 GB of images (x86 ISO + Pi ARM64 image) on the first run. They're cached locally for re-runs.

### 3. Deploy to x86_64 machines

1. Plug USB into target machine
2. Boot from USB (F12/F2/Del for BIOS boot menu)
3. Select **"Install Ubuntu 24.04 (x86_64) - K3s Autoinstall"**
4. Ubuntu installs unattended → machine powers off
5. Remove USB, power on → k3s bootstraps on first boot

### 4. Deploy to Raspberry Pi 5

Prerequisites: Pi 5 with NVMe SSD via M.2 HAT. EEPROM should allow USB boot (default on recent firmware).

1. Plug USB into Pi 5
2. Power on — Pi boots Ubuntu from USB
3. System auto-clones itself to NVMe (~3-5 min)
4. Pi powers off
5. Remove USB, power on → Pi boots from NVMe, k3s bootstraps

### 5. Repeat

Same USB drive, next machine. Each new node discovers existing servers via mDNS and joins automatically.

## Cluster Discovery

- **First node** (any arch): No mDNS servers found → initialises as k3s server → advertises `_k3s-server._tcp` via Avahi
- **Subsequent nodes**: Discover the server → join as agents
- **Override**: Set `K3S_FORCE_ROLE=server` or `agent` in `k3s-config.env`
- **Mixed-arch**: Works fine — k3s handles x86_64 and ARM64 nodes in the same cluster

## Default Credentials

| | |
|---|---|
| Username | `k3sadmin` |
| Password | `k3sadmin` |
| SSH | Enabled (password auth) |

Change for production by updating the password hash in `user-data` and `user-data-pi`.

```bash
# Generate a new password hash
mkpasswd --method=SHA-512 yourpassword
```

## Post-Install Access

```bash
# SSH into a node (hostname is k3s-<mac-suffix>)
ssh k3sadmin@k3s-XXXX.local

# On a server node, check cluster
kubectl get nodes -o wide
```

## Troubleshooting

### x86 machines
```bash
journalctl -u k3s-first-boot.service
cat /var/log/k3s-bootstrap.log
```

### Pi 5
```bash
# If NVMe clone failed (still booted from USB):
journalctl -u pi-clone-to-nvme.service
cat /var/log/k3s-bootstrap.log

# Re-run clone manually:
sudo /opt/k3s-bootstrap/pi-clone-to-nvme.sh

# If Pi doesn't boot from NVMe after clone:
# Check EEPROM boot order:
sudo rpi-eeprom-config
# Set NVMe first:
sudo rpi-eeprom-config --edit
# Change BOOT_ORDER to: BOOT_ORDER=0xf6142
```

### General
```bash
# Force re-run first boot
sudo touch /opt/k3s-bootstrap/.first-boot-pending
sudo systemctl start k3s-first-boot.service

# Check k3s service
journalctl -u k3s.service        # server
journalctl -u k3s-agent.service  # agent
```

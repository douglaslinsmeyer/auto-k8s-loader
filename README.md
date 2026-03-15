# K3s Auto-Installer USB — Dual Architecture

One USB/eSATA drive that auto-installs Ubuntu 24.04 + k3s on both x86_64 machines and Raspberry Pi 5 with NVMe. Plug in, power on, walk away. First node creates the cluster; subsequent nodes auto-join via mDNS.

## How It Works

### x86_64 (Intel/AMD)

1. Machine boots from USB via UEFI
2. GRUB loads Ubuntu autoinstall (3-second timeout)
3. Ubuntu installs unattended to internal disk, injects k3s scripts via `late-commands`
4. Machine powers off — you remove the USB
5. Machine boots from internal disk, `k3s-first-boot.service` installs k3s
6. On every subsequent boot, `k3s-every-boot.service` runs health checks

### Raspberry Pi 5

1. Pi 5 boots Ubuntu from USB
2. Cloud-init sets up user, SSH, packages
3. `pi-clone-to-nvme.sh` clones the entire system to the NVMe SSD
4. Pi powers off — you remove the USB
5. Pi boots from NVMe, `k3s-first-boot.service` installs k3s
6. On every subsequent boot, `k3s-every-boot.service` runs health checks

### Cluster Auto-Discovery

The first node (either architecture) finds no existing k3s servers via mDNS and initialises as a server. It publishes `_k3s-server._tcp` via Avahi. Every subsequent node discovers this and joins as an agent.

Override with the `K3S_FORCE_ROLE` setting if needed.

## Prerequisites

### For dual-arch drive (recommended)

- A running Linux machine (e.g. one of your Pi nodes)
- USB/eSATA drive (16 GB minimum)

### For Pi-only drive (macOS)

- macOS with `xz` installed (`brew install xz`)
- USB/eSATA drive (8 GB minimum)

### Target machines

- x86_64: UEFI boot support
- Pi 5: NVMe SSD via M.2 HAT, USB in EEPROM boot order

## Quick Start

### Option A: Dual-arch drive (from Linux)

```bash
# SSH into a Pi node (or any Linux machine)
ssh k3sadmin@<pi-ip>

# Clone repo
git clone https://github.com/<user>/auto-k8s-loader.git
cd auto-k8s-loader

# Find your USB/eSATA device
lsblk

# Flash the drive
sudo bash prepare-usb.sh /dev/sdX
```

This downloads both images (~4.5 GB total), partitions the drive (ESP + x86 installer + Pi boot + Pi root), and injects all configs. Takes about 10-15 minutes.

### Option B: Pi-only drive (from macOS)

```bash
brew install xz    # if not already installed
sudo bash prepare-pi-usb.sh /dev/diskN    # replace with your device
```

### Deploy

1. Plug USB into target machine (x86 or Pi), power on
2. Wait for automatic install (5-15 min depending on hardware)
3. Machine powers off automatically
4. Remove USB, power on — k3s bootstraps on first boot
5. Plug the same USB into the next machine and repeat

## Edit Your Cluster Token

Open `user-data-pi` and `user-data-x86` and find the `K3S_TOKEN` line. The current token is pre-generated but you can replace it:

```bash
openssl rand -hex 32
```

All nodes must share the same token. Update it in both user-data files.

## Files

| File | Purpose |
|---|---|
| `prepare-usb.sh` | Dual-arch drive prep (runs on Linux) |
| `prepare-pi-usb.sh` | Pi-only drive prep (runs on macOS) |
| `user-data-x86` | Ubuntu autoinstall config with embedded k3s scripts |
| `user-data-pi` | Cloud-init config with embedded k3s scripts |
| `k3s-config.env` | Reference copy of cluster config (actual config is embedded in user-data files) |
| `meta-data` | Empty file required by cloud-init |

Everything (first-boot.sh, every-boot.sh, pi-clone-to-nvme.sh, systemd units) is embedded inside the user-data files.

## Default Credentials

| | |
|---|---|
| Username | `k3sadmin` |
| Password | `k3sadmin` |
| SSH | Enabled (password auth) |

Change for production by updating the password hash in both user-data files:

```bash
mkpasswd --method=SHA-512 yourpassword
```

## Drive Partition Layout (Dual-Arch)

```
Part 1:  1 GB    FAT32  ESP         — GRUB EFI for x86 UEFI boot
Part 2:  6 GB    ext4   x86-install — Ubuntu ISO contents + autoinstall user-data
Part 3:  300 MB  FAT32  pi-boot     — Pi firmware, kernel, config.txt, cloud-init
Part 4:  4 GB    ext4   pi-root     — Pi Ubuntu root filesystem
```

x86 UEFI finds the ESP (Part 1), loads GRUB, which boots the installer from Part 2. Pi firmware scans FAT32 partitions for `config.txt`, finds it on Part 3 (not Part 1, which has no `config.txt`), and boots from Parts 3+4.

## Monitoring

```bash
# Find a node on your network
ping k3s-<last-6-mac>.local

# SSH in
ssh k3sadmin@<ip>

# Watch bootstrap progress
tail -f /var/log/k3s-bootstrap.log
journalctl -f -u k3s-first-boot.service

# Check cluster
export KUBECONFIG=~/.kube/config
kubectl get nodes
```

## Troubleshooting

```bash
# x86: check autoinstall logs (during install, before poweroff)
cat /var/log/installer/autoinstall-user-data
journalctl -u subiquity

# Pi: check NVMe clone
journalctl -u pi-clone-to-nvme.service

# Both: check k3s first boot
journalctl -u k3s-first-boot.service

# Both: check k3s service
journalctl -u k3s.service        # server
journalctl -u k3s-agent.service  # agent

# Full bootstrap log
cat /var/log/k3s-bootstrap.log

# Re-run first boot manually
sudo touch /opt/k3s-bootstrap/.first-boot-pending
sudo systemctl start k3s-first-boot.service

# Pi: re-run NVMe clone
sudo rm -f /opt/k3s-bootstrap/.nvme-clone-done
sudo systemctl start pi-clone-to-nvme.service

# Pi: check/set boot order
sudo rpi-eeprom-config          # view
sudo rpi-eeprom-config --edit   # set BOOT_ORDER=0xf6142
```

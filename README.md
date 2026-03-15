# K3s Auto-Installer — Dual Architecture, Multi-Cluster

One USB/eSATA drive that auto-installs Ubuntu 24.04 + k3s on both x86_64 machines and Raspberry Pi 5 with NVMe. Plug in, power on, walk away. First node creates the cluster; subsequent nodes auto-join via mDNS.

Supports multiple independent clusters via named profiles — each with its own token, mDNS service, and k3s configuration.

## How It Works

### x86_64 (Intel/AMD)

1. Machine boots from USB via UEFI (or PXE)
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

The first node (either architecture) finds no existing k3s servers via mDNS and initialises as a server. It publishes the cluster's mDNS service via Avahi. Every subsequent node discovers this and joins as an agent. Each cluster uses a unique mDNS service name to prevent cross-cluster joins.

Override with the `K3S_FORCE_ROLE` setting in the cluster profile if needed.

## Multi-Cluster Support

Cluster profiles live in `clusters/*.env`. Each profile contains a cluster name, token, mDNS service type, and k3s arguments. All prep scripts prompt you to select a cluster (or create a new one) before flashing.

```bash
# List clusters and pick one interactively
sudo bash prepare-usb.sh

# Use a specific cluster by name
sudo bash prepare-usb.sh --cluster mes-edge /dev/sdX

# Create a new cluster (interactive wizard if no profiles exist)
sudo bash prepare-usb.sh
# → select "n) Create a new cluster"
```

To create a cluster profile manually:

```bash
cat > clusters/my-cluster.env <<'EOF'
CLUSTER_NAME="my-cluster"
K3S_TOKEN="$(openssl rand -hex 32)"
K3S_MDNS_SERVICE="_k3s-my-cluster._tcp"
K3S_EXTRA_SERVER_ARGS="--disable traefik"
K3S_EXTRA_AGENT_ARGS=""
K3S_VERSION=""
EOF
```

All nodes in a cluster must share the same token. The mDNS service name isolates clusters on the same network.

## Prerequisites

### For dual-arch drive (recommended)

- A running Linux machine (e.g. one of your Pi nodes)
- USB/eSATA drive (16 GB minimum)

### For Pi-only drive (macOS)

- macOS with `xz` installed (`brew install xz`)
- USB/eSATA drive (8 GB minimum)

### For PXE boot (x86 machines that can't boot from USB)

- macOS or Linux machine on the same LAN
- Dependencies installed automatically by the script (`dnsmasq`, `p7zip`)

### Target machines

- x86_64: UEFI boot support (USB or PXE)
- Pi 5: NVMe SSD via M.2 HAT, USB in EEPROM boot order

## Quick Start

### Option A: Dual-arch drive (from Linux)

```bash
# SSH into a Pi node (or any Linux machine)
ssh k3sadmin@<pi-ip>

# Clone repo
git clone https://github.com/<user>/auto-k8s-loader.git
cd auto-k8s-loader

# Flash the drive (interactive disk + cluster selection)
sudo bash prepare-usb.sh
```

This downloads both images (~4.5 GB total), partitions the drive (ESP + x86 installer + Pi boot + Pi root), and injects all configs. Takes about 10-15 minutes.

### Option B: Pi-only drive (from macOS)

```bash
brew install xz
sudo bash prepare-pi-usb.sh
```

### Option C: PXE boot for x86 (from macOS or Linux)

```bash
sudo bash start-pxe-server.sh
# On target x86 machine: boot from network (PXE / Onboard NIC IPv4)
```

### Deploy

1. Plug USB into target machine (x86 or Pi), power on
2. Wait for automatic install (5-15 min depending on hardware)
3. Machine powers off automatically
4. Remove USB, power on — k3s bootstraps on first boot
5. Plug the same USB into the next machine and repeat

### Fetch Kubeconfig

```bash
# Auto-discover server via mDNS and save kubeconfig
./fetch-kubeconfig.sh --cluster mes-edge

# Or specify server IP directly
./fetch-kubeconfig.sh --cluster mes-edge 192.168.8.188

# Use it
export KUBECONFIG=~/.kube/config-mes-edge
kubectl get nodes
```

## Files

| File | Purpose |
|---|---|
| `prepare-usb.sh` | Dual-arch drive prep (runs on Linux) |
| `prepare-pi-usb.sh` | Pi-only drive prep (runs on macOS) |
| `start-pxe-server.sh` | PXE boot server for x86 machines |
| `fetch-kubeconfig.sh` | Fetches kubeconfig from the k3s server node |
| `user-data-x86.template` | Ubuntu autoinstall template with embedded k3s scripts |
| `user-data-pi.template` | Cloud-init template with embedded k3s scripts |
| `lib/cluster.sh` | Shared cluster profile management library |
| `clusters/*.env` | Cluster profiles (token, mDNS, k3s args) |

Everything (first-boot.sh, every-boot.sh, pi-clone-to-nvme.sh, systemd units) is embedded inside the user-data template files. Cluster-specific values are substituted at prep time via `%%PLACEHOLDER%%` syntax.

## Default Credentials

| | |
|---|---|
| Username | `k3sadmin` |
| Password | `k3sadmin` |
| SSH | Enabled (password auth) |

Change for production by updating the password hash in both template files:

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
export KUBECONFIG=~/.kube/config-<cluster-name>
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

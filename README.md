# K3s Auto-Installer USB — Raspberry Pi 5

One USB/eSATA drive that auto-installs Ubuntu 24.04 + k3s on Raspberry Pi 5 with NVMe. Plug in, power on, walk away. First node creates the cluster; subsequent nodes auto-join via mDNS.

## How It Works

1. Pi 5 boots Ubuntu from USB
2. Cloud-init sets up user, SSH, packages
3. `pi-clone-to-nvme.sh` clones the entire system to the NVMe SSD
4. Pi powers off — you remove the USB
5. Pi boots from NVMe, `first-boot.sh` installs k3s (server or agent)
6. On every subsequent boot, `every-boot.sh` runs health checks

## Prerequisites

- Raspberry Pi 5 with NVMe SSD (via M.2 HAT)
- Pi firmware that allows USB boot (default on recent EEPROM)
- macOS with `xz` installed (`brew install xz`)

## Quick Start

### 1. Edit your cluster token

Open `user-data-pi` and find the `K3S_TOKEN` line in the `k3s-config.env` section. The current token is pre-generated but you can replace it:

```bash
openssl rand -hex 32
```

All nodes must share the same token.

### 2. Flash the USB drive

```bash
brew install xz    # if not already installed
sudo bash prepare-pi-usb.sh /dev/disk4    # replace with your device
```

This downloads the Ubuntu Pi image (~2 GB compressed), writes it to the drive, and injects the cloud-init config. Takes about 5 minutes.

### 3. Deploy

1. Plug USB into Pi 5, power on
2. Wait ~5-10 min (Pi boots from USB, clones to NVMe, powers off)
3. Remove USB
4. Power on — Pi boots from NVMe, k3s installs on first boot
5. Plug the same USB into the next Pi and repeat

### 4. Cluster auto-discovery

The first Pi finds no existing k3s servers via mDNS and initialises as a server. It publishes `_k3s-server._tcp` via Avahi. Every subsequent Pi discovers this and joins as an agent.

Override with the `K3S_FORCE_ROLE` setting in user-data-pi if needed.

## Files

| File | Purpose |
|---|---|
| `prepare-pi-usb.sh` | Flashes the USB drive (runs on macOS) |
| `user-data-pi` | All-in-one cloud-init config with embedded scripts |
| `meta-data` | Empty file required by cloud-init |

Everything else (first-boot.sh, every-boot.sh, pi-clone-to-nvme.sh, k3s-config.env, systemd units) is embedded inside `user-data-pi` via cloud-init's `write_files`.

## Default Credentials

| | |
|---|---|
| Username | `k3sadmin` |
| Password | `k3sadmin` |
| SSH | Enabled (password auth) |

Change for production by updating the password hash in `user-data-pi`:

```bash
mkpasswd --method=SHA-512 yourpassword
```

## Monitoring the Process

Since the Pis are headless, you can monitor via SSH once the Pi gets a DHCP address:

```bash
# Find the Pi on your network (after it boots from USB)
ping k3s-pi-node.local

# SSH in
ssh k3sadmin@k3s-pi-node.local

# Watch the clone/bootstrap progress
tail -f /var/log/k3s-bootstrap.log
journalctl -f -u pi-clone-to-nvme.service
journalctl -f -u k3s-first-boot.service
```

## Troubleshooting

```bash
# Check NVMe clone status
journalctl -u pi-clone-to-nvme.service

# Check k3s first boot
journalctl -u k3s-first-boot.service

# Check k3s service
journalctl -u k3s.service        # server
journalctl -u k3s-agent.service  # agent

# Full bootstrap log
cat /var/log/k3s-bootstrap.log

# Re-run first boot manually
sudo touch /opt/k3s-bootstrap/.first-boot-pending
sudo systemctl start k3s-first-boot.service

# Re-run NVMe clone (if it failed)
sudo rm -f /opt/k3s-bootstrap/.nvme-clone-done
sudo systemctl start pi-clone-to-nvme.service

# Check/set Pi boot order manually
sudo rpi-eeprom-config          # view
sudo rpi-eeprom-config --edit   # set BOOT_ORDER=0xf6142
```

## Adding x86_64 Support Later

The `prepare-usb.sh` script (also in this repo) supports a dual-arch drive with both x86 and Pi partitions. It requires running from a Linux machine. See the comments in that script for details.

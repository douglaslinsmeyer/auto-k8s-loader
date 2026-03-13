#!/usr/bin/env bash
# ── prepare-usb.sh ──────────────────────────────────────────────────
# Prepares a USB/eSATA drive as a DUAL-ARCH unattended Ubuntu 24.04
# autoinstaller for k3s cluster nodes.
#
# Supports:
#   - x86_64 (Intel/AMD) PCs  → standard Ubuntu autoinstall
#   - ARM64  (Raspberry Pi 5)  → preinstalled image cloned to NVMe
#
# !! MUST BE RUN FROM LINUX !!
# (ext4 partition creation is required; macOS cannot do this)
#
# If you don't have a Linux machine yet, boot any PC from a Ubuntu
# live USB and run this script from there.
#
# Usage:  sudo ./prepare-usb.sh /dev/sdX
#
# Prerequisites:
#   apt install -y parted dosfstools e2fsprogs grub-efi-amd64-bin \
#                  xorriso rsync curl qemu-utils xz-utils
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ── Platform check ──────────────────────────────────────────────────
[[ "$(uname)" != "Linux" ]] && die "This script must be run from Linux (ext4 partitions required). Boot a Ubuntu live USB if needed."
[[ $EUID -ne 0 ]] && die "Must be run as root (sudo)."

# ── Validate args ───────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    echo "Usage: sudo $0 /dev/sdX"
    echo ""
    echo "Run 'lsblk -o NAME,SIZE,TYPE,TRAN,MODEL' to find your USB drive."
    exit 1
fi

DEVICE="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Safety: refuse to operate on the root disk
ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
[[ "$DEVICE" == "$ROOT_DEV"* ]] && die "Refusing to operate on root disk $ROOT_DEV"

# Verify device exists and is a block device
[[ ! -b "$DEVICE" ]] && die "$DEVICE is not a block device."

# ── URLs & Files ────────────────────────────────────────────────────
X86_ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso"
PI_IMG_URL="https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.2-preinstalled-server-arm64+raspi.img.xz"

X86_ISO="${SCRIPT_DIR}/ubuntu-24.04-server-amd64.iso"
PI_IMG_XZ="${SCRIPT_DIR}/ubuntu-24.04-server-arm64-raspi.img.xz"
PI_IMG="${SCRIPT_DIR}/ubuntu-24.04-server-arm64-raspi.img"

WORK_DIR=$(mktemp -d /tmp/k3s-usb.XXXXXX)
trap 'cleanup' EXIT

cleanup() {
    log "Cleaning up..."
    # Unmount everything we might have mounted
    for mp in "${WORK_DIR}"/*/; do
        mountpoint -q "$mp" 2>/dev/null && umount -l "$mp" 2>/dev/null || true
    done
    # Detach any loop devices we set up
    losetup -j "$PI_IMG" 2>/dev/null | cut -d: -f1 | while read -r lo; do
        losetup -d "$lo" 2>/dev/null || true
    done
    rm -rf "$WORK_DIR"
}

# ── Helper: partition device path ───────────────────────────────────
# /dev/sda  → /dev/sda1
# /dev/nvme0n1 → /dev/nvme0n1p1
part_path() {
    local dev="$1" num="$2"
    if [[ "$dev" =~ [0-9]$ ]]; then
        echo "${dev}p${num}"
    else
        echo "${dev}${num}"
    fi
}

# ══════════════════════════════════════════════════════════════════════
#  STEP 1: Download images
# ══════════════════════════════════════════════════════════════════════
log "Step 1/7: Downloading images..."

if [[ -f "$X86_ISO" ]]; then
    info "Found existing x86_64 ISO"
else
    log "Downloading Ubuntu 24.04 Server x86_64 (~2.6 GB)..."
    curl -L -# -o "$X86_ISO" "$X86_ISO_URL" || die "x86 ISO download failed."
fi

if [[ -f "$PI_IMG" ]]; then
    info "Found existing Pi ARM64 image (decompressed)"
elif [[ -f "$PI_IMG_XZ" ]]; then
    info "Found existing Pi ARM64 image (compressed), decompressing..."
    xz -dk "$PI_IMG_XZ" || die "Decompression failed."
else
    log "Downloading Ubuntu 24.04 Server ARM64 for Pi (~2.0 GB compressed)..."
    curl -L -# -o "$PI_IMG_XZ" "$PI_IMG_URL" || die "Pi image download failed."
    log "Decompressing Pi image..."
    xz -dk "$PI_IMG_XZ" || die "Decompression failed."
fi

# ══════════════════════════════════════════════════════════════════════
#  STEP 2: Partition the USB drive
# ══════════════════════════════════════════════════════════════════════
log ""
log "Step 2/7: Partitioning ${DEVICE}"
log ""
log "═══════════════════════════════════════════════════════════════"
log "  Target:  ${DEVICE}"
log "  Size:    $(lsblk -dno SIZE "$DEVICE" 2>/dev/null || echo 'unknown')"
log "  Model:   $(lsblk -dno MODEL "$DEVICE" 2>/dev/null || echo 'unknown')"
log ""
log "  Partition layout:"
log "    Part 1:  1 GB   FAT32  EFI System (GRUB x86 + Pi firmware)"
log "    Part 2:  6 GB   ext4   x86_64 Ubuntu installer"
log "    Part 3:  300 MB FAT32  Pi boot (system-boot)"
log "    Part 4:  6 GB   ext4   Pi root filesystem"
log "    (rest of drive unused / free)"
log ""
log "  ALL DATA ON THIS DEVICE WILL BE DESTROYED."
log "═══════════════════════════════════════════════════════════════"
log ""
read -rp "Type 'YES' to continue: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && die "Aborted."

# Unmount all partitions
umount "${DEVICE}"* 2>/dev/null || true
umount "$(part_path "$DEVICE" 1)" 2>/dev/null || true
umount "$(part_path "$DEVICE" 2)" 2>/dev/null || true
umount "$(part_path "$DEVICE" 3)" 2>/dev/null || true
umount "$(part_path "$DEVICE" 4)" 2>/dev/null || true

# Wipe and create GPT
wipefs -af "$DEVICE" >/dev/null 2>&1
sgdisk --zap-all "$DEVICE" >/dev/null 2>&1 || true
parted -s "$DEVICE" mklabel gpt

# Create partitions
# Part 1: ESP (FAT32, 1GB) — holds GRUB EFI for x86 + Pi firmware + shared configs
parted -s "$DEVICE" mkpart "ESP" fat32 1MiB 1025MiB
parted -s "$DEVICE" set 1 esp on
parted -s "$DEVICE" set 1 boot on

# Part 2: x86 installer (ext4, 6GB) — Ubuntu ISO contents + autoinstall
parted -s "$DEVICE" mkpart "x86-installer" ext4 1025MiB 7169MiB

# Part 3: Pi boot (FAT32, 300MB) — Pi firmware, kernel, config.txt
parted -s "$DEVICE" mkpart "pi-boot" fat32 7169MiB 7469MiB

# Part 4: Pi root (ext4, 6GB) — Ubuntu ARM64 root filesystem
parted -s "$DEVICE" mkpart "pi-root" ext4 7469MiB 13613MiB

# Let kernel re-read partition table
partprobe "$DEVICE" 2>/dev/null || true
sleep 2

P1=$(part_path "$DEVICE" 1)
P2=$(part_path "$DEVICE" 2)
P3=$(part_path "$DEVICE" 3)
P4=$(part_path "$DEVICE" 4)

# Format partitions
log "Formatting partitions..."
mkfs.fat -F 32 -n "K3S_EFI" "$P1"
mkfs.ext4 -F -L "K3S_X86" "$P2"
mkfs.fat -F 32 -n "K3S_PIBOOT" "$P3"
mkfs.ext4 -F -L "K3S_PIROOT" "$P4"

# ══════════════════════════════════════════════════════════════════════
#  STEP 3: Set up x86_64 installer (Part 1 ESP + Part 2 data)
# ══════════════════════════════════════════════════════════════════════
log "Step 3/7: Setting up x86_64 installer..."

MNT_ESP="${WORK_DIR}/esp"
MNT_X86="${WORK_DIR}/x86"
MNT_ISO="${WORK_DIR}/iso"
mkdir -p "$MNT_ESP" "$MNT_X86" "$MNT_ISO"

mount "$P1" "$MNT_ESP"
mount "$P2" "$MNT_X86"
mount -o loop,ro "$X86_ISO" "$MNT_ISO"

# Copy ISO contents to x86 partition
log "  Copying x86_64 installer files (~2.5 GB)..."
rsync -a --info=progress2 "$MNT_ISO/" "$MNT_X86/"

# Copy autoinstall configs to x86 partition
mkdir -p "${MNT_X86}/autoinstall"
cp "${SCRIPT_DIR}/user-data"  "${MNT_X86}/autoinstall/user-data"
cp "${SCRIPT_DIR}/meta-data"  "${MNT_X86}/autoinstall/meta-data"
mkdir -p "${MNT_X86}/nocloud"
cp "${SCRIPT_DIR}/user-data"  "${MNT_X86}/nocloud/user-data"
cp "${SCRIPT_DIR}/meta-data"  "${MNT_X86}/nocloud/meta-data"

# Copy k3s scripts to x86 partition (installer's late-commands read from here)
mkdir -p "${MNT_X86}/k3s-scripts"
cp "${SCRIPT_DIR}/first-boot.sh"   "${MNT_X86}/k3s-scripts/first-boot.sh"
cp "${SCRIPT_DIR}/every-boot.sh"   "${MNT_X86}/k3s-scripts/every-boot.sh"
cp "${SCRIPT_DIR}/k3s-config.env"  "${MNT_X86}/k3s-scripts/k3s-config.env"

# Set up GRUB on ESP
log "  Installing GRUB EFI bootloader..."
mkdir -p "${MNT_ESP}/EFI/BOOT"

# Copy GRUB EFI binary from ISO
if [[ -f "${MNT_ISO}/EFI/BOOT/BOOTx64.EFI" ]]; then
    cp "${MNT_ISO}/EFI/BOOT/BOOTx64.EFI" "${MNT_ESP}/EFI/BOOT/BOOTX64.EFI"
    cp "${MNT_ISO}/EFI/BOOT/grubx64.efi"  "${MNT_ESP}/EFI/BOOT/grubx64.efi" 2>/dev/null || true
elif [[ -f "${MNT_ISO}/EFI/BOOT/BOOTX64.EFI" ]]; then
    cp "${MNT_ISO}/EFI/BOOT/BOOTX64.EFI" "${MNT_ESP}/EFI/BOOT/BOOTX64.EFI"
    cp "${MNT_ISO}/EFI/BOOT/grubx64.efi"  "${MNT_ESP}/EFI/BOOT/grubx64.efi" 2>/dev/null || true
else
    # Fallback: use grub-install
    grub-install --target=x86_64-efi --efi-directory="$MNT_ESP" \
        --boot-directory="${MNT_ESP}/boot" --removable --no-nvram 2>/dev/null || \
        warn "GRUB EFI install failed — x86 UEFI boot may not work"
fi

# Copy GRUB modules from ISO
if [[ -d "${MNT_ISO}/boot/grub" ]]; then
    mkdir -p "${MNT_ESP}/boot/grub"
    rsync -a "${MNT_ISO}/boot/grub/" "${MNT_ESP}/boot/grub/" 2>/dev/null || true
fi

# Get the UUID of partition 2 (x86 installer)
X86_UUID=$(blkid -s UUID -o value "$P2")

# Write GRUB config that boots the Ubuntu installer from partition 2
cat > "${MNT_ESP}/boot/grub/grub.cfg" <<GRUBCFG
set default=0
set timeout=3

menuentry "Install Ubuntu 24.04 (x86_64) - K3s Autoinstall" {
    search --no-floppy --fs-uuid --set=root ${X86_UUID}
    set gfxpayload=keep
    linux /casper/vmlinuz quiet autoinstall ds=nocloud\;s=/cdrom/autoinstall/ ---
    initrd /casper/initrd
}

menuentry "Install Ubuntu 24.04 (x86_64) - Interactive" {
    search --no-floppy --fs-uuid --set=root ${X86_UUID}
    set gfxpayload=keep
    linux /casper/vmlinuz ---
    initrd /casper/initrd
}
GRUBCFG

# Also make autoinstall configs accessible from the standard /cdrom path
# The Ubuntu installer mounts the boot source at /cdrom
mkdir -p "${MNT_X86}/cdrom"
ln -sf ../autoinstall "${MNT_X86}/cdrom/autoinstall" 2>/dev/null || \
    cp -r "${MNT_X86}/autoinstall" "${MNT_X86}/cdrom/autoinstall" 2>/dev/null || true

umount "$MNT_ISO"

# ══════════════════════════════════════════════════════════════════════
#  STEP 4: Set up Pi 5 installer (Part 3 boot + Part 4 root)
# ══════════════════════════════════════════════════════════════════════
log "Step 4/7: Setting up Pi 5 ARM64 installer..."

MNT_PIBOOT="${WORK_DIR}/pi-boot"
MNT_PIROOT="${WORK_DIR}/pi-root"
MNT_PIIMG_BOOT="${WORK_DIR}/piimg-boot"
MNT_PIIMG_ROOT="${WORK_DIR}/piimg-root"
mkdir -p "$MNT_PIBOOT" "$MNT_PIROOT" "$MNT_PIIMG_BOOT" "$MNT_PIIMG_ROOT"

mount "$P3" "$MNT_PIBOOT"
mount "$P4" "$MNT_PIROOT"

# Mount the Pi image's two partitions via loop device
LOOP_DEV=$(losetup --find --show --partscan "$PI_IMG")
sleep 1

# Pi image layout: partition 1 = FAT32 boot, partition 2 = ext4 root
PIIMG_P1="${LOOP_DEV}p1"
PIIMG_P2="${LOOP_DEV}p2"

if [[ ! -b "$PIIMG_P1" ]] || [[ ! -b "$PIIMG_P2" ]]; then
    # Fallback: calculate offsets manually
    BOOT_OFFSET=$(fdisk -l "$PI_IMG" | awk '/^.*img1/{print $2 * 512}')
    ROOT_OFFSET=$(fdisk -l "$PI_IMG" | awk '/^.*img2/{print $2 * 512}')
    losetup -d "$LOOP_DEV" 2>/dev/null
    LOOP_BOOT=$(losetup --find --show --offset "$BOOT_OFFSET" "$PI_IMG")
    LOOP_ROOT=$(losetup --find --show --offset "$ROOT_OFFSET" "$PI_IMG")
    mount "$LOOP_BOOT" "$MNT_PIIMG_BOOT"
    mount "$LOOP_ROOT" "$MNT_PIIMG_ROOT"
else
    mount "$PIIMG_P1" "$MNT_PIIMG_BOOT"
    mount "$PIIMG_P2" "$MNT_PIIMG_ROOT"
fi

# Copy Pi boot files
log "  Copying Pi boot partition..."
rsync -a "$MNT_PIIMG_BOOT/" "$MNT_PIBOOT/"

# Copy Pi root filesystem
log "  Copying Pi root filesystem (~3-4 GB, this takes a few minutes)..."
rsync -a --info=progress2 "$MNT_PIIMG_ROOT/" "$MNT_PIROOT/"

# Unmount Pi image
umount "$MNT_PIIMG_BOOT" 2>/dev/null || true
umount "$MNT_PIIMG_ROOT" 2>/dev/null || true
losetup -D 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════
#  STEP 5: Configure Pi boot to use our partitions
# ══════════════════════════════════════════════════════════════════════
log "Step 5/7: Configuring Pi 5 boot..."

PI_ROOT_UUID=$(blkid -s UUID -o value "$P4")
PI_ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$P4")

# Update cmdline.txt to point root= at our partition 4
if [[ -f "${MNT_PIBOOT}/cmdline.txt" ]]; then
    # Replace the root= parameter with our partition's UUID
    sed -i "s|root=[^ ]*|root=UUID=${PI_ROOT_UUID}|" "${MNT_PIBOOT}/cmdline.txt"
    # If PARTUUID was used instead
    sed -i "s|root=PARTUUID=[^ ]*|root=UUID=${PI_ROOT_UUID}|" "${MNT_PIBOOT}/cmdline.txt"
fi

# Update fstab in Pi root to match our partition UUIDs
PI_BOOT_UUID=$(blkid -s UUID -o value "$P3")
if [[ -f "${MNT_PIROOT}/etc/fstab" ]]; then
    # Rewrite fstab with our UUIDs
    cat > "${MNT_PIROOT}/etc/fstab" <<FSTAB
# /etc/fstab — generated by k3s-autoinstaller
UUID=${PI_ROOT_UUID}  /       ext4  defaults,noatime  0  1
UUID=${PI_BOOT_UUID}  /boot/firmware  vfat  defaults  0  2
FSTAB
fi

# ══════════════════════════════════════════════════════════════════════
#  STEP 6: Inject k3s scripts + cloud-init into Pi filesystem
# ══════════════════════════════════════════════════════════════════════
log "Step 6/7: Injecting k3s bootstrap into Pi filesystem..."

# Copy k3s scripts
mkdir -p "${MNT_PIROOT}/opt/k3s-bootstrap"
cp "${SCRIPT_DIR}/first-boot.sh"   "${MNT_PIROOT}/opt/k3s-bootstrap/first-boot.sh"
cp "${SCRIPT_DIR}/every-boot.sh"   "${MNT_PIROOT}/opt/k3s-bootstrap/every-boot.sh"
cp "${SCRIPT_DIR}/k3s-config.env"  "${MNT_PIROOT}/opt/k3s-bootstrap/k3s-config.env"
cp "${SCRIPT_DIR}/pi-clone-to-nvme.sh" "${MNT_PIROOT}/opt/k3s-bootstrap/pi-clone-to-nvme.sh"
chmod +x "${MNT_PIROOT}/opt/k3s-bootstrap/"*.sh

# Create the first-boot sentinel
touch "${MNT_PIROOT}/opt/k3s-bootstrap/.first-boot-pending"

# Create systemd services (same as x86, but written directly)
cat > "${MNT_PIROOT}/etc/systemd/system/k3s-first-boot.service" <<'UNIT'
[Unit]
Description=K3s first-boot cluster setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=/opt/k3s-bootstrap/.first-boot-pending

[Service]
Type=oneshot
ExecStart=/opt/k3s-bootstrap/first-boot.sh
ExecStartPost=/bin/rm -f /opt/k3s-bootstrap/.first-boot-pending
RemainAfterExit=true
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

cat > "${MNT_PIROOT}/etc/systemd/system/k3s-every-boot.service" <<'UNIT'
[Unit]
Description=K3s every-boot maintenance
After=network-online.target k3s-first-boot.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/k3s-bootstrap/every-boot.sh
RemainAfterExit=true
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

# Enable services via symlinks (chroot not available for arm64 on x86)
mkdir -p "${MNT_PIROOT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/k3s-first-boot.service \
    "${MNT_PIROOT}/etc/systemd/system/multi-user.target.wants/k3s-first-boot.service"
ln -sf /etc/systemd/system/k3s-every-boot.service \
    "${MNT_PIROOT}/etc/systemd/system/multi-user.target.wants/k3s-every-boot.service"

# ── Pi clone-to-NVMe service (runs BEFORE k3s first boot) ──────────
# This detects if booted from USB, clones to NVMe, then powers off.
cat > "${MNT_PIROOT}/etc/systemd/system/pi-clone-to-nvme.service" <<'UNIT'
[Unit]
Description=Clone Pi system from USB to NVMe
After=network-online.target
Wants=network-online.target
Before=k3s-first-boot.service
ConditionPathExists=/opt/k3s-bootstrap/pi-clone-to-nvme.sh
# Only run if booted from USB (not NVMe)
ConditionPathExists=!/opt/k3s-bootstrap/.nvme-clone-done

[Service]
Type=oneshot
ExecStart=/opt/k3s-bootstrap/pi-clone-to-nvme.sh
RemainAfterExit=true
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

ln -sf /etc/systemd/system/pi-clone-to-nvme.service \
    "${MNT_PIROOT}/etc/systemd/system/multi-user.target.wants/pi-clone-to-nvme.service"

# ── Cloud-init: set up user, SSH, packages ──────────────────────────
# The Pi preinstalled image uses cloud-init for first-boot user setup
mkdir -p "${MNT_PIBOOT}/nocloud"
cp "${SCRIPT_DIR}/user-data-pi" "${MNT_PIBOOT}/nocloud/user-data"
cp "${SCRIPT_DIR}/meta-data"    "${MNT_PIBOOT}/nocloud/meta-data"

# Also place in the standard cloud-init location
mkdir -p "${MNT_PIROOT}/var/lib/cloud/seed/nocloud"
cp "${SCRIPT_DIR}/user-data-pi" "${MNT_PIROOT}/var/lib/cloud/seed/nocloud/user-data"
cp "${SCRIPT_DIR}/meta-data"    "${MNT_PIROOT}/var/lib/cloud/seed/nocloud/meta-data"

# Tell cloud-init where to find the datasource
if [[ -f "${MNT_PIBOOT}/cmdline.txt" ]]; then
    # Append ds=nocloud if not already present
    if ! grep -q "ds=nocloud" "${MNT_PIBOOT}/cmdline.txt"; then
        sed -i 's/$/ ds=nocloud/' "${MNT_PIBOOT}/cmdline.txt"
    fi
fi

# ══════════════════════════════════════════════════════════════════════
#  STEP 7: Finalize
# ══════════════════════════════════════════════════════════════════════
log "Step 7/7: Syncing and finalizing..."

# Also copy k3s scripts to ESP for easy access/editing
mkdir -p "${MNT_ESP}/k3s-scripts"
cp "${SCRIPT_DIR}/first-boot.sh"   "${MNT_ESP}/k3s-scripts/"
cp "${SCRIPT_DIR}/every-boot.sh"   "${MNT_ESP}/k3s-scripts/"
cp "${SCRIPT_DIR}/k3s-config.env"  "${MNT_ESP}/k3s-scripts/"
cp "${SCRIPT_DIR}/pi-clone-to-nvme.sh" "${MNT_ESP}/k3s-scripts/"

sync

# Unmount everything
umount "$MNT_PIBOOT" 2>/dev/null || true
umount "$MNT_PIROOT" 2>/dev/null || true
umount "$MNT_X86"    2>/dev/null || true
umount "$MNT_ESP"    2>/dev/null || true
sync

log ""
log "═══════════════════════════════════════════════════════════════"
log "  USB drive is ready!  (dual-arch: x86_64 + ARM64 Pi 5)"
log ""
log "  x86_64 machines:"
log "    1. Plug USB in, boot from USB (UEFI)"
log "    2. Select 'Install Ubuntu 24.04 - K3s Autoinstall'"
log "    3. Ubuntu installs → machine powers off"
log "    4. Remove USB, power on → k3s bootstraps"
log ""
log "  Raspberry Pi 5 (with NVMe):"
log "    1. Plug USB in, power on (Pi boots from USB)"
log "    2. System clones itself to NVMe → Pi powers off"
log "    3. Remove USB, power on → boots from NVMe, k3s bootstraps"
log ""
log "  First node  → k3s server (advertises via mDNS)"
log "  Next nodes  → auto-discover and join as agents"
log "═══════════════════════════════════════════════════════════════"

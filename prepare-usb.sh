#!/usr/bin/env bash
# ── prepare-usb.sh ──────────────────────────────────────────────────────
# Creates a dual-arch (x86_64 + Pi 5) unattended k3s installer drive.
# Runs on Linux (e.g. SSH into a Pi node in your cluster).
#
# Partition layout:
#   Part 1:  1 GB    FAT32  ESP — GRUB EFI for x86 UEFI boot
#   Part 2:  6 GB    ext4   x86 Ubuntu installer (ISO contents + autoinstall)
#   Part 3:  300 MB  FAT32  Pi boot (firmware, kernel, config.txt, cloud-init)
#   Part 4:  4 GB    ext4   Pi root filesystem
#
# Boot paths:
#   x86 UEFI → ESP (Part 1) → GRUB → installer on Part 2 → autoinstall → poweroff
#   Pi 5     → scans FAT32 → finds config.txt on Part 3 → boots Part 3+4 →
#              cloud-init → clones to NVMe → poweroff
#
# All k3s scripts are embedded inside user-data-x86 and user-data-pi.
# No standalone script files are needed.
#
# Usage:  sudo ./prepare-usb.sh /dev/sdX
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ── Validate ────────────────────────────────────────────────────────────
[[ "$(uname)" != "Linux" ]] && die "This script must be run from Linux."
[[ $EUID -ne 0 ]] && die "Must run as root (sudo)."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Interactive disk selection (Linux) ──────────────────────────────────
pick_disk_linux() {
    ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
    ROOT_DISK=$(basename "$ROOT_DEV")
    MIN_SIZE_GB=8

    echo ""
    echo -e "${BOLD}Scanning for USB drives...${NC}"
    echo ""

    local disks=()
    local i=1
    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        local type=$(echo "$line" | awk '{print $3}')
        local tran=$(echo "$line" | awk '{print $4}')
        local model=$(echo "$line" | awk '{$1=$2=$3=$4=""; gsub(/^ +/,"",$0); print}')

        [[ "$type" != "disk" ]] && continue

        # Skip boot disk
        if [[ "/dev/$name" == "$ROOT_DEV"* ]] || [[ "$name" == "$ROOT_DISK" ]]; then
            continue
        fi

        # Only show removable/external drives (USB, eSATA, etc.)
        # Skip internal drive transports like nvme, and empty transport (SD cards show empty but are usually mmcblk)
        case "$tran" in
            usb|sata|ata) ;;  # allow these
            *) continue ;;
        esac

        # Skip the boot disk (don't offer to wipe what we're running from)
        local root_disk=$(lsblk -ndo PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null)
        [[ "$name" == "$root_disk" ]] && continue

        # Skip drives smaller than 8 GB
        local size_bytes=$(lsblk -bdno SIZE "/dev/$name" 2>/dev/null)
        [[ -n "$size_bytes" ]] && (( size_bytes < MIN_SIZE_GB * 1000000000 )) && continue

        # Check for existing k3s labels (previously prepared drive)
        local labels=""
        for lbl in $(lsblk -no LABEL "/dev/$name" 2>/dev/null); do
            case "$lbl" in
                K3S_EFI|K3S_PIBOOT|K3S_X86|K3S_PIROOT|system-boot)
                    labels="${labels:+$labels, }$lbl" ;;
            esac
        done

        echo -e "  ${GREEN}${i})${NC} /dev/${name}  ${size}"
        [[ -n "$model" && "$model" != " " ]] && echo -e "     ${CYAN}${model}${NC}"
        [[ -n "$labels" ]] && echo -e "     ${YELLOW}Previously prepared — partitions: ${labels}${NC}"

        disks+=("/dev/$name")
        ((i++))
    done < <(lsblk -dno NAME,SIZE,TYPE,TRAN,MODEL 2>/dev/null)

    if [[ ${#disks[@]} -eq 0 ]]; then
        die "No external drives found (8 GB+). Plug in your USB/eSATA drive and try again."
    fi

    echo ""

    # Auto-select if there's exactly one USB drive
    if [[ ${#disks[@]} -eq 1 ]]; then
        DEVICE="${disks[0]}"
        log "Auto-selected ${DEVICE} (only USB drive detected)"
        return
    fi

    read -rp "Select disk number [1-$((i-1))]: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
        DEVICE="${disks[$((choice-1))]}"
    else
        die "Invalid selection."
    fi
}

# ── Parse args ────────────────────────────────────────────────────────
DEVICE=""
CLUSTER_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster) CLUSTER_ARG="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo $0 [--cluster NAME] [/dev/sdX]"
            echo "  --cluster NAME   Use a specific cluster profile"
            echo "  /dev/sdX         Target disk (interactive if omitted)"
            exit 0
            ;;
        *) DEVICE="$1"; shift ;;
    esac
done

if [[ -z "$DEVICE" ]]; then
    pick_disk_linux
fi

[[ ! -b "$DEVICE" ]] && die "$DEVICE is not a block device."

# Safety: refuse the boot disk
ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
[[ "$DEVICE" == "$ROOT_DEV"* ]] && die "Refusing to operate on boot disk ($ROOT_DEV)."

# ── Cluster selection ────────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/cluster.sh"

if [[ -n "$CLUSTER_ARG" ]]; then
    select_cluster "$CLUSTER_ARG"
else
    select_cluster
fi

# ── Required files ──────────────────────────────────────────────────────
USER_DATA_X86_TEMPLATE="${SCRIPT_DIR}/user-data-x86.template"
USER_DATA_PI_TEMPLATE="${SCRIPT_DIR}/user-data-pi.template"
[[ ! -f "$USER_DATA_X86_TEMPLATE" ]] && die "user-data-x86.template not found in ${SCRIPT_DIR}"
[[ ! -f "$USER_DATA_PI_TEMPLATE" ]]  && die "user-data-pi.template not found in ${SCRIPT_DIR}"

# Generate user-data from templates with cluster config
log "Generating user-data for cluster: ${CLUSTER_NAME}"
USER_DATA_X86="/tmp/user-data-x86-$$"
USER_DATA_PI="/tmp/user-data-pi-$$"
apply_cluster_to_template "$USER_DATA_X86_TEMPLATE" "$USER_DATA_X86"
apply_cluster_to_template "$USER_DATA_PI_TEMPLATE" "$USER_DATA_PI"

# ── Config ──────────────────────────────────────────────────────────────
X86_ISO_URL="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso"
PI_IMG_URL="https://cdimage.ubuntu.com/releases/24.04.4/release/ubuntu-24.04.4-preinstalled-server-arm64+raspi.img.xz"

X86_ISO="${SCRIPT_DIR}/ubuntu-24.04-server-amd64.iso"
PI_IMG_XZ="${SCRIPT_DIR}/ubuntu-24.04-pi-arm64.img.xz"
PI_IMG="${SCRIPT_DIR}/ubuntu-24.04-pi-arm64.img"

# ── Cleanup trap ────────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d /tmp/k3s-usb.XXXXXX)
cleanup() {
    log "Cleaning up mounts..."
    for mp in "${WORK_DIR}"/*/; do
        mountpoint -q "$mp" 2>/dev/null && umount -l "$mp" 2>/dev/null || true
    done
    [[ -n "${PI_LOOP:-}" ]] && losetup -d "$PI_LOOP" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ── Helper: partition device path ─────────────────────────────────────
# /dev/sda → /dev/sda1   |   /dev/nvme0n1 → /dev/nvme0n1p1
part() {
    local dev="$1" num="$2"
    if [[ "$dev" =~ [0-9]$ ]]; then echo "${dev}p${num}"; else echo "${dev}${num}"; fi
}

# ── Install dependencies ────────────────────────────────────────────────
log "Checking dependencies..."
for pkg in parted dosfstools e2fsprogs rsync curl xz-utils; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        log "Installing $pkg..."
        apt-get update -qq && apt-get install -y -qq "$pkg" || warn "Could not install $pkg"
    fi
done

# ═════════════════════════════════════════════════════════════════════════
#  STEP 1: Download images
# ═════════════════════════════════════════════════════════════════════════
log "Step 1/6: Downloading images..."

if [[ -f "$X86_ISO" ]]; then
    log "Found existing x86 ISO: $(basename "$X86_ISO")"
else
    log "Downloading Ubuntu 24.04 Server x86_64 ISO (~2.6 GB)..."
    curl -L -# -o "$X86_ISO" "$X86_ISO_URL" || die "x86 ISO download failed."
fi

if [[ -f "$PI_IMG" ]]; then
    log "Found existing Pi image (decompressed)"
elif [[ -f "$PI_IMG_XZ" ]]; then
    log "Decompressing Pi image..."
    xz -dk "$PI_IMG_XZ" || die "Decompression failed."
else
    log "Downloading Ubuntu 24.04 Server ARM64 for Pi (~2.0 GB)..."
    curl -L -# -o "$PI_IMG_XZ" "$PI_IMG_URL" || die "Pi image download failed."
    log "Decompressing Pi image..."
    xz -dk "$PI_IMG_XZ" || die "Decompression failed."
fi

# ═════════════════════════════════════════════════════════════════════════
#  STEP 2: Partition the drive
# ═════════════════════════════════════════════════════════════════════════
log ""
log "═══════════════════════════════════════════════════════════════"
log "  Target: ${DEVICE}"
lsblk "$DEVICE" 2>/dev/null || true
log ""
log "  Layout:"
log "    Part 1:  1 GB    FAT32  ESP (GRUB for x86 UEFI)"
log "    Part 2:  6 GB    ext4   x86 Ubuntu installer + autoinstall"
log "    Part 3:  300 MB  FAT32  Pi boot (firmware + cloud-init)"
log "    Part 4:  4 GB    ext4   Pi root filesystem"
log ""
log "  ALL DATA ON THIS DEVICE WILL BE DESTROYED."
log "═══════════════════════════════════════════════════════════════"
log ""
read -rp "Type 'YES' to continue: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && die "Aborted."

log "Step 2/6: Partitioning ${DEVICE}..."

# Unmount any existing partitions
for i in 1 2 3 4 5 6 7 8; do
    umount "$(part "$DEVICE" "$i")" 2>/dev/null || true
done

wipefs -af "$DEVICE" >/dev/null 2>&1
parted -s "$DEVICE" mklabel gpt

parted -s "$DEVICE" mkpart "ESP"          fat32 1MiB    1025MiB
parted -s "$DEVICE" set 1 esp on
parted -s "$DEVICE" set 1 boot on
parted -s "$DEVICE" mkpart "x86-install"  ext4  1025MiB 7169MiB
parted -s "$DEVICE" mkpart "pi-boot"      fat32 7169MiB 7469MiB
parted -s "$DEVICE" mkpart "pi-root"      ext4  7469MiB 15665MiB

sleep 2
partprobe "$DEVICE" 2>/dev/null || true
sleep 2

P1=$(part "$DEVICE" 1)
P2=$(part "$DEVICE" 2)
P3=$(part "$DEVICE" 3)
P4=$(part "$DEVICE" 4)

for p in "$P1" "$P2" "$P3" "$P4"; do
    [[ ! -b "$p" ]] && die "Partition $p not found after partitioning."
done

log "Formatting..."
mkfs.fat  -F 32 -n "K3S_EFI"    "$P1"
mkfs.ext4 -F    -L "K3S_X86"    "$P2"
mkfs.fat  -F 32 -n "K3S_PIBOOT" "$P3"
mkfs.ext4 -F -i 4096 -L "K3S_PIROOT" "$P4"

# ═════════════════════════════════════════════════════════════════════════
#  STEP 3: Set up x86 installer (ESP + Part 2)
# ═════════════════════════════════════════════════════════════════════════
log "Step 3/6: Setting up x86 installer..."

MNT_ESP="${WORK_DIR}/esp"
MNT_X86="${WORK_DIR}/x86"
MNT_ISO="${WORK_DIR}/iso"
mkdir -p "$MNT_ESP" "$MNT_X86" "$MNT_ISO"

mount "$P1" "$MNT_ESP"
mount "$P2" "$MNT_X86"
mount -o loop,ro "$X86_ISO" "$MNT_ISO" || die "Could not mount ISO."

# Copy ISO contents to x86 installer partition
log "  Copying x86 ISO contents to Part 2 (~2.5 GB)..."
rsync -a --info=progress2 "$MNT_ISO/" "$MNT_X86/"

# Set up GRUB on ESP
log "  Setting up GRUB on ESP..."
mkdir -p "${MNT_ESP}/EFI/BOOT"

# Copy GRUB EFI binaries from ISO (case-insensitive search)
EFI_SRC=$(find "${MNT_ISO}/EFI" -iname "bootx64.efi" -print -quit 2>/dev/null)
if [[ -n "$EFI_SRC" ]]; then
    cp "$EFI_SRC" "${MNT_ESP}/EFI/BOOT/BOOTX64.EFI"
    log "  Copied BOOTX64.EFI from $(basename "$(dirname "$EFI_SRC")")"
else
    warn "No BOOTX64.EFI found in ISO — x86 UEFI boot may not work."
    warn "You may need to copy BOOTX64.EFI to the ESP manually."
fi
# Copy grubx64.efi and mmx64.efi (shim) if present
for efi in grubx64.efi mmx64.efi; do
    SRC=$(find "${MNT_ISO}/EFI" -iname "$efi" -print -quit 2>/dev/null)
    [[ -n "$SRC" ]] && cp "$SRC" "${MNT_ESP}/EFI/BOOT/$efi"
done

# Copy GRUB modules from ISO
if [[ -d "${MNT_ISO}/boot/grub" ]]; then
    mkdir -p "${MNT_ESP}/boot/grub"
    rsync -a "${MNT_ISO}/boot/grub/" "${MNT_ESP}/boot/grub/" 2>/dev/null || true
fi

umount "$MNT_ISO"

# Get x86 installer partition UUID for GRUB
X86_UUID=$(blkid -s UUID -o value "$P2")

# Write GRUB config
mkdir -p "${MNT_ESP}/boot/grub"
cat > "${MNT_ESP}/boot/grub/grub.cfg" <<GRUBCFG
set default=0
set timeout=3

menuentry "Install Ubuntu 24.04 (x86_64) - K3s Autoinstall" {
    search --no-floppy --fs-uuid --set=root ${X86_UUID}
    set gfxpayload=keep
    linux /casper/vmlinuz quiet autoinstall ds=nocloud\\;s=/cdrom/ ---
    initrd /casper/initrd
}

menuentry "Install Ubuntu 24.04 - Safe Graphics" {
    search --no-floppy --fs-uuid --set=root ${X86_UUID}
    set gfxpayload=keep
    linux /casper/vmlinuz quiet autoinstall ds=nocloud\\;s=/cdrom/ nomodeset ---
    initrd /casper/initrd
}
GRUBCFG

# Also put grub.cfg where GRUB EFI might look for it
cp "${MNT_ESP}/boot/grub/grub.cfg" "${MNT_ESP}/EFI/BOOT/grub.cfg"

# Overwrite the ISO's grub.cfg on the x86 installer partition
# GRUB's embedded config searches for /.disk/info, finds it on this partition,
# then loads boot/grub/grub.cfg from here — so this is the one that actually runs
log "  Overwriting installer GRUB config with autoinstall version..."
cat > "${MNT_X86}/boot/grub/grub.cfg" <<X86GRUB
set timeout=5

loadfont unicode

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Install Ubuntu Server - K3s Autoinstall" {
$(printf '\t')set gfxpayload=keep
$(printf '\t')linux$(printf '\t')/casper/vmlinuz autoinstall ds=nocloud\;s=/cdrom/ quiet ---
$(printf '\t')initrd$(printf '\t')/casper/initrd
}
menuentry "Install Ubuntu Server - K3s (Safe Graphics)" {
$(printf '\t')set gfxpayload=keep
$(printf '\t')linux$(printf '\t')/casper/vmlinuz autoinstall ds=nocloud\;s=/cdrom/ quiet nomodeset ---
$(printf '\t')initrd$(printf '\t')/casper/initrd
}
X86GRUB

# Inject autoinstall user-data into the x86 installer partition
# Ubuntu autoinstall with ds=nocloud;s=/cdrom/ looks at the root of the boot source
log "  Injecting x86 autoinstall user-data..."
cp "$USER_DATA_X86" "${MNT_X86}/user-data"
touch "${MNT_X86}/meta-data"

# ═════════════════════════════════════════════════════════════════════════
#  STEP 4: Set up Pi boot + root (Parts 3 + 4)
# ═════════════════════════════════════════════════════════════════════════
log "Step 4/6: Setting up Pi partitions from ARM64 image..."

MNT_PIBOOT="${WORK_DIR}/pi-boot"
MNT_PIROOT="${WORK_DIR}/pi-root"
MNT_IMG_BOOT="${WORK_DIR}/img-boot"
MNT_IMG_ROOT="${WORK_DIR}/img-root"
mkdir -p "$MNT_PIBOOT" "$MNT_PIROOT" "$MNT_IMG_BOOT" "$MNT_IMG_ROOT"

mount "$P3" "$MNT_PIBOOT"
mount "$P4" "$MNT_PIROOT"

# Mount Pi image partitions via loop device
PI_LOOP=$(losetup -fP --show "$PI_IMG") || die "Could not set up loop device for Pi image."
sleep 2

mount "${PI_LOOP}p1" "$MNT_IMG_BOOT" || die "Could not mount Pi image boot partition."
mount "${PI_LOOP}p2" "$MNT_IMG_ROOT" || die "Could not mount Pi image root partition."

log "  Copying Pi boot partition..."
rsync -a "$MNT_IMG_BOOT/" "$MNT_PIBOOT/"

log "  Copying Pi root filesystem (this takes several minutes)..."
rsync -aAXH --info=progress2 "$MNT_IMG_ROOT/" "$MNT_PIROOT/" || die "rsync failed copying Pi root filesystem."

umount "$MNT_IMG_BOOT"
umount "$MNT_IMG_ROOT"
losetup -d "$PI_LOOP"
PI_LOOP=""

# ═════════════════════════════════════════════════════════════════════════
#  STEP 5: Configure Pi boot + inject cloud-init
# ═════════════════════════════════════════════════════════════════════════
log "Step 5/6: Configuring Pi boot and injecting cloud-init..."

PI_BOOT_UUID=$(blkid -s UUID -o value "$P3")
PI_ROOT_UUID=$(blkid -s UUID -o value "$P4")

# Update cmdline.txt to point to our root partition
if [[ -f "${MNT_PIBOOT}/cmdline.txt" ]]; then
    sed -i "s|root=[^ ]*|root=UUID=${PI_ROOT_UUID}|" "${MNT_PIBOOT}/cmdline.txt"
    sed -i "s|root=PARTUUID=[^ ]*|root=UUID=${PI_ROOT_UUID}|" "${MNT_PIBOOT}/cmdline.txt"
    log "  Updated cmdline.txt → root=UUID=${PI_ROOT_UUID}"
fi

# Update fstab on Pi root
cat > "${MNT_PIROOT}/etc/fstab" <<FSTAB
# Generated by prepare-usb.sh for USB boot
UUID=${PI_ROOT_UUID}  /               ext4  defaults,noatime  0  1
UUID=${PI_BOOT_UUID}  /boot/firmware  vfat  defaults          0  2
FSTAB

# Inject cloud-init user-data onto the Pi boot partition
# The Pi's Ubuntu image reads cloud-init from the boot partition root
cp "$USER_DATA_PI" "${MNT_PIBOOT}/user-data"
touch "${MNT_PIBOOT}/meta-data"

log "  Pi cloud-init user-data injected"

# ═════════════════════════════════════════════════════════════════════════
#  STEP 6: Sync and finalize
# ═════════════════════════════════════════════════════════════════════════
log "Step 6/6: Syncing and finalizing..."

sync
umount "$MNT_ESP"    2>/dev/null || true
umount "$MNT_X86"    2>/dev/null || true
umount "$MNT_PIBOOT" 2>/dev/null || true
umount "$MNT_PIROOT" 2>/dev/null || true
sync

log ""
log "═══════════════════════════════════════════════════════════════"
log "  Dual-arch USB drive is ready!"
log ""
lsblk "$DEVICE" 2>/dev/null || true
log ""
log "  x86_64 deployment:"
log "    1. Plug USB into x86 machine, boot from USB (UEFI)"
log "    2. GRUB auto-selects K3s Autoinstall after 3 seconds"
log "    3. Ubuntu installs unattended (~10-15 min), machine powers off"
log "    4. Remove USB, power on → k3s bootstraps on first boot"
log ""
log "  Raspberry Pi 5 deployment:"
log "    1. Plug USB into Pi 5, power on"
log "    2. Pi boots from USB, clones to NVMe (~5-10 min), powers off"
log "    3. Remove USB, power on → k3s bootstraps on first boot"
log ""
log "  Cluster auto-discovery:"
log "    First node (any arch) → k3s server (publishes via mDNS)"
log "    All subsequent nodes  → auto-discover and join as agents"
log "═══════════════════════════════════════════════════════════════"

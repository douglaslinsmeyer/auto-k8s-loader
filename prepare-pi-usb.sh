#!/usr/bin/env bash
# ── prepare-pi-usb.sh ───────────────────────────────────────────────
# Prepares a USB/eSATA drive as an unattended Pi 5 + k3s installer.
# Runs natively on macOS — no Docker, no Linux required.
#
# What it does:
#   1. Downloads Ubuntu 24.04 Server ARM64 preinstalled image for Pi
#   2. Writes it to the USB drive (dd)
#   3. Mounts the FAT32 boot partition
#   4. Injects the cloud-init user-data (which contains ALL scripts)
#
# Usage:  sudo ./prepare-pi-usb.sh /dev/diskN
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ── Validate ────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && { echo "Usage: sudo $0 /dev/diskN"; echo "Run 'diskutil list' to find your USB drive."; exit 1; }

DEVICE="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -ne 0 ]] && die "Must run as root (sudo)."

# Safety: refuse boot disk
if [[ "$(uname)" == "Darwin" ]]; then
    BOOT_DISK=$(diskutil info / 2>/dev/null | awk '/Part of Whole/ {print $NF}')
    [[ "$DEVICE" == *"$BOOT_DISK"* ]] && die "Refusing to operate on boot disk ($BOOT_DISK)."
fi

# ── Config ──────────────────────────────────────────────────────────
IMG_URL="https://cdimage.ubuntu.com/releases/24.04.4/release/ubuntu-24.04.4-preinstalled-server-arm64+raspi.img.xz"
IMG_XZ="${SCRIPT_DIR}/ubuntu-24.04-pi-arm64.img.xz"
IMG="${SCRIPT_DIR}/ubuntu-24.04-pi-arm64.img"
USER_DATA="${SCRIPT_DIR}/user-data-pi"

[[ ! -f "$USER_DATA" ]] && die "user-data-pi not found in ${SCRIPT_DIR}"

# ── Step 1: Download Pi image ───────────────────────────────────────
if [[ -f "$IMG" ]]; then
    log "Found existing Pi image (decompressed): $IMG"
elif [[ -f "$IMG_XZ" ]]; then
    log "Found compressed image, decompressing..."
    xz -dk "$IMG_XZ" || die "Decompression failed. Install xz: brew install xz"
else
    log "Downloading Ubuntu 24.04 Server ARM64 for Pi (~2.0 GB)..."
    curl -L -# -o "$IMG_XZ" "$IMG_URL" || die "Download failed."
    log "Decompressing (this takes a minute)..."
    xz -dk "$IMG_XZ" || die "Decompression failed."
fi

# ── Step 2: Write image to USB ──────────────────────────────────────
log ""
log "═══════════════════════════════════════════════════════════════"
log "  Target:  ${DEVICE}"
if command -v diskutil &>/dev/null; then
    diskutil list "$DEVICE" 2>/dev/null | head -5 || true
fi
log ""
log "  ALL DATA ON THIS DEVICE WILL BE DESTROYED."
log "═══════════════════════════════════════════════════════════════"
log ""
read -rp "Type 'YES' to continue: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && die "Aborted."

diskutil unmountDisk "$DEVICE" 2>/dev/null || true

RAW_DEVICE="${DEVICE/disk/rdisk}"
log "Writing Pi image to ${RAW_DEVICE} (this takes a few minutes)..."
dd if="$IMG" of="$RAW_DEVICE" bs=4m status=progress 2>&1 || \
dd if="$IMG" of="$RAW_DEVICE" bs=4m 2>&1 || \
dd if="$IMG" of="$DEVICE" bs=4m 2>&1
sync

# ── Step 3: Mount boot partition and inject cloud-init ──────────────
log "Mounting boot partition..."
sleep 3

# The Pi image creates two partitions:
#   disk4s1 = FAT32 "system-boot" (this is what we need)
#   disk4s2 = ext4 root (macOS can't write here, but we don't need to)
BOOT_MOUNT=""
USED_MOUNT_MSDOS=false

# Method 1: diskutil mount (preferred, auto-mounts to /Volumes)
diskutil mount "${DEVICE}s1" 2>/dev/null && sleep 2 || true

# Check if diskutil succeeded
mp=$(diskutil info "${DEVICE}s1" 2>/dev/null | grep "Mount Point" | sed 's/.*Mount Point: *//' | sed 's/ *$//') || true
if [[ -n "$mp" ]] && [[ -d "$mp" ]]; then
    BOOT_MOUNT="$mp"
fi

# Check known volume names
if [[ -z "$BOOT_MOUNT" ]]; then
    for candidate in "/Volumes/system-boot" "/Volumes/SYSTEM-BOOT" "/Volumes/boot" "/Volumes/PI_BOOT"; do
        if [[ -d "$candidate" ]] && [[ -f "${candidate}/config.txt" ]]; then
            BOOT_MOUNT="$candidate"
            break
        fi
    done
fi

# Method 2: mount_msdos fallback (diskutil sometimes blocks after dd)
if [[ -z "$BOOT_MOUNT" ]]; then
    warn "diskutil mount blocked — falling back to mount_msdos..."
    BOOT_MOUNT="/tmp/piboot-$$"
    mkdir -p "$BOOT_MOUNT"
    mount_msdos "${DEVICE}s1" "$BOOT_MOUNT" 2>/dev/null || \
        die "Could not mount ${DEVICE}s1. Try: unplug and replug the drive, then re-run."
    USED_MOUNT_MSDOS=true
fi

log "Found boot partition at: $BOOT_MOUNT"

# Verify it looks like a Pi boot partition
if [[ ! -f "${BOOT_MOUNT}/config.txt" ]]; then
    warn "No config.txt found — this may not be a Pi boot partition."
fi

# ── Step 4: Inject user-data ────────────────────────────────────────
log "Injecting cloud-init user-data..."

# The Pi's Ubuntu image reads cloud-init from the boot partition root
cp "$USER_DATA" "${BOOT_MOUNT}/user-data"

# Ensure meta-data exists (required by cloud-init)
touch "${BOOT_MOUNT}/meta-data"

# Verify
if [[ -f "${BOOT_MOUNT}/user-data" ]]; then
    log "user-data written successfully ($(wc -c < "${BOOT_MOUNT}/user-data") bytes)"
else
    die "Failed to write user-data!"
fi

# ── Step 5: Eject ──────────────────────────────────────────────────
sync
if [[ "$USED_MOUNT_MSDOS" == true ]]; then
    umount "$BOOT_MOUNT" 2>/dev/null || true
    rmdir "$BOOT_MOUNT" 2>/dev/null || true
fi
diskutil eject "$DEVICE" 2>/dev/null || diskutil unmountDisk "$DEVICE" 2>/dev/null || true

log ""
log "═══════════════════════════════════════════════════════════════"
log "  USB drive is ready!"
log ""
log "  To deploy a Pi 5 (with NVMe):"
log "    1. Plug USB into Pi 5"
log "    2. Power on"
log "    3. Wait ~5-10 min (boots from USB, clones to NVMe)"
log "    4. Pi powers off automatically"
log "    5. Remove USB, power on"
log "    6. Pi boots from NVMe, k3s sets up automatically"
log ""
log "  First Pi  -> k3s server (advertises via mDNS)"
log "  Next Pis  -> auto-discover and join as agents"
log "═══════════════════════════════════════════════════════════════"

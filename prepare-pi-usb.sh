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
# Usage:
#   sudo ./prepare-pi-usb.sh             # interactive disk selection
#   sudo ./prepare-pi-usb.sh /dev/diskN  # specify disk directly
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Must run as root (sudo)."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Interactive disk selection (macOS) ──────────────────────────────
pick_disk_macos() {
    BOOT_DISK=$(diskutil info / 2>/dev/null | awk '/Part of Whole/ {print $NF}')
    MIN_SIZE_BYTES=8000000000  # 8 GB minimum

    echo ""
    echo -e "${BOLD}Scanning for USB drives...${NC}"
    echo ""

    local disks=()
    local i=1
    while IFS= read -r disk; do
        [[ "$disk" == "$BOOT_DISK" ]] && continue

        local proto=$(diskutil info "/dev/$disk" 2>/dev/null | awk -F: '/Protocol/ {gsub(/^ +/,"",$2); print $2}')
        # Only show USB drives
        [[ "$proto" != "USB" ]] && continue

        local size_str=$(diskutil info "/dev/$disk" 2>/dev/null | awk -F: '/Disk Size/ {gsub(/^ +/,"",$2); print $2}' | head -1)
        local size_bytes=$(diskutil info "/dev/$disk" 2>/dev/null | grep 'Disk Size' | grep -oE '[0-9]+ Bytes' | awk '{print $1}')
        # Skip drives smaller than 8 GB
        if [[ -n "$size_bytes" ]] && [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
            (( size_bytes < MIN_SIZE_BYTES )) && continue
        fi

        local media=$(diskutil info "/dev/$disk" 2>/dev/null | awk -F: '/Media Name/ {gsub(/^ +/,"",$2); print $2}')

        # Check for existing k3s labels (previously prepared drive)
        local labels=""
        for part_num in 1 2 3 4; do
            local lbl=$(diskutil info "/dev/${disk}s${part_num}" 2>/dev/null | awk -F: '/Volume Name/ {gsub(/^ +/,"",$2); print $2}')
            case "$lbl" in
                K3S_EFI|K3S_PIBOOT|K3S_X86|K3S_PIROOT|system-boot)
                    labels="${labels:+$labels, }$lbl" ;;
            esac
        done

        echo -e "  ${GREEN}${i})${NC} /dev/${disk}  ${size_str:-unknown size}"
        [[ -n "$media" ]] && echo -e "     ${CYAN}${media}${NC}"
        [[ -n "$labels" ]] && echo -e "     ${YELLOW}Previously prepared — partitions: ${labels}${NC}"

        disks+=("/dev/$disk")
        ((i++))
    done < <(diskutil list 2>/dev/null | awk '/^\/dev\/disk[0-9]/ {gsub(/\/dev\//,"",$1); gsub(/[^a-z0-9]/,"",$1); print $1}')

    if [[ ${#disks[@]} -eq 0 ]]; then
        die "No USB drives found (8 GB+). Plug in your USB/eSATA drive and try again."
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

# ── Parse args ─────────────────────────────────────────────────────
DEVICE=""
CLUSTER_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster) CLUSTER_ARG="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo $0 [--cluster NAME] [/dev/diskN]"
            echo "  --cluster NAME   Use a specific cluster profile"
            echo "  /dev/diskN       Target disk (interactive if omitted)"
            exit 0
            ;;
        *) DEVICE="$1"; shift ;;
    esac
done

# ── Disk selection ─────────────────────────────────────────────────
if [[ -z "$DEVICE" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        pick_disk_macos
    else
        echo "Usage: sudo $0 [--cluster NAME] /dev/diskN"
        echo "Run 'diskutil list' (macOS) or 'lsblk' (Linux) to find your USB drive."
        exit 1
    fi
fi

# Safety: refuse boot disk
if [[ "$(uname)" == "Darwin" ]]; then
    BOOT_DISK=$(diskutil info / 2>/dev/null | awk '/Part of Whole/ {print $NF}')
    [[ "$DEVICE" == *"$BOOT_DISK"* ]] && die "Refusing to operate on boot disk ($BOOT_DISK)."
fi

# ── Cluster selection ──────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/cluster.sh"

if [[ -n "$CLUSTER_ARG" ]]; then
    select_cluster "$CLUSTER_ARG"
else
    select_cluster
fi

# ── Config ──────────────────────────────────────────────────────────
IMG_URL="https://cdimage.ubuntu.com/releases/24.04.4/release/ubuntu-24.04.4-preinstalled-server-arm64+raspi.img.xz"
IMG_XZ="${SCRIPT_DIR}/ubuntu-24.04-pi-arm64.img.xz"
IMG="${SCRIPT_DIR}/ubuntu-24.04-pi-arm64.img"
USER_DATA_TEMPLATE="${SCRIPT_DIR}/user-data-pi.template"
USER_DATA="/tmp/user-data-pi-$$"

[[ ! -f "$USER_DATA_TEMPLATE" ]] && die "user-data-pi.template not found in ${SCRIPT_DIR}"

# Generate user-data from template with cluster config
log "Generating user-data for cluster: ${CLUSTER_NAME}"
apply_cluster_to_template "$USER_DATA_TEMPLATE" "$USER_DATA"

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

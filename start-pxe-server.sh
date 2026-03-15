#!/usr/bin/env bash
# ── start-pxe-server.sh ─────────────────────────────────────────────────
# Starts a PXE boot server on your Mac (or Linux) to network-boot x86
# machines with the k3s autoinstaller.
#
# What this does:
#   1. Downloads the Ubuntu Server ISO if not present
#   2. Extracts boot files (kernel, initrd, EFI binaries)
#   3. Starts an HTTP server (serves installer + autoinstall config)
#   4. Starts dnsmasq (DHCP proxy + TFTP for PXE boot)
#
# Prerequisites (macOS):
#   brew install dnsmasq p7zip
#
# Prerequisites (Linux):
#   sudo apt install dnsmasq p7zip-full
#
# Usage:
#   sudo ./start-pxe-server.sh                     # interactive cluster + IP
#   sudo ./start-pxe-server.sh --ip 192.168.1.100  # specify server IP
#   sudo ./start-pxe-server.sh --cluster prod       # specify cluster profile
#
# On the target x86 machine:
#   Boot from network (PXE/Onboard NIC IPv4)
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PXE_DIR="${SCRIPT_DIR}/pxe"
TFTP_DIR="${PXE_DIR}/tftp"
HTTP_DIR="${PXE_DIR}/http"
SERVER_IP=""
CLUSTER_ARG=""

# ── Parse args ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)      SERVER_IP="$2"; shift 2 ;;
        --cluster) CLUSTER_ARG="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo $0 [--cluster NAME] [--ip SERVER_IP]"
            echo ""
            echo "  --cluster NAME   Use a specific cluster profile"
            echo "  --ip IP          Your machine's LAN IP (auto-detected if omitted)"
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Check root ──────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must run as root (sudo)."

# ── Cluster selection ─────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/cluster.sh"

if [[ -n "$CLUSTER_ARG" ]]; then
    select_cluster "$CLUSTER_ARG"
else
    select_cluster
fi

# ── Install dependencies ────────────────────────────────────────────────
install_deps() {
    local missing=()
    for cmd in dnsmasq curl 7z; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return
    fi

    log "Missing tools: ${missing[*]}"

    if [[ "$(uname)" == "Darwin" ]]; then
        if ! command -v brew &>/dev/null; then
            die "Homebrew is required to install dependencies. Install from https://brew.sh"
        fi
        local brew_pkgs=()
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                dnsmasq) brew_pkgs+=("dnsmasq") ;;
                7z)      brew_pkgs+=("p7zip") ;;
                curl)    brew_pkgs+=("curl") ;;
            esac
        done
        if [[ ${#brew_pkgs[@]} -gt 0 ]]; then
            log "Installing via brew: ${brew_pkgs[*]}"
            sudo -u "${SUDO_USER:-$USER}" brew install "${brew_pkgs[@]}" || die "brew install failed"
        fi
    else
        local apt_pkgs=()
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                dnsmasq) apt_pkgs+=("dnsmasq") ;;
                7z)      apt_pkgs+=("p7zip-full") ;;
                curl)    apt_pkgs+=("curl") ;;
            esac
        done
        if [[ ${#apt_pkgs[@]} -gt 0 ]]; then
            log "Installing via apt: ${apt_pkgs[*]}"
            apt-get update -qq && apt-get install -y -qq "${apt_pkgs[@]}" || die "apt install failed"
        fi
    fi
}

install_deps

HAS_7Z=false
command -v 7z &>/dev/null && HAS_7Z=true

# ── Detect IP ───────────────────────────────────────────────────────────
pick_interface() {
    echo ""
    echo -e "${BOLD:-}Network interfaces with IP addresses:${NC}"
    echo ""

    local ifaces=()
    local ips=()
    local i=1

    if [[ "$(uname)" == "Darwin" ]]; then
        while IFS= read -r iface; do
            local ip=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
            [[ -z "$ip" ]] && continue
            local hw=$(networksetup -listallhardwareports 2>/dev/null | grep -A1 "Device: $iface" | head -1 | sed 's/Hardware Port: //')

            echo -e "  ${GREEN}${i})${NC} ${iface}  ${BOLD:-}${ip}${NC}"
            [[ -n "$hw" ]] && echo -e "     ${CYAN:-}${hw}${NC}"

            ifaces+=("$iface")
            ips+=("$ip")
            ((i++))
        done < <(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -v '^lo')
    else
        while IFS= read -r line; do
            local iface=$(echo "$line" | awk '{print $1}')
            local ip=$(echo "$line" | awk '{print $2}')
            [[ -z "$ip" || "$ip" == "127."* ]] && continue

            echo -e "  ${GREEN}${i})${NC} ${iface}  ${BOLD:-}${ip}${NC}"

            ifaces+=("$iface")
            ips+=("$ip")
            ((i++))
        done < <(ip -4 -o addr show 2>/dev/null | awk '{gsub(/\/.*/,"",$4); print $2, $4}')
    fi

    if [[ ${#ips[@]} -eq 0 ]]; then
        die "No network interfaces with IP addresses found."
    fi

    if [[ ${#ips[@]} -eq 1 ]]; then
        SERVER_IP="${ips[0]}"
        log "Using ${ifaces[0]} (${SERVER_IP})"
        return
    fi

    echo ""
    read -rp "Select interface [1-$((i-1))]: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
        SERVER_IP="${ips[$((choice-1))]}"
    else
        die "Invalid selection."
    fi
}

if [[ -z "$SERVER_IP" ]]; then
    pick_interface
fi
log "Server IP: ${SERVER_IP}"

# Detect subnet for dnsmasq DHCP proxy range
SUBNET=$(echo "$SERVER_IP" | sed 's/\.[0-9]*$/.0/')

# ── Config ──────────────────────────────────────────────────────────────
X86_ISO_URL="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso"
X86_ISO="${SCRIPT_DIR}/ubuntu-24.04.4-live-server-amd64.iso"

# Also check for other common ISO names
if [[ ! -f "$X86_ISO" ]]; then
    for candidate in \
        "${SCRIPT_DIR}/ubuntu-24.04-server-amd64.iso" \
        "${SCRIPT_DIR}/ubuntu-24.04.2-live-server-amd64.iso" \
        "${SCRIPT_DIR}/ubuntu-24.04.4-live-server-amd64.iso"; do
        if [[ -f "$candidate" ]]; then
            X86_ISO="$candidate"
            break
        fi
    done
fi

USER_DATA_TEMPLATE="${SCRIPT_DIR}/user-data-x86.template"
USER_DATA_X86="/tmp/user-data-x86-$$"

[[ ! -f "$USER_DATA_TEMPLATE" ]] && die "user-data-x86.template not found in ${SCRIPT_DIR}"

# Generate user-data from template with cluster config
log "Generating user-data for cluster: ${CLUSTER_NAME}"
apply_cluster_to_template "$USER_DATA_TEMPLATE" "$USER_DATA_X86"

# ── Step 1: Download ISO if needed ──────────────────────────────────────
if [[ ! -f "$X86_ISO" ]]; then
    log "Downloading Ubuntu 24.04 Server x86_64 ISO (~2.6 GB)..."
    curl -L -# -o "$X86_ISO" "$X86_ISO_URL" || die "ISO download failed."
fi
log "Using ISO: $(basename "$X86_ISO")"

# ── Step 2: Extract boot files if needed ────────────────────────────────
if [[ -f "${TFTP_DIR}/grubx64.efi" && -f "${HTTP_DIR}/vmlinuz" && -f "${HTTP_DIR}/initrd" ]]; then
    log "PXE files already extracted"
else
    log "Extracting boot files from ISO..."
    mkdir -p "$TFTP_DIR/grub" "$HTTP_DIR"

    EXTRACT_DIR=$(mktemp -d)
    if [[ "$HAS_7Z" == true ]]; then
        7z x -o"$EXTRACT_DIR" "$X86_ISO" EFI/boot casper/vmlinuz casper/initrd >/dev/null 2>&1 || \
        7z x -o"$EXTRACT_DIR" "$X86_ISO" >/dev/null 2>&1 || die "ISO extraction failed."
    elif [[ "$(uname)" == "Linux" ]]; then
        ISO_MNT=$(mktemp -d)
        mount -o loop,ro "$X86_ISO" "$ISO_MNT" || die "Could not mount ISO."
        rsync -a "$ISO_MNT/" "$EXTRACT_DIR/"
        umount "$ISO_MNT"
        rmdir "$ISO_MNT"
    else
        die "Cannot extract ISO. Install p7zip: brew install p7zip"
    fi

    # Copy EFI binaries to TFTP
    EFI_SRC=$(find "$EXTRACT_DIR/EFI" -iname "bootx64.efi" -print -quit 2>/dev/null)
    [[ -n "$EFI_SRC" ]] && cp "$EFI_SRC" "${TFTP_DIR}/bootx64.efi"
    for efi in grubx64.efi mmx64.efi; do
        SRC=$(find "$EXTRACT_DIR/EFI" -iname "$efi" -print -quit 2>/dev/null)
        [[ -n "$SRC" ]] && cp "$SRC" "${TFTP_DIR}/$efi"
    done

    # Copy GRUB modules
    if [[ -d "$EXTRACT_DIR/boot/grub" ]]; then
        mkdir -p "${TFTP_DIR}/boot/grub"
        rsync -a "$EXTRACT_DIR/boot/grub/" "${TFTP_DIR}/boot/grub/" 2>/dev/null || true
    fi

    # Copy kernel + initrd to HTTP dir
    [[ -f "$EXTRACT_DIR/casper/vmlinuz" ]] && cp "$EXTRACT_DIR/casper/vmlinuz" "${HTTP_DIR}/vmlinuz"
    [[ -f "$EXTRACT_DIR/casper/initrd" ]]  && cp "$EXTRACT_DIR/casper/initrd"  "${HTTP_DIR}/initrd"

    rm -rf "$EXTRACT_DIR"

    [[ ! -f "${TFTP_DIR}/bootx64.efi" ]] && die "Failed to extract BOOTX64.EFI from ISO."
    [[ ! -f "${HTTP_DIR}/vmlinuz" ]]      && die "Failed to extract vmlinuz from ISO."
    [[ ! -f "${HTTP_DIR}/initrd" ]]       && die "Failed to extract initrd from ISO."

    log "Boot files extracted"
fi

# ── Step 3: Set up autoinstall + ISO for HTTP ───────────────────────────
cp "$USER_DATA_X86" "${HTTP_DIR}/user-data"
touch "${HTTP_DIR}/meta-data"

# Symlink ISO for the installer to download
if [[ ! -e "${HTTP_DIR}/ubuntu.iso" ]]; then
    ln -sf "$X86_ISO" "${HTTP_DIR}/ubuntu.iso"
fi

# ── Step 4: Write GRUB config ───────────────────────────────────────────
# GRUB loaded via PXE doesn't have HTTP/TFTP modules, so it sources
# its config from the disk it finds with /.disk/info. We write the
# grub.cfg to the TFTP dir as a reference, but the actual boot config
# must be on the eSATA drive's x86 partition (prepare-usb.sh handles this).
#
# For pure PXE boot (no eSATA), GRUB falls to a prompt. The kernel/initrd
# are served by the PXE firmware before GRUB, so autoinstall still works
# if the UEFI firmware supports direct kernel loading.
mkdir -p "${TFTP_DIR}/grub"
cat > "${TFTP_DIR}/grub/grub.cfg" <<GRUBCFG
set default=0
set timeout=3

menuentry "Install Ubuntu 24.04 - K3s Autoinstall" {
    linux (tftp,${SERVER_IP})/vmlinuz autoinstall ip=dhcp url=http://${SERVER_IP}/ubuntu.iso "ds=nocloud-net;s=http://${SERVER_IP}/" quiet ---
    initrd (tftp,${SERVER_IP})/initrd
}
GRUBCFG

# Also copy kernel/initrd to TFTP for GRUB access (if modules are available)
cp "${HTTP_DIR}/vmlinuz" "${TFTP_DIR}/vmlinuz" 2>/dev/null || true
cp "${HTTP_DIR}/initrd"  "${TFTP_DIR}/initrd"  2>/dev/null || true

# ── Step 5: Stop any existing dnsmasq ───────────────────────────────────
if pgrep -x dnsmasq &>/dev/null; then
    warn "Stopping existing dnsmasq process..."
    killall dnsmasq 2>/dev/null || true
    sleep 1
fi

# ── Step 6: Start servers ───────────────────────────────────────────────
log ""
log "═══════════════════════════════════════════════════════════════"
log "  Starting PXE server on ${SERVER_IP}"
log ""
log "  HTTP:  http://${SERVER_IP}:80  (installer + autoinstall)"
log "  TFTP:  ${SERVER_IP}:69        (GRUB EFI bootloader)"
log "  DHCP:  proxy mode             (no conflict with router)"
log ""
log "  On target x86 machine:"
log "    1. Connect to same network"
log "    2. Boot from network (PXE / Onboard NIC IPv4)"
log "    3. Installation is fully automatic"
log ""
log "  Press Ctrl+C to stop all servers"
log "═══════════════════════════════════════════════════════════════"
log ""

# Start HTTP server in background
cd "$HTTP_DIR"
python3 -m http.server 80 &
HTTP_PID=$!

# Cleanup on exit
cleanup() {
    log ""
    log "Shutting down servers..."
    kill $HTTP_PID 2>/dev/null || true
    kill $DNSMASQ_PID 2>/dev/null || true
    wait $HTTP_PID 2>/dev/null || true
    wait $DNSMASQ_PID 2>/dev/null || true
    log "PXE server stopped."
}
trap cleanup EXIT INT TERM

# Start dnsmasq in foreground (so Ctrl+C stops everything)
dnsmasq \
    --no-daemon \
    --port=0 \
    --enable-tftp \
    --tftp-root="$TFTP_DIR" \
    --dhcp-range="${SUBNET},proxy" \
    --dhcp-boot=bootx64.efi \
    --pxe-service=x86-64_EFI,"K3s Ubuntu Autoinstall",bootx64.efi \
    --log-dhcp \
    --log-queries &
DNSMASQ_PID=$!

wait $DNSMASQ_PID

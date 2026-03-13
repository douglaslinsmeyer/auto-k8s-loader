#!/usr/bin/env bash
# ── K3s First-Boot Script ────────────────────────────────────────────
# Runs once on the first boot after Ubuntu autoinstall.
# Auto-detects whether to initialise a new k3s cluster or join an existing one
# using mDNS (Avahi) service discovery on the local network.
set -euo pipefail

LOG_TAG="k3s-first-boot"
log() { echo "[$(date -Is)] $*" | tee -a /var/log/k3s-bootstrap.log; logger -t "$LOG_TAG" "$*"; }

CONFIG="/opt/k3s-bootstrap/k3s-config.env"
if [[ ! -f "$CONFIG" ]]; then
    log "ERROR: Config file $CONFIG not found. Aborting."
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

# ── Validate critical config ────────────────────────────────────────
if [[ "${K3S_TOKEN}" == "CHANGE_ME"* ]]; then
    log "ERROR: K3S_TOKEN has not been set. Edit $CONFIG before deploying."
    exit 1
fi

# ── Wait for network ────────────────────────────────────────────────
log "Waiting for network connectivity..."
for i in $(seq 1 60); do
    if ping -c1 -W2 1.1.1.1 &>/dev/null; then
        log "Network is up."
        break
    fi
    sleep 2
done

# ── Set hostname to something unique (based on MAC of first NIC) ────
PRIMARY_MAC=$(ip -o link show | awk '!/lo:/{print $2; exit}' | tr -d ':')
PRIMARY_MAC=${PRIMARY_MAC%%:}  # strip trailing colon from device name
# Get actual MAC address
MAC_ADDR=$(cat /sys/class/net/$(ip -o link show | awk '!/lo/{gsub(/:$/,"",$2); print $2; exit}')/address 2>/dev/null | tr -d ':' | tail -c 7)
NEW_HOSTNAME="k3s-${MAC_ADDR}"
hostnamectl set-hostname "$NEW_HOSTNAME"
log "Hostname set to $NEW_HOSTNAME"

# ── Discover existing k3s servers via mDNS ──────────────────────────
log "Scanning for existing k3s cluster via mDNS (timeout: ${K3S_DISCOVERY_TIMEOUT}s)..."

# Make sure avahi is running
systemctl start avahi-daemon 2>/dev/null || true
sleep 3

DISCOVERED_SERVER=""
if command -v avahi-browse &>/dev/null; then
    # Browse for the k3s service; timeout after K3S_DISCOVERY_TIMEOUT seconds
    BROWSE_OUTPUT=$(timeout "${K3S_DISCOVERY_TIMEOUT}" avahi-browse -rpt "$K3S_MDNS_SERVICE" 2>/dev/null || true)
    # Extract the first IPv4 address found
    DISCOVERED_SERVER=$(echo "$BROWSE_OUTPUT" | awk -F';' '/^=.*IPv4/ {print $8; exit}')
fi

# ── Determine role ──────────────────────────────────────────────────
ROLE=""
if [[ -n "${K3S_FORCE_ROLE}" ]]; then
    ROLE="${K3S_FORCE_ROLE}"
    log "Role forced via config: $ROLE"
elif [[ -n "$DISCOVERED_SERVER" ]]; then
    ROLE="agent"
    log "Discovered existing server at $DISCOVERED_SERVER → joining as agent"
else
    ROLE="server"
    log "No existing cluster found → initialising as server"
fi

# ── Install k3s ─────────────────────────────────────────────────────
INSTALL_URL="https://get.k3s.io"
VERSION_FLAG=""
if [[ -n "${K3S_VERSION}" ]]; then
    VERSION_FLAG="INSTALL_K3S_VERSION=${K3S_VERSION}"
fi

if [[ "$ROLE" == "server" ]]; then
    log "Installing k3s SERVER..."
    EXTRA_ARGS="${K3S_EXTRA_SERVER_ARGS}"
    [[ -n "${K3S_CLUSTER_CIDR}" ]] && EXTRA_ARGS+=" --cluster-cidr=${K3S_CLUSTER_CIDR}"
    [[ -n "${K3S_SERVICE_CIDR}" ]] && EXTRA_ARGS+=" --service-cidr=${K3S_SERVICE_CIDR}"

    curl -sfL "$INSTALL_URL" | \
        K3S_TOKEN="${K3S_TOKEN}" \
        ${VERSION_FLAG:+$VERSION_FLAG} \
        INSTALL_K3S_EXEC="server ${EXTRA_ARGS}" \
        sh -

    # Publish this server via mDNS so future nodes can discover it
    log "Publishing mDNS service ${K3S_MDNS_SERVICE} on port ${K3S_API_PORT}..."
    cat > /etc/avahi/services/k3s-server.service <<AVAHI
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">k3s-server on %h</name>
  <service>
    <type>${K3S_MDNS_SERVICE}</type>
    <port>${K3S_API_PORT}</port>
  </service>
</service-group>
AVAHI
    systemctl restart avahi-daemon

    # Wait for k3s to be ready
    log "Waiting for k3s server to become ready..."
    for i in $(seq 1 120); do
        if /usr/local/bin/k3s kubectl get nodes &>/dev/null; then
            log "k3s server is ready."
            break
        fi
        sleep 2
    done

    # Copy kubeconfig for the admin user
    mkdir -p /home/k3sadmin/.kube
    cp /etc/rancher/k3s/k3s.yaml /home/k3sadmin/.kube/config
    chown -R k3sadmin:k3sadmin /home/k3sadmin/.kube
    chmod 600 /home/k3sadmin/.kube/config

else
    log "Installing k3s AGENT joining server ${DISCOVERED_SERVER}..."
    curl -sfL "$INSTALL_URL" | \
        K3S_URL="https://${DISCOVERED_SERVER}:${K3S_API_PORT}" \
        K3S_TOKEN="${K3S_TOKEN}" \
        ${VERSION_FLAG:+$VERSION_FLAG} \
        INSTALL_K3S_EXEC="agent ${K3S_EXTRA_AGENT_ARGS}" \
        sh -

    log "Waiting for k3s agent to register..."
    sleep 15
fi

log "First boot complete. Role=$ROLE Host=$(hostname)"

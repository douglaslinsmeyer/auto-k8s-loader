#!/usr/bin/env bash
# ── fetch-kubeconfig.sh ─────────────────────────────────────────────────
# Fetches the kubeconfig from the k3s server node and saves it locally.
# Run from your laptop (macOS or Linux) after the first node is up.
#
# Usage:
#   ./fetch-kubeconfig.sh                  # auto-discover via mDNS
#   ./fetch-kubeconfig.sh 192.168.8.188    # specify server IP
#   ./fetch-kubeconfig.sh -u myuser 192.168.8.188  # custom SSH user
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

SSH_USER="k3sadmin"
SERVER_IP=""
KUBECONFIG_OUT="${HOME}/.kube/config-k3s"

# ── Parse args ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)   SSH_USER="$2"; shift 2 ;;
        -o|--output) KUBECONFIG_OUT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [-u user] [-o output_path] [server_ip]"
            echo ""
            echo "  -u, --user     SSH username (default: k3sadmin)"
            echo "  -o, --output   Output kubeconfig path (default: ~/.kube/config-k3s)"
            echo "  server_ip      k3s server IP (auto-discovers via mDNS if omitted)"
            exit 0
            ;;
        *)           SERVER_IP="$1"; shift ;;
    esac
done

# ── Discover server via mDNS if no IP given ─────────────────────────────
if [[ -z "$SERVER_IP" ]]; then
    log "Scanning for k3s server via mDNS..."

    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: use dns-sd
        MDNS_OUTPUT=$(timeout 15 dns-sd -B _k3s-server._tcp local 2>&1 &
            BGPID=$!
            sleep 5
            kill $BGPID 2>/dev/null
            wait $BGPID 2>/dev/null
        ) || true

        # Get the hostname from the browse result
        K3S_HOST=$(echo "$MDNS_OUTPUT" | awk '/k3s-server on/ {print $NF}' | head -1)

        if [[ -n "$K3S_HOST" ]]; then
            # Resolve hostname to IP
            SERVER_IP=$(dns-sd -G v4 "${K3S_HOST}.local" 2>&1 &
                BGPID=$!
                sleep 3
                kill $BGPID 2>/dev/null
                wait $BGPID 2>/dev/null
            ) || true
            SERVER_IP=$(echo "$SERVER_IP" | awk '/Addr/ {print $NF}' | head -1)
        fi

        # Fallback: try avahi-browse if available
        if [[ -z "$SERVER_IP" ]] && command -v avahi-browse &>/dev/null; then
            SERVER_IP=$(timeout 15 avahi-browse -rpt _k3s-server._tcp 2>/dev/null | awk -F';' '/^=.*IPv4/ {print $8; exit}')
        fi
    else
        # Linux: use avahi-browse
        if command -v avahi-browse &>/dev/null; then
            SERVER_IP=$(timeout 15 avahi-browse -rpt _k3s-server._tcp 2>/dev/null | awk -F';' '/^=.*IPv4/ {print $8; exit}')
        fi
    fi

    if [[ -z "$SERVER_IP" ]]; then
        die "Could not discover k3s server via mDNS. Pass the server IP manually:\n  $0 192.168.x.x"
    fi

    log "Found k3s server at ${SERVER_IP}"
fi

# ── Wait for server to be reachable ─────────────────────────────────────
log "Waiting for ${SERVER_IP} to be reachable..."
for i in $(seq 1 30); do
    if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${SSH_USER}@${SERVER_IP}" "true" 2>/dev/null; then
        break
    fi
    if [[ $i -eq 30 ]]; then
        die "Cannot SSH to ${SSH_USER}@${SERVER_IP}. Make sure the server is up and SSH key is configured.\n  You may need to run: ssh-copy-id ${SSH_USER}@${SERVER_IP}"
    fi
    sleep 5
done

# ── Wait for k3s to be ready ────────────────────────────────────────────
log "Waiting for k3s to be ready on ${SERVER_IP}..."
for i in $(seq 1 60); do
    if ssh "${SSH_USER}@${SERVER_IP}" "sudo k3s kubectl get nodes" &>/dev/null; then
        log "k3s is ready."
        break
    fi
    if [[ $i -eq 60 ]]; then
        die "k3s is not ready after 5 minutes. Check: ssh ${SSH_USER}@${SERVER_IP} 'sudo journalctl -u k3s.service'"
    fi
    sleep 5
done

# ── Fetch kubeconfig ────────────────────────────────────────────────────
log "Fetching kubeconfig..."
mkdir -p "$(dirname "$KUBECONFIG_OUT")"

ssh "${SSH_USER}@${SERVER_IP}" "sudo cat /etc/rancher/k3s/k3s.yaml" | \
    sed "s|127.0.0.1|${SERVER_IP}|g" | \
    sed "s|localhost|${SERVER_IP}|g" > "$KUBECONFIG_OUT"

chmod 600 "$KUBECONFIG_OUT"

# ── Verify ──────────────────────────────────────────────────────────────
log "Verifying..."
if KUBECONFIG="$KUBECONFIG_OUT" kubectl get nodes 2>/dev/null; then
    log ""
    log "Kubeconfig saved to: ${KUBECONFIG_OUT}"
    log ""
    log "To use it:"
    log "  export KUBECONFIG=${KUBECONFIG_OUT}"
    log "  kubectl get nodes"
    log ""
    log "Or add to your shell profile:"
    log "  echo 'export KUBECONFIG=${KUBECONFIG_OUT}' >> ~/.bashrc"
else
    warn "Kubeconfig saved but kubectl verification failed."
    warn "You may need to install kubectl: brew install kubectl"
    log ""
    log "Kubeconfig saved to: ${KUBECONFIG_OUT}"
fi

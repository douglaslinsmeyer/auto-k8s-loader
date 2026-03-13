#!/usr/bin/env bash
# ── K3s Every-Boot Script ────────────────────────────────────────────
# Runs on every boot after the first-boot script has completed.
# Handles health checks, log rotation triggers, and basic cluster maintenance.
set -euo pipefail

LOG_TAG="k3s-every-boot"
log() { echo "[$(date -Is)] $*" | tee -a /var/log/k3s-bootstrap.log; logger -t "$LOG_TAG" "$*"; }

CONFIG="/opt/k3s-bootstrap/k3s-config.env"
[[ -f "$CONFIG" ]] && source "$CONFIG"

# ── Wait for network ────────────────────────────────────────────────
log "Waiting for network..."
for i in $(seq 1 30); do
    if ip route | grep -q default; then break; fi
    sleep 2
done

# ── Detect role (server has k3s-server.service, agent has k3s-agent.service)
if systemctl is-active --quiet k3s.service 2>/dev/null || systemctl is-active --quiet k3s-server.service 2>/dev/null; then
    ROLE="server"
elif systemctl is-active --quiet k3s-agent.service 2>/dev/null; then
    ROLE="agent"
else
    ROLE="unknown"
    log "WARNING: Could not determine k3s role. k3s may not be installed yet."
fi

log "Boot detected. Role=$ROLE Host=$(hostname)"

# ── Ensure k3s service is running ───────────────────────────────────
if [[ "$ROLE" == "server" ]]; then
    if ! systemctl is-active --quiet k3s.service 2>/dev/null; then
        log "k3s server service not running, attempting restart..."
        systemctl restart k3s.service || systemctl restart k3s-server.service || true
    fi

    # Ensure mDNS advertisement is active
    if [[ -f /etc/avahi/services/k3s-server.service ]]; then
        systemctl restart avahi-daemon 2>/dev/null || true
    fi

elif [[ "$ROLE" == "agent" ]]; then
    if ! systemctl is-active --quiet k3s-agent.service 2>/dev/null; then
        log "k3s agent service not running, attempting restart..."
        systemctl restart k3s-agent.service || true
    fi
fi

# ── Server-only: node health check ─────────────────────────────────
if [[ "$ROLE" == "server" ]]; then
    log "Running node health check..."
    if /usr/local/bin/k3s kubectl get nodes -o wide 2>/dev/null | tee -a /var/log/k3s-bootstrap.log; then
        NOT_READY=$(/usr/local/bin/k3s kubectl get nodes --no-headers 2>/dev/null | grep -c "NotReady" || true)
        if [[ "$NOT_READY" -gt 0 ]]; then
            log "WARNING: $NOT_READY node(s) in NotReady state."
        else
            log "All nodes healthy."
        fi
    else
        log "WARNING: kubectl not responding yet."
    fi
fi

# ── System maintenance ──────────────────────────────────────────────
# Clean up old container images to reclaim disk space
if command -v crictl &>/dev/null; then
    crictl rmi --prune 2>/dev/null || true
    log "Pruned unused container images."
fi

# Trim log if it's getting large (> 50MB)
LOG_FILE="/var/log/k3s-bootstrap.log"
if [[ -f "$LOG_FILE" ]]; then
    LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$LOG_SIZE" -gt 52428800 ]]; then
        tail -n 5000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "Rotated bootstrap log (was ${LOG_SIZE} bytes)."
    fi
fi

# ── NTP sync check ──────────────────────────────────────────────────
if command -v timedatectl &>/dev/null; then
    if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
        log "WARNING: NTP not synchronized. Cluster time drift possible."
        timedatectl set-ntp true 2>/dev/null || true
    fi
fi

log "Every-boot tasks complete."

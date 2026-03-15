#!/usr/bin/env bash
# ── lib/cluster.sh ──────────────────────────────────────────────────────
# Shared cluster profile management. Source this from prep scripts:
#   source "$(dirname "$0")/lib/cluster.sh"
#
# Provides:
#   select_cluster      — interactive cluster picker (sets CLUSTER_* vars)
#   create_cluster       — guided new cluster creation
#   apply_cluster_to_template — substitutes placeholders in a template file
#
# Cluster profiles live in clusters/<name>.env and contain:
#   CLUSTER_NAME, K3S_TOKEN, K3S_MDNS_SERVICE, K3S_EXTRA_SERVER_ARGS,
#   K3S_EXTRA_AGENT_ARGS, K3S_VERSION

# Resolve paths relative to the repo root (parent of lib/)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTERS_DIR="${REPO_DIR}/clusters"

# ── create_cluster ──────────────────────────────────────────────────────
# Interactive guided creation of a new cluster profile.
# Sets all CLUSTER_* variables and writes the .env file.
create_cluster() {
    echo ""
    echo -e "${BOLD:-\033[1m}Create a new cluster${NC:-\033[0m}"
    echo ""

    # Name
    local name=""
    while [[ -z "$name" ]]; do
        read -rp "  Cluster name (letters, numbers, hyphens): " name
        name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
        if [[ -z "$name" ]]; then
            echo "  Invalid name. Use only letters, numbers, and hyphens."
        elif [[ -f "${CLUSTERS_DIR}/${name}.env" ]]; then
            echo "  Cluster '${name}' already exists."
            name=""
        fi
    done

    # Token
    local token=""
    echo ""
    echo "  A cluster token is a shared secret that all nodes use to join."
    read -rp "  Generate a new token? [Y/n]: " gen_token
    if [[ "$(echo "$gen_token" | tr '[:upper:]' '[:lower:]')" == "n" ]]; then
        read -rp "  Enter token: " token
        [[ -z "$token" ]] && { echo "  Token cannot be empty."; return 1; }
    else
        if command -v openssl &>/dev/null; then
            token=$(openssl rand -hex 32)
        else
            token=$(head -c 32 /dev/urandom | xxd -p 2>/dev/null || cat /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | head -c 64)
        fi
        echo "  Generated token: ${token}"
    fi

    # mDNS service name — namespaced to prevent cross-cluster joins
    local mdns="_k3s-${name}._tcp"
    echo ""
    echo "  mDNS service type for cluster discovery: ${mdns}"
    echo "  (nodes in this cluster will only find each other)"

    # Extra args
    local extra_server="--disable traefik"
    echo ""
    read -rp "  Extra k3s server args [${extra_server}]: " input_server
    [[ -n "$input_server" ]] && extra_server="$input_server"

    local extra_agent=""
    read -rp "  Extra k3s agent args [none]: " input_agent
    [[ -n "$input_agent" ]] && extra_agent="$input_agent"

    # k3s version
    local version=""
    read -rp "  Pin k3s version? (leave blank for latest stable): " version

    # Write profile
    mkdir -p "$CLUSTERS_DIR"
    cat > "${CLUSTERS_DIR}/${name}.env" <<ENVEOF
# Cluster profile: ${name}
# Created: $(date -Is 2>/dev/null || date)
CLUSTER_NAME="${name}"
K3S_TOKEN="${token}"
K3S_MDNS_SERVICE="${mdns}"
K3S_EXTRA_SERVER_ARGS="${extra_server}"
K3S_EXTRA_AGENT_ARGS="${extra_agent}"
K3S_VERSION="${version}"
ENVEOF

    echo ""
    echo -e "${GREEN:-\033[0;32m}[+]${NC:-\033[0m} Cluster '${name}' created → clusters/${name}.env"

    # Load the profile we just created
    CLUSTER_NAME="$name"
    K3S_TOKEN="$token"
    K3S_MDNS_SERVICE="$mdns"
    K3S_EXTRA_SERVER_ARGS="$extra_server"
    K3S_EXTRA_AGENT_ARGS="$extra_agent"
    K3S_VERSION="$version"
}

# ── select_cluster ──────────────────────────────────────────────────────
# Lists available clusters and lets the user pick one or create new.
# After return, CLUSTER_NAME, K3S_TOKEN, etc. are set.
# Accepts optional argument: --cluster <name> for non-interactive use.
select_cluster() {
    local requested_cluster=""

    # Check for --cluster flag passed to the parent script
    # (caller should pass "$@" or the specific cluster name)
    if [[ "${1:-}" == "--cluster" ]] && [[ -n "${2:-}" ]]; then
        requested_cluster="$2"
    elif [[ -n "${1:-}" ]] && [[ -f "${CLUSTERS_DIR}/${1}.env" ]]; then
        requested_cluster="$1"
    fi

    # Non-interactive: load by name
    if [[ -n "$requested_cluster" ]]; then
        local envfile="${CLUSTERS_DIR}/${requested_cluster}.env"
        if [[ ! -f "$envfile" ]]; then
            echo -e "${RED:-\033[0;31m}[✗]${NC:-\033[0m} Cluster '${requested_cluster}' not found in clusters/" >&2
            echo "  Available: $(ls "${CLUSTERS_DIR}"/*.env 2>/dev/null | xargs -I{} basename {} .env | tr '\n' ' ')" >&2
            return 1
        fi
        source "$envfile"
        return 0
    fi

    # Find available profiles
    local profiles=()
    if [[ -d "$CLUSTERS_DIR" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] && profiles+=("$f")
        done < <(ls "${CLUSTERS_DIR}"/*.env 2>/dev/null | sort)
    fi

    # No profiles exist — go straight to creation
    if [[ ${#profiles[@]} -eq 0 ]]; then
        echo ""
        echo -e "${YELLOW:-\033[1;33m}[!]${NC:-\033[0m} No cluster profiles found."
        echo "  Let's set one up."
        create_cluster
        return $?
    fi

    # List available clusters
    echo ""
    echo -e "${BOLD:-\033[1m}Available clusters:${NC:-\033[0m}"
    echo ""

    local i=1
    local names=()
    for envfile in "${profiles[@]}"; do
        local cname=$(basename "$envfile" .env)
        names+=("$cname")

        # Read a few values for display
        local ctoken=$(grep '^K3S_TOKEN=' "$envfile" | head -1 | cut -d'"' -f2)
        local cmdns=$(grep '^K3S_MDNS_SERVICE=' "$envfile" | head -1 | cut -d'"' -f2)
        local token_preview="${ctoken:0:8}...${ctoken: -8}"

        echo -e "  ${GREEN:-\033[0;32m}${i})${NC:-\033[0m} ${BOLD:-\033[1m}${cname}${NC:-\033[0m}"
        echo -e "     token: ${token_preview}  mDNS: ${cmdns}"

        ((i++))
    done

    echo ""
    echo -e "  ${CYAN:-\033[0;36m}n)${NC:-\033[0m} Create a new cluster"
    echo ""

    read -rp "Select cluster [1-$((i-1))] or 'n' for new: " choice

    if [[ "$choice" == "n" || "$choice" == "N" ]]; then
        create_cluster
        return $?
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
        local selected="${profiles[$((choice-1))]}"
        source "$selected"
        echo -e "${GREEN:-\033[0;32m}[+]${NC:-\033[0m} Using cluster: ${CLUSTER_NAME}"
        return 0
    fi

    echo -e "${RED:-\033[0;31m}[✗]${NC:-\033[0m} Invalid selection." >&2
    return 1
}

# ── apply_cluster_to_template ───────────────────────────────────────────
# Reads a template file, substitutes %%PLACEHOLDER%% values with cluster
# config, writes result to the specified output path.
#
# Usage: apply_cluster_to_template <template_file> <output_file>
apply_cluster_to_template() {
    local template="$1"
    local output="$2"

    [[ ! -f "$template" ]] && { echo "Template not found: $template" >&2; return 1; }

    sed \
        -e "s|%%CLUSTER_NAME%%|${CLUSTER_NAME}|g" \
        -e "s|%%K3S_TOKEN%%|${K3S_TOKEN}|g" \
        -e "s|%%K3S_MDNS_SERVICE%%|${K3S_MDNS_SERVICE}|g" \
        -e "s|%%K3S_EXTRA_SERVER_ARGS%%|${K3S_EXTRA_SERVER_ARGS}|g" \
        -e "s|%%K3S_EXTRA_AGENT_ARGS%%|${K3S_EXTRA_AGENT_ARGS}|g" \
        -e "s|%%K3S_VERSION%%|${K3S_VERSION}|g" \
        "$template" > "$output"
}

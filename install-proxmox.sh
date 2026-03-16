#!/usr/bin/env bash
# Project N.O.M.A.D — Proxmox LXC Installer
#
# Run on the Proxmox HOST shell:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Lukas-tek-no-logic/project-nomad/main/install-proxmox.sh)"
#
# Creates a Debian 12 LXC, installs Docker inside, runs N.O.M.A.D.
# Supports arm64 (aarch64) and amd64 (x86_64).

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
CYAN='\033[0;36m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
err()  { echo -e "  ${RED}✗${NC} $*"; }
info() { echo -e "  ${BLUE}→${NC} $*"; }
hdr()  { echo -e "\n${CYAN}${BOLD}$*${NC}"; }

ask() {
    local reply
    printf "%b" "$1" > /dev/tty
    read -r reply < /dev/tty
    echo "${reply:-$2}"
}

ask_yn() {
    # ask_yn "Question" "y"  → default yes
    local reply
    printf "%b" "$1" > /dev/tty
    read -r reply < /dev/tty
    reply="${reply:-$2}"
    [[ "$reply" =~ ^[Yy] ]]
}

FORK_REGISTRY="ghcr.io/lukas-tek-no-logic"
FORK_REPO="Lukas-tek-no-logic/project-nomad"
NOMAD_DIR="/opt/project-nomad"

# ── banner ────────────────────────────────────────────────────────────────────
echo -e "${BLUE}${BOLD}"
echo "╔═══════════════════════════════════════════════════╗"
echo "║   Project N.O.M.A.D                              ║"
echo "║   Proxmox LXC Installer  (arm64 / amd64)         ║"
echo "╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "  Offline-first knowledge & AI server"
echo "  LXC (Debian 12) + Docker + arm64 images"
echo ""

# ── 1. verify Proxmox host ────────────────────────────────────────────────────
hdr "[1/8] Checking Proxmox host..."
if ! command -v pct &>/dev/null; then
    err "pct not found — run this script on the Proxmox VE host shell."
    exit 1
fi
ok "Proxmox VE detected"

HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    aarch64) ARCH="arm64" ;;
    x86_64)  ARCH="amd64" ;;
    *) err "Unsupported architecture: $HOST_ARCH"; exit 1 ;;
esac
ok "Host architecture: $ARCH"

# ── 2. find / download Debian 12 template ────────────────────────────────────
hdr "[2/8] Finding Debian 12 LXC template..."

TEMPLATE_FILE=$(find /var/lib/vz/template/cache/ -name "debian-12-*${ARCH}*.tar.*" 2>/dev/null | sort -V | tail -1 || true)

if [[ -z "$TEMPLATE_FILE" ]]; then
    info "Not found locally — checking Proxmox mirrors..."
    pveam update 2>/dev/null || true
    TEMPLATE_NAME=$(pveam available --section system 2>/dev/null \
        | awk '{print $2}' | grep -E "debian-12.*${ARCH}" | sort -V | tail -1 || true)

    if [[ -n "$TEMPLATE_NAME" ]]; then
        pveam download local "$TEMPLATE_NAME"
        TEMPLATE_FILE="/var/lib/vz/template/cache/$TEMPLATE_NAME"
    else
        warn "No ${ARCH} template in Proxmox mirrors. Downloading from linuxcontainers.org..."
        LC_BASE="https://images.linuxcontainers.org/images/debian/bookworm/${ARCH}/default"
        LC_VER=$(curl -s "${LC_BASE}/" | grep -oP '\d{8}_\d+:\d+' | tail -1)
        if [[ -z "$LC_VER" ]]; then
            err "Could not fetch template list from linuxcontainers.org"
            exit 1
        fi
        TEMPLATE_FILE="/var/lib/vz/template/cache/debian-12-standard_${ARCH}.tar.xz"
        info "Downloading ${LC_VER} rootfs (~100 MB)..."
        wget -q --show-progress \
            "${LC_BASE}/${LC_VER}/rootfs.tar.xz" \
            -O "$TEMPLATE_FILE"
    fi
fi

ok "Template: $(basename "$TEMPLATE_FILE")"
TEMPLATE_STOR="local:vztmpl/$(basename "$TEMPLATE_FILE")"

# ── 3. LXC configuration ──────────────────────────────────────────────────────
hdr "[3/8] Configure LXC..."
echo ""

echo "  Available storage:"
pvesm status --content rootdir 2>/dev/null \
    | awk 'NR>1 {printf "    %-20s %s GiB free\n", $1, int($5/1024/1024)}' || true
echo ""

DEFAULT_STORAGE=$(pvesm status --content rootdir 2>/dev/null \
    | awk 'NR>1 {print $1; exit}')
DEFAULT_STORAGE=${DEFAULT_STORAGE:-local}

CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
CTID=$(ask     "  Container ID [${CTID}]: "       "$CTID")
STORAGE=$(ask  "  Storage [${DEFAULT_STORAGE}]: " "$DEFAULT_STORAGE")
HOSTNAME=$(ask "  Hostname [project-nomad]: "      "project-nomad")
RAM=$(ask      "  RAM MB [2048]: "                 "2048")
DISK=$(ask     "  Disk GB [20]: "                  "20")
CORES=$(ask    "  CPU cores [2]: "                 "2")

echo ""
LAST_IP=$(grep -h '^net0:' /etc/pve/lxc/*.conf 2>/dev/null \
    | grep -oE 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
    | grep -oE '[0-9]+$' | sort -n | tail -1 || echo "")
SUGGEST_LAST=$(( ${LAST_IP:-199} + 1 ))
DEFAULT_IP="192.168.0.${SUGGEST_LAST}/24"

CT_IP=$(ask  "  Container IP [${DEFAULT_IP}]: "  "$DEFAULT_IP")
GW=$(ask     "  Gateway [192.168.0.1]: "          "192.168.0.1")

# ── 4. service selection ──────────────────────────────────────────────────────
hdr "[4/8] Select optional services..."
echo ""
echo "  Core services (always installed):"
echo "    ✓ Command Center (Web UI)  — port 8080"
echo "    ✓ MySQL + Redis"
echo "    ✓ Dozzle (log viewer)      — port 9999"
echo ""
echo "  Optional services:"
echo ""

INSTALL_OLLAMA=false
INSTALL_KIWIX=false
INSTALL_KOLIBRI=false
INSTALL_CYBERCHEF=false
INSTALL_FLATNOTES=false
OLLAMA_MODEL=""
PULL_MAPS=()
LLM_BACKEND_TYPE=""
LLM_REMOTE_URL=""
LLM_LOCAL_OLLAMA=false

if ask_yn "  AI Assistant — LLM-powered chat with knowledge base [y/N]: " "n"; then
    INSTALL_OLLAMA=true
    echo ""
    echo "  LLM backend:"
    echo "    1) Local Ollama     — runs on this machine (default, no internet needed)"
    echo "    2) Remote Ollama    — connect to Ollama running on another server"
    echo "    3) Remote llama.cpp — connect to llama-server on another server"
    LLM_CHOICE=$(ask "  Choice [1]: " "1")
    case "$LLM_CHOICE" in
        2)
            LLM_BACKEND_TYPE="ollama"
            LLM_REMOTE_URL=$(ask "  Remote Ollama URL (e.g. http://192.168.0.50:11434): " "")
            if [[ -z "$LLM_REMOTE_URL" ]]; then
                err "Remote URL is required for remote Ollama. Falling back to local."
                LLM_LOCAL_OLLAMA=true
                LLM_BACKEND_TYPE=""
                LLM_REMOTE_URL=""
            else
                ok "Remote Ollama: $LLM_REMOTE_URL"
            fi
            ;;
        3)
            LLM_BACKEND_TYPE="llamacpp"
            LLM_REMOTE_URL=$(ask "  Remote llama.cpp URL (e.g. http://192.168.0.50:8080): " "")
            if [[ -z "$LLM_REMOTE_URL" ]]; then
                err "Remote URL is required for llama.cpp. Falling back to local Ollama."
                LLM_LOCAL_OLLAMA=true
                LLM_BACKEND_TYPE=""
                LLM_REMOTE_URL=""
            else
                ok "Remote llama.cpp: $LLM_REMOTE_URL"
            fi
            ;;
        *)
            LLM_LOCAL_OLLAMA=true
            ok "Local Ollama selected (port 11434)"
            ;;
    esac

    # Model selection only for local Ollama (remote manages its own models)
    if $LLM_LOCAL_OLLAMA; then
        echo ""
        echo "  Select AI model to pre-download:"
        echo "    1) llama3.2:3b    (~2 GB, fast, good quality)"
        echo "    2) llama3.2:1b    (~1 GB, very fast, lighter)"
        echo "    3) mistral:7b     (~4 GB, excellent quality)"
        echo "    4) phi3:mini      (~2 GB, Microsoft, efficient)"
        echo "    5) gemma3:4b      (~3 GB, Google, multilingual)"
        echo "    6) None (download later via UI)"
        MODEL_CHOICE=$(ask "  Choice [1]: " "1")
        case "$MODEL_CHOICE" in
            1) OLLAMA_MODEL="llama3.2:3b" ;;
            2) OLLAMA_MODEL="llama3.2:1b" ;;
            3) OLLAMA_MODEL="mistral:7b" ;;
            4) OLLAMA_MODEL="phi3:mini" ;;
            5) OLLAMA_MODEL="gemma3:4b" ;;
            *) OLLAMA_MODEL="" ;;
        esac
        [[ -n "$OLLAMA_MODEL" ]] && ok "Model: $OLLAMA_MODEL"
    fi
fi

echo ""
if ask_yn "  Information Library — Kiwix (offline Wikipedia, books) [y/N]: " "n"; then
    INSTALL_KIWIX=true
    ok "Information Library selected (port 8090)"
fi

echo ""
if ask_yn "  Education Platform — Kolibri (interactive courses) [y/N]: " "n"; then
    INSTALL_KOLIBRI=true
    ok "Education Platform selected (port 8300)"
fi

echo ""
if ask_yn "  Data Tools — CyberChef (encoding, encryption, analysis) [y/N]: " "n"; then
    INSTALL_CYBERCHEF=true
    ok "Data Tools selected (port 8100)"
fi

echo ""
if ask_yn "  Notes — FlatNotes (simple markdown notes) [y/N]: " "n"; then
    INSTALL_FLATNOTES=true
    ok "Notes selected (port 8200)"
fi

# ── 5. map regions selection ──────────────────────────────────────────────────
echo ""
if ask_yn "  Maps — download offline map regions? [y/N]: " "n"; then
    echo ""
    echo "  Available regions (PMTiles):"
    echo ""
    echo "  US regions:"
    echo "    1)  Pacific          — Alaska, California, Hawaii, Oregon, Washington"
    echo "    2)  Mountain         — Arizona, Colorado, Idaho, Montana, Nevada, New Mexico, Utah, Wyoming"
    echo "    3)  West South Central — Arkansas, Louisiana, Oklahoma, Texas"
    echo "    4)  East South Central — Alabama, Kentucky, Mississippi, Tennessee"
    echo "    5)  South Atlantic   — Delaware, DC, Florida, Georgia, Maryland, NC, SC, Virginia, WV"
    echo "    6)  West North Central — Iowa, Kansas, Minnesota, Missouri, Nebraska, ND, SD"
    echo "    7)  East North Central — Illinois, Indiana/Michigan, Ohio, Wisconsin"
    echo "    8)  Mid-Atlantic     — New Jersey, New York, Pennsylvania"
    echo "    9)  New England      — Connecticut, Maine, Massachusetts, NH, Rhode Island, Vermont"
    echo ""
    echo "  European regions:"
    echo "    10) Northern Europe   — Norway, Sweden, Finland, Denmark, Iceland, Baltics"
    echo "    11) British Isles     — United Kingdom, Ireland"
    echo "    12) Western Europe    — France, Belgium, Netherlands, Luxembourg"
    echo "    13) Central Europe    — Germany, Poland, Czech Republic, Austria, Switzerland, Hungary, Slovakia"
    echo "    14) Southern Europe   — Spain, Portugal, Italy, Greece, Malta, Cyprus"
    echo "    15) SE Europe         — Romania, Bulgaria, Croatia, Slovenia, Serbia, Balkans"
    echo ""
    echo "  Enter region numbers separated by spaces (e.g. '1 3 13'), or Enter to skip:"
    read -r MAP_INPUT < /dev/tty
    for n in $MAP_INPUT; do
        case "$n" in
            1)  PULL_MAPS+=("pacific") ;;
            2)  PULL_MAPS+=("mountain") ;;
            3)  PULL_MAPS+=("west-south-central") ;;
            4)  PULL_MAPS+=("east-south-central") ;;
            5)  PULL_MAPS+=("south-atlantic") ;;
            6)  PULL_MAPS+=("west-north-central") ;;
            7)  PULL_MAPS+=("east-north-central") ;;
            8)  PULL_MAPS+=("mid-atlantic") ;;
            9)  PULL_MAPS+=("new-england") ;;
            10) PULL_MAPS+=("northern-europe") ;;
            11) PULL_MAPS+=("british-isles") ;;
            12) PULL_MAPS+=("western-europe") ;;
            13) PULL_MAPS+=("central-europe") ;;
            14) PULL_MAPS+=("southern-europe") ;;
            15) PULL_MAPS+=("southeastern-europe") ;;
        esac
    done
    if [[ ${#PULL_MAPS[@]} -gt 0 ]]; then
        ok "Map regions: ${PULL_MAPS[*]}"
    fi
fi

# ── summary before creating ───────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  Summary:"
echo "    LXC ID:     $CTID"
echo "    Hostname:   $HOSTNAME"
echo "    IP:         $CT_IP"
echo "    RAM/Disk:   ${RAM} MB / ${DISK} GB"
echo "    Arch:       $ARCH"
echo "    Services:   Command Center, MySQL, Redis, Dozzle"
if $INSTALL_OLLAMA && [[ -n "$LLM_REMOTE_URL" ]]; then
    echo "                + AI Assistant (${LLM_BACKEND_TYPE} @ ${LLM_REMOTE_URL})"
elif $INSTALL_OLLAMA; then
    echo "                + AI Assistant (local Ollama${OLLAMA_MODEL:+ — $OLLAMA_MODEL})"
fi
$INSTALL_KIWIX     && echo "                + Information Library (Kiwix)"
$INSTALL_KOLIBRI   && echo "                + Education Platform (Kolibri)"
$INSTALL_CYBERCHEF && echo "                + Data Tools (CyberChef)"
$INSTALL_FLATNOTES && echo "                + Notes (FlatNotes)"
[[ ${#PULL_MAPS[@]} -gt 0 ]] && echo "    Maps:       ${PULL_MAPS[*]}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
ask_yn "  Proceed? [Y/n]: " "y" || { echo "Aborted."; exit 0; }

# ── 6. create LXC ────────────────────────────────────────────────────────────
hdr "[5/8] Creating LXC ${CTID}..."

BRIDGE=$(grep -h 'bridge=' /etc/pve/lxc/*.conf 2>/dev/null \
    | grep -oE 'bridge=[^,]+' | cut -d= -f2 \
    | sort | uniq -c | sort -rn | awk 'NR==1{print $2}' || echo "vmbr0")
BRIDGE=${BRIDGE:-vmbr0}
info "Network bridge: $BRIDGE"

pct create "$CTID" "$TEMPLATE_STOR" \
    --hostname "$HOSTNAME" \
    --memory   "$RAM" \
    --cores    "$CORES" \
    --rootfs   "${STORAGE}:${DISK}" \
    --net0     "name=eth0,bridge=${BRIDGE},ip=${CT_IP},gw=${GW}" \
    --unprivileged 0 \
    --ostype   debian \
    --features "nesting=1,keyctl=1" \
    --start    1 \
    --onboot   1

ok "Container $CTID created and started"
info "Waiting for boot..."
sleep 6

# ── 7. install Docker + pull images ──────────────────────────────────────────
hdr "[6/8] Installing Docker + pulling images..."
info "This takes 3-8 minutes depending on your connection."

pct exec "$CTID" -- bash -euo pipefail << 'DOCKER_INSTALL'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release git

curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker
sleep 3
docker --version
DOCKER_INSTALL

ok "Docker installed"

# ── 8. pull images + start compose ───────────────────────────────────────────
hdr "[7/8] Pulling images + starting N.O.M.A.D..."

# Build list of extra images to pre-pull
EXTRA_PULLS=()
$LLM_LOCAL_OLLAMA  && EXTRA_PULLS+=("ollama/ollama:0.15.2" "qdrant/qdrant:v1.16")
$INSTALL_KIWIX     && EXTRA_PULLS+=("ghcr.io/kiwix/kiwix-serve:3.8.1")
$INSTALL_KOLIBRI   && EXTRA_PULLS+=("treehouses/kolibri:0.12.8")
$INSTALL_CYBERCHEF && EXTRA_PULLS+=("ghcr.io/gchq/cyberchef:10.19.4")
$INSTALL_FLATNOTES && EXTRA_PULLS+=("dullage/flatnotes:v5.5.4")

pct exec "$CTID" -- bash -euo pipefail << PROVISION
export DEBIAN_FRONTEND=noninteractive

mkdir -p ${NOMAD_DIR}/storage/{zim,qdrant,ollama,flatnotes,kolibri,maps/pmtiles,logs}
touch ${NOMAD_DIR}/storage/logs/admin.log

# Download compose + helper scripts from fork
curl -fsSL "https://raw.githubusercontent.com/${FORK_REPO}/main/install/management_compose.yaml" \
    -o "${NOMAD_DIR}/compose.yml"

curl -fsSL "https://raw.githubusercontent.com/${FORK_REPO}/main/install/entrypoint.sh" \
    -o "${NOMAD_DIR}/entrypoint.sh" && chmod +x "${NOMAD_DIR}/entrypoint.sh"

curl -fsSL "https://raw.githubusercontent.com/vishnubob/wait-for-it/master/wait-for-it.sh" \
    -o "${NOMAD_DIR}/wait-for-it.sh" && chmod +x "${NOMAD_DIR}/wait-for-it.sh"

mkdir -p "${NOMAD_DIR}/sidecar-updater"
curl -fsSL "https://raw.githubusercontent.com/${FORK_REPO}/main/install/sidecar-updater/Dockerfile" \
    -o "${NOMAD_DIR}/sidecar-updater/Dockerfile"
curl -fsSL "https://raw.githubusercontent.com/${FORK_REPO}/main/install/sidecar-updater/update-watcher.sh" \
    -o "${NOMAD_DIR}/sidecar-updater/update-watcher.sh" && chmod +x "${NOMAD_DIR}/sidecar-updater/update-watcher.sh"

# Inject IP into compose
CT_BARE_IP=\$(echo "${CT_IP}" | cut -d/ -f1)
APP_KEY=\$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
DB_PASS=\$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
ROOT_PASS=\$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)

sed -i "s|URL=replaceme|URL=http://\${CT_BARE_IP}:8080|g"      "${NOMAD_DIR}/compose.yml"
sed -i "s|APP_KEY=replaceme|APP_KEY=\${APP_KEY}|g"             "${NOMAD_DIR}/compose.yml"
sed -i "s|DB_PASSWORD=replaceme|DB_PASSWORD=\${DB_PASS}|g"     "${NOMAD_DIR}/compose.yml"
sed -i "s|MYSQL_ROOT_PASSWORD=replaceme|MYSQL_ROOT_PASSWORD=\${ROOT_PASS}|g" "${NOMAD_DIR}/compose.yml"
sed -i "s|MYSQL_PASSWORD=replaceme|MYSQL_PASSWORD=\${DB_PASS}|g" "${NOMAD_DIR}/compose.yml"

# Inject LLM backend configuration if using remote server
LLM_BACKEND_TYPE_VAL="${LLM_BACKEND_TYPE}"
LLM_REMOTE_URL_VAL="${LLM_REMOTE_URL}"
if [[ -n "\${LLM_REMOTE_URL_VAL}" ]]; then
    # Uncomment and set the LLM env vars in compose.yml
    sed -i "s|# - LLM_BACKEND_TYPE=ollama|      - LLM_BACKEND_TYPE=\${LLM_BACKEND_TYPE_VAL}|g" "${NOMAD_DIR}/compose.yml"
    sed -i "s|# - LLM_REMOTE_URL=http://192.168.0.50:11434|      - LLM_REMOTE_URL=\${LLM_REMOTE_URL_VAL}|g" "${NOMAD_DIR}/compose.yml"
fi

echo "Starting core services..."
cd "${NOMAD_DIR}"
docker compose -p project-nomad -f compose.yml up -d
PROVISION

ok "Core services started"

# Pre-pull optional images
if [[ ${#EXTRA_PULLS[@]} -gt 0 ]]; then
    info "Pre-pulling optional service images..."
    for img in "${EXTRA_PULLS[@]}"; do
        info "Pulling $img..."
        pct exec "$CTID" -- docker pull "$img" || warn "Failed to pull $img (can be installed later)"
    done
fi

# Start selected optional services
if $LLM_LOCAL_OLLAMA; then
    info "Starting Qdrant (vector DB)..."
    pct exec "$CTID" -- docker run -d \
        --name nomad_qdrant \
        --network project-nomad_default \
        --restart unless-stopped \
        -v "${NOMAD_DIR}/storage/qdrant:/qdrant/storage" \
        -p 6333:6333 -p 6334:6334 \
        qdrant/qdrant:v1.16 || warn "Qdrant start failed"

    info "Starting Ollama (AI)..."
    pct exec "$CTID" -- docker run -d \
        --name nomad_ollama \
        --network project-nomad_default \
        --restart unless-stopped \
        -v "${NOMAD_DIR}/storage/ollama:/root/.ollama" \
        -p 11434:11434 \
        ollama/ollama:0.15.2 serve || warn "Ollama start failed"
elif $INSTALL_OLLAMA && [[ -n "$LLM_REMOTE_URL" ]]; then
    info "Using remote LLM backend at $LLM_REMOTE_URL — skipping local Ollama/Qdrant containers"
fi

if $INSTALL_KIWIX; then
    info "Starting Kiwix..."
    pct exec "$CTID" -- docker run -d \
        --name nomad_kiwix_server \
        --network project-nomad_default \
        --restart unless-stopped \
        -v "${NOMAD_DIR}/storage/zim:/data" \
        -p 8090:8080 \
        ghcr.io/kiwix/kiwix-serve:3.8.1 "*.zim --address=all" || warn "Kiwix start failed"
fi

if $INSTALL_CYBERCHEF; then
    info "Starting CyberChef..."
    pct exec "$CTID" -- docker run -d \
        --name nomad_cyberchef \
        --network project-nomad_default \
        --restart unless-stopped \
        -p 8100:80 \
        ghcr.io/gchq/cyberchef:10.19.4 || warn "CyberChef start failed"
fi

if $INSTALL_FLATNOTES; then
    info "Starting FlatNotes..."
    pct exec "$CTID" -- docker run -d \
        --name nomad_flatnotes \
        --network project-nomad_default \
        --restart unless-stopped \
        -v "${NOMAD_DIR}/storage/flatnotes:/data" \
        -p 8200:8080 \
        -e FLATNOTES_AUTH_TYPE=none \
        dullage/flatnotes:v5.5.4 || warn "FlatNotes start failed"
fi

if $INSTALL_KOLIBRI; then
    info "Starting Kolibri..."
    pct exec "$CTID" -- docker run -d \
        --name nomad_kolibri \
        --network project-nomad_default \
        --restart unless-stopped \
        -v "${NOMAD_DIR}/storage/kolibri:/root/.kolibri" \
        -p 8300:8080 \
        treehouses/kolibri:0.12.8 || warn "Kolibri start failed"
fi

# Pull Ollama model (only for local Ollama)
if $LLM_LOCAL_OLLAMA && [[ -n "$OLLAMA_MODEL" ]]; then
    info "Waiting for Ollama to start..."
    sleep 10
    info "Pulling model $OLLAMA_MODEL (this may take a while)..."
    pct exec "$CTID" -- docker exec nomad_ollama ollama pull "$OLLAMA_MODEL" \
        || warn "Model pull failed — pull it later from the UI"
fi

# ── download maps ─────────────────────────────────────────────────────────────
if [[ ${#PULL_MAPS[@]} -gt 0 ]]; then
    hdr "[8/8] Downloading map regions..."

    # Map slug → array of pmtiles URLs from collections/maps.json
    declare -A MAP_URLS
    MAP_URLS["pacific"]="alaska_2025-12.pmtiles california_2025-12.pmtiles hawaii_2025-12.pmtiles oregon_2025-12.pmtiles washington_2025-12.pmtiles"
    MAP_URLS["mountain"]="arizona_2025-12.pmtiles colorado_2025-12.pmtiles idaho_2025-12.pmtiles montana_2025-12.pmtiles nevada_2025-12.pmtiles new_mexico_2025-12.pmtiles utah_2025-12.pmtiles wyoming_2025-12.pmtiles"
    MAP_URLS["west-south-central"]="arkansas_2025-12.pmtiles louisiana_2025-12.pmtiles oklahoma_2025-12.pmtiles texas_2025-12.pmtiles"
    MAP_URLS["east-south-central"]="alabama_2025-12.pmtiles kentucky_2025-12.pmtiles mississippi_2025-12.pmtiles tennessee_2025-12.pmtiles"
    MAP_URLS["south-atlantic"]="delaware_2025-12.pmtiles district_of_columbia_2025-12.pmtiles florida_2025-12.pmtiles georgia_2025-12.pmtiles maryland_2025-12.pmtiles north_carolina_2025-12.pmtiles south_carolina_2025-12.pmtiles virginia_2025-12.pmtiles west_virginia_2025-12.pmtiles"
    MAP_URLS["west-north-central"]="iowa_2025-12.pmtiles kansas_2025-12.pmtiles minnesota_2025-12.pmtiles missouri_2025-12.pmtiles nebraska_2025-12.pmtiles north_dakota_2025-12.pmtiles south_dakota_2025-12.pmtiles"
    MAP_URLS["east-north-central"]="illinois_2025-12.pmtiles indianamichigan_2025-12.pmtiles ohio_2025-12.pmtiles wisconsin_2025-12.pmtiles"
    MAP_URLS["mid-atlantic"]="new_jersey_2025-12.pmtiles new_york_2025-12.pmtiles pennsylvania_2025-12.pmtiles"
    MAP_URLS["new-england"]="connecticut_2025-12.pmtiles maine_2025-12.pmtiles massachusetts_2025-12.pmtiles new_hampshire_2025-12.pmtiles rhode_island_2025-12.pmtiles vermont_2025-12.pmtiles"

    MAP_URLS["northern-europe"]="norway_2025-03.pmtiles sweden_2025-03.pmtiles finland_2025-03.pmtiles denmark_2025-03.pmtiles iceland_2025-03.pmtiles estonia_2025-03.pmtiles latvia_2025-03.pmtiles lithuania_2025-03.pmtiles"
    MAP_URLS["british-isles"]="united_kingdom_2025-03.pmtiles ireland_2025-03.pmtiles"
    MAP_URLS["western-europe"]="france_2025-03.pmtiles belgium_2025-03.pmtiles netherlands_2025-03.pmtiles luxembourg_2025-03.pmtiles"
    MAP_URLS["central-europe"]="germany_2025-03.pmtiles poland_2025-03.pmtiles czech_republic_2025-03.pmtiles austria_2025-03.pmtiles switzerland_2025-03.pmtiles hungary_2025-03.pmtiles slovakia_2025-03.pmtiles"
    MAP_URLS["southern-europe"]="spain_2025-03.pmtiles portugal_2025-03.pmtiles italy_2025-03.pmtiles greece_2025-03.pmtiles malta_2025-03.pmtiles cyprus_2025-03.pmtiles"
    MAP_URLS["southeastern-europe"]="romania_2025-03.pmtiles bulgaria_2025-03.pmtiles croatia_2025-03.pmtiles slovenia_2025-03.pmtiles serbia_2025-03.pmtiles bosnia_herzegovina_2025-03.pmtiles montenegro_2025-03.pmtiles albania_2025-03.pmtiles north_macedonia_2025-03.pmtiles kosovo_2025-03.pmtiles"

    MAP_BASE_US="https://github.com/Crosstalk-Solutions/project-nomad-maps/raw/refs/heads/master/pmtiles"
    MAP_BASE_EU="https://github.com/Lukas-tek-no-logic/project-nomad-maps-europe/raw/refs/heads/main/pmtiles"
    MAP_DIR="${NOMAD_DIR}/storage/maps/pmtiles"

    # Download base map assets first
    info "Downloading base map assets..."
    pct exec "$CTID" -- bash -c "
        mkdir -p ${MAP_DIR}
        curl -fsSL 'https://github.com/Crosstalk-Solutions/project-nomad-maps/raw/refs/heads/master/base-assets.tar.gz' \
            -o /tmp/base-assets.tar.gz && \
        tar -xzf /tmp/base-assets.tar.gz --strip=1 -C '${NOMAD_DIR}/storage/maps/' && \
        rm -f /tmp/base-assets.tar.gz
    " || warn "Base map assets download failed"

    # European region slugs for URL routing
    EU_REGIONS="northern-europe british-isles western-europe central-europe southern-europe southeastern-europe"

    for region in "${PULL_MAPS[@]}"; do
        info "Downloading region: $region"

        # Pick the right base URL
        MAP_BASE="${MAP_BASE_US}"
        if echo "$EU_REGIONS" | grep -qw "$region"; then
            MAP_BASE="${MAP_BASE_EU}"
        fi

        for fname in ${MAP_URLS[$region]:-}; do
            info "  → $fname"
            pct exec "$CTID" -- bash -c "
                curl -fsSL --retry 3 --retry-delay 5 \
                    '${MAP_BASE}/${fname}' \
                    -o '${MAP_DIR}/${fname}' || echo 'WARN: failed to download ${fname}'
            " || warn "Failed: $fname"
        done
    done
    ok "Maps downloaded"
fi

# ── summary ───────────────────────────────────────────────────────────────────
CT_BARE_IP=$(echo "$CT_IP" | cut -d/ -f1)

echo ""
echo -e "${GREEN}${BOLD}"
echo "╔═══════════════════════════════════════════════════╗"
echo "║   Installation complete!                          ║"
echo "╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Command Center:  ${BOLD}http://${CT_BARE_IP}:8080${NC}"
echo -e "  Log Viewer:      http://${CT_BARE_IP}:9999"
echo ""
if $INSTALL_OLLAMA && [[ -n "$LLM_REMOTE_URL" ]]; then
    echo -e "  AI Assistant:    http://${CT_BARE_IP}:8080/chat  (${LLM_BACKEND_TYPE} @ ${LLM_REMOTE_URL})"
elif $INSTALL_OLLAMA; then
    echo -e "  AI Assistant:    http://${CT_BARE_IP}:8080/chat  (Ollama: port 11434)"
fi
$INSTALL_KIWIX     && echo -e "  Library:         http://${CT_BARE_IP}:8090"
$INSTALL_CYBERCHEF && echo -e "  Data Tools:      http://${CT_BARE_IP}:8100"
$INSTALL_FLATNOTES && echo -e "  Notes:           http://${CT_BARE_IP}:8200"
$INSTALL_KOLIBRI   && echo -e "  Education:       http://${CT_BARE_IP}:8300"
echo ""
echo "  Management (run on Proxmox host):"
echo "    pct exec ${CTID} -- docker ps"
echo "    pct exec ${CTID} -- docker compose -p project-nomad -f ${NOMAD_DIR}/compose.yml logs -f"
echo "    pct exec ${CTID} -- docker compose -p project-nomad -f ${NOMAD_DIR}/compose.yml restart"
echo ""
echo "  Update all containers:"
echo "    pct exec ${CTID} -- docker compose -p project-nomad -f ${NOMAD_DIR}/compose.yml pull && \\"
echo "    pct exec ${CTID} -- docker compose -p project-nomad -f ${NOMAD_DIR}/compose.yml up -d"
echo ""

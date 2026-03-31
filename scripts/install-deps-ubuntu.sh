#!/usr/bin/env bash
#
# install-deps-ubuntu.sh
# Install all BDK6 dependencies on Ubuntu/Mint with Podman (Apache 2.0)
# Usage: sudo ./install-deps-ubuntu.sh [--clean]
#
# Default: resumes from where it left off, reuses existing installs.
# --clean: wipe venv, re-download tools, fresh install from scratch.
#
# Container runtime: Podman (Apache 2.0 licensed, preferred for blockchain)
# Exposes 'docker' CLI command via podman-docker for Kurtosis compatibility.
# For Docker CE version, use install-deps-ubuntu-docker.sh instead.
#
set -euo pipefail

# ─── Clean install flag ──────────────────────────────────────────────
CLEAN_INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN_INSTALL=true ;;
    esac
done

# ─── Constants ────────────────────────────────────────────────────────
GO_VERSION="1.24.4"
NODE_MAJOR=20
POLYCLI_VERSION="v0.1.108"
YQ_VERSION="v4.44.1"
FOUNDRY_NIGHTLY="nightly-f625d0fa7c51e65b4bf1e8f7931cd1c6e2e285e9"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Ensure tool paths are available (sudo may strip PATH) ───────────
export PATH="/opt/bdk6/venv/bin:/usr/local/go/bin:$HOME/.foundry/bin:/usr/local/bin:$PATH"

# ─── Detect architecture ─────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  GOARCH="amd64"; YQARCH="amd64" ;;
    aarch64) GOARCH="arm64"; YQARCH="arm64" ;;
    *) echo "FATAL: Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ─── Detect the real user (when run with sudo) ───────────────────────
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# ─── Progress bar ─────────────────────────────────────────────────────
# Source: https://github.com/Professor-Codephreak/progressbar
TOTAL_STEPS=11
CURRENT_STEP=0

if [[ -t 1 ]] && command -v tput &>/dev/null; then
    source "$SCRIPT_DIR/progressbar.sh"
    HAS_PROGRESSBAR=true
    ILoveCandy=false
    CursorDone="#"
    CursorNotDone="-"
else
    HAS_PROGRESSBAR=false
fi

show_progress() {
    if [[ "$HAS_PROGRESSBAR" == true ]]; then
        progressbar "BDK6 Install" "$CURRENT_STEP" "$TOTAL_STEPS" "[$CURRENT_STEP/$TOTAL_STEPS]" "$*"
        echo ""
    fi
}

# ─── Helpers ──────────────────────────────────────────────────────────
info()  { echo -e "\e[1;32m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[1;33m[WARN]\e[0m  $*"; }
error() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; }
ok()    { echo -e "\e[1;32m  [OK]\e[0m  $*"; }

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo ""
    echo -e "\e[1;36m=====> [$CURRENT_STEP/$TOTAL_STEPS] $*\e[0m"
    show_progress "$*"
}

step_done() {
    show_progress "$* done"
}

substep() {
    echo -e "       \e[0;37m-> $*\e[0m"
}

trap 'error "Script failed at line $LINENO. Command: $BASH_COMMAND"' ERR

is_installed() {
    command -v "$1" &>/dev/null
}

# apt-get update that tolerates third-party repo failures
apt_update() {
    if ! apt-get update -qq 2>&1; then
        warn "apt update had warnings from third-party repos (non-fatal, continuing...)"
    fi
}

# ─── Root check — auto-elevate with sudo if needed ──────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Root privileges required. Requesting sudo..."
    exec sudo bash "$0" "$@"
fi

echo ""
echo "=============================================="
echo "  BDK6 Dependency Installer — Ubuntu"
echo "=============================================="
echo "  Architecture : $ARCH ($GOARCH)"
echo "  User         : $REAL_USER"
echo "  Runtime      : Podman (Apache 2.0)"
echo "  Mode         : $( [[ "$CLEAN_INSTALL" == true ]] && echo "clean install" || echo "resume (use --clean for fresh)")"
echo "  Steps        : $TOTAL_STEPS"
echo "=============================================="
show_progress "Starting..."

# ─── 1. System packages ──────────────────────────────────────────────
step "Installing system packages"
substep "Updating apt package index..."
apt_update
substep "Installing build tools (git, curl, gcc, make, protobuf)..."
apt-get install -y --no-install-recommends \
    git curl wget bc make gcc g++ build-essential \
    ca-certificates gnupg lsb-release \
    protobuf-compiler \
    postgresql-client \
    python3 python3-pip python3-venv \
    software-properties-common \
    apt-transport-https \
    unzip uidmap
ok "System packages installed"

# Create or reuse BDK6 Python virtual environment
BDK6_VENV="/opt/bdk6/venv"
if [[ "$CLEAN_INSTALL" == true ]] && [[ -d "$BDK6_VENV" ]]; then
    substep "Clean install: removing existing venv..."
    rm -rf "$BDK6_VENV"
fi
if [[ -d "$BDK6_VENV" ]] && [[ -x "$BDK6_VENV/bin/pip" ]]; then
    info "Python venv already exists at $BDK6_VENV, reusing."
    export PATH="$BDK6_VENV/bin:$PATH"
else
    substep "Creating Python venv at $BDK6_VENV..."
    python3 -m venv "$BDK6_VENV"
    export PATH="$BDK6_VENV/bin:$PATH"
    "$BDK6_VENV/bin/pip" install --upgrade pip setuptools >/dev/null 2>&1 || true
    ok "Python venv ready"
fi
step_done "System packages"

# ─── 2. Go ───────────────────────────────────────────────────────────
step "Installing Go $GO_VERSION"
if [[ "$CLEAN_INSTALL" == true ]]; then
    rm -rf /usr/local/go
fi
if is_installed go && [[ "$(go version 2>/dev/null)" == *"go${GO_VERSION}"* ]]; then
    info "Go $GO_VERSION already installed, skipping."
else
    GO_TAR="go${GO_VERSION}.linux-${GOARCH}.tar.gz"
    substep "Downloading Go ${GO_VERSION} for ${GOARCH}..."
    curl -fsSL "https://go.dev/dl/${GO_TAR}" -o "/tmp/${GO_TAR}"
    substep "Extracting to /usr/local/go..."
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${GO_TAR}"
    rm -f "/tmp/${GO_TAR}"
    export PATH="/usr/local/go/bin:$PATH"
    ok "Go $(go version | awk '{print $3}') installed"
fi

substep "Persisting PATH for $REAL_USER..."
PROFILE_LINE='export PATH="/opt/bdk6/venv/bin:/usr/local/go/bin:$HOME/go/bin:$HOME/.foundry/bin:$PATH"'
for rc in "$REAL_HOME/.bashrc" "$REAL_HOME/.profile"; do
    if [[ -f "$rc" ]] && ! grep -qF '/usr/local/go/bin' "$rc"; then
        echo "$PROFILE_LINE" >> "$rc"
    fi
done
step_done "Go"

# ─── 3. Node.js 20.x LTS ────────────────────────────────────────────
step "Installing Node.js ${NODE_MAJOR}.x LTS"
if is_installed node && [[ "$(node --version 2>/dev/null)" == v${NODE_MAJOR}.* ]]; then
    info "Node.js $(node --version) already installed, skipping."
else
    substep "Adding NodeSource GPG key..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg --yes
    substep "Adding NodeSource repository..."
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    substep "Installing Node.js ${NODE_MAJOR}.x..."
    apt_update
    apt-get install -y nodejs
    ok "Node.js $(node --version) installed"
fi
step_done "Node.js"

# ─── 4. Podman container runtime ─────────────────────────────────────
step "Installing Podman container runtime (Docker-compatible)"

# Remove Docker CE packages that conflict with podman-docker
if dpkg -l docker-ce-cli &>/dev/null 2>&1; then
    substep "Removing Docker CE packages (conflict with podman-docker)..."
    apt-get remove -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
fi

# Clean up stale Docker repos
if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
    substep "Removing stale Docker apt repository..."
    rm -f /etc/apt/sources.list.d/docker.list
fi
if [[ -f /etc/apt/sources.list.d/additional-repositories.list ]] && \
    grep -q 'download.docker.com' /etc/apt/sources.list.d/additional-repositories.list 2>/dev/null; then
    substep "Removing stale Docker entry from additional-repositories.list..."
    sed -i '/download\.docker\.com/d' /etc/apt/sources.list.d/additional-repositories.list
fi

# Determine minimum podman version needed (4.0+ for Docker API compat / Kurtosis)
PODMAN_MIN_MAJOR=4
needs_podman_upgrade=false
if is_installed podman; then
    CURRENT_PODMAN="$(podman --version | awk '{print $3}')"
    CURRENT_PODMAN_MAJOR="$(echo "$CURRENT_PODMAN" | cut -d. -f1)"
    if [[ "$CURRENT_PODMAN_MAJOR" -lt "$PODMAN_MIN_MAJOR" ]]; then
        warn "Podman $CURRENT_PODMAN is too old for Kurtosis (need >= 4.0). Upgrading..."
        needs_podman_upgrade=true
    else
        info "Podman $CURRENT_PODMAN already installed (>= 4.0), skipping."
    fi
else
    needs_podman_upgrade=true
fi

if [[ "$needs_podman_upgrade" == true ]]; then
    # Remove old podman 3.x from default Ubuntu repos
    if is_installed podman; then
        substep "Removing old Podman $(podman --version | awk '{print $3}')..."
        apt-get remove -y podman podman-docker 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
    fi

    # Add Kubic repo for Podman 4.x+ (use UBUNTU_CODENAME for Mint/derivatives)
    BASE_VERSION="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    # Map codename to Ubuntu version number for Kubic URL
    case "$BASE_VERSION" in
        jammy)  KUBIC_UBUNTU="22.04" ;;
        noble)  KUBIC_UBUNTU="24.04" ;;
        *)      KUBIC_UBUNTU="$(. /etc/os-release && echo "$VERSION_ID")" ;;
    esac
    substep "Adding Kubic repository for Podman 4.x (Ubuntu ${KUBIC_UBUNTU})..."
    mkdir -p /etc/apt/keyrings
    KUBIC_URL="https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/unstable/xUbuntu_${KUBIC_UBUNTU}"
    curl -fsSL "${KUBIC_URL}/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/kubic-libcontainers.gpg --yes
    echo "deb [signed-by=/etc/apt/keyrings/kubic-libcontainers.gpg] ${KUBIC_URL}/ /" \
        > /etc/apt/sources.list.d/kubic-libcontainers.list
    apt_update

    substep "Installing Podman 4.x and podman-docker..."
    apt-get install -y podman podman-docker
    substep "Installing podman-compose into venv..."
    "$BDK6_VENV/bin/pip" install podman-compose >/dev/null 2>&1 || true
    ok "Podman $(podman --version | awk '{print $3}') installed"
fi

# Grant socket access to the real user via a podman group
substep "Configuring socket permissions for $REAL_USER..."
groupadd -f podman
usermod -aG podman "$REAL_USER"

# Set default network to "bridge" BEFORE starting the service
# Kurtosis expects Docker-style default bridge network
substep "Setting Podman default network to 'bridge'..."
mkdir -p /etc/containers
if [[ -f /etc/containers/containers.conf ]]; then
    if grep -q 'default_network' /etc/containers/containers.conf 2>/dev/null; then
        sed -i 's/^.*default_network.*/default_network = "bridge"/' /etc/containers/containers.conf
    else
        if grep -q '^\[network\]' /etc/containers/containers.conf 2>/dev/null; then
            sed -i '/^\[network\]/a default_network = "bridge"' /etc/containers/containers.conf
        else
            printf '\n[network]\ndefault_network = "bridge"\n' >> /etc/containers/containers.conf
        fi
    fi
else
    cat > /etc/containers/containers.conf << 'CONFEOF'
[network]
default_network = "bridge"
CONFEOF
fi

# ── Podman API + Docker proxy systemd services ──────────────────────
# Kubic podman package masks the stock podman.socket/podman.service.
# Rather than fight the mask, we create our own service pair:
#   podman-api.service        → runs podman system service on a unix socket
#   podman-docker-proxy.service → Python proxy that fixes bridge name filter bug
substep "Installing Podman API services..."
# Stop everything first
pkill -f "podman system service" 2>/dev/null || true
pkill -f "podman-docker-proxy" 2>/dev/null || true
systemctl stop podman-docker-proxy podman-api podman.socket podman.service 2>/dev/null || true
rm -f /run/podman/podman.sock /run/podman/podman-real.sock /var/run/docker.sock
mkdir -p /run/podman

# Podman API service
cat > /etc/systemd/system/podman-api.service << 'SVCEOF'
[Unit]
Description=Podman API Service
After=network.target

[Service]
Type=exec
ExecStart=/usr/bin/podman system service --time=0 unix:///run/podman/podman.sock
ExecStartPost=/bin/bash -c 'for i in 1 2 3 4 5; do [ -S /run/podman/podman.sock ] && break; sleep 0.5; done; chgrp podman /run/podman/podman.sock 2>/dev/null; chmod 0660 /run/podman/podman.sock 2>/dev/null'
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
SVCEOF

# Docker API proxy service
cat > /etc/systemd/system/podman-docker-proxy.service << PROXYEOF
[Unit]
Description=Podman Docker API Proxy (Kurtosis bridge network workaround)
After=podman-api.service
Requires=podman-api.service

[Service]
Type=simple
Environment=UPSTREAM_SOCK=/run/podman/podman.sock
ExecStart=/usr/bin/python3 $SCRIPT_DIR/podman-docker-proxy.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
PROXYEOF

systemctl daemon-reload
systemctl enable --now podman-api
sleep 2
if [[ -S /run/podman/podman.sock ]]; then
    ok "Podman API service running"
else
    error "Podman API service failed — check: journalctl -u podman-api"
fi

systemctl enable --now podman-docker-proxy
sleep 2
if curl -sf --unix-socket /var/run/docker.sock http://localhost/version &>/dev/null; then
    ok "Docker API proxy running at /var/run/docker.sock"
else
    warn "Proxy not yet responding — will retry before Kurtosis launch"
fi

# Configure subuid/subgid for rootless podman
substep "Configuring rootless container support for $REAL_USER..."
grep -q "^${REAL_USER}:" /etc/subuid 2>/dev/null || \
    usermod --add-subuids 100000-165535 "$REAL_USER" 2>/dev/null || true
grep -q "^${REAL_USER}:" /etc/subgid 2>/dev/null || \
    usermod --add-subgids 100000-165535 "$REAL_USER" 2>/dev/null || true

# Remove stale Docker Desktop credential helper (breaks Kurtosis on Podman)
DOCKER_CONFIG="$REAL_HOME/.docker/config.json"
if [[ -f "$DOCKER_CONFIG" ]] && grep -q 'credsStore.*desktop' "$DOCKER_CONFIG" 2>/dev/null; then
    substep "Removing stale docker-credential-desktop from Docker config..."
    su -s /bin/bash "$REAL_USER" -c "sed -i '/.credsStore/d; /.currentContext/d' '$DOCKER_CONFIG'" 2>/dev/null || true
fi

ok "Podman container runtime ready"
step_done "Podman"

# ─── 5. Kurtosis CLI ─────────────────────────────────────────────────
step "Installing Kurtosis CLI"
if is_installed kurtosis; then
    info "Kurtosis already installed, skipping."
else
    substep "Adding Kurtosis apt repository..."
    echo "deb [trusted=yes] https://apt.fury.io/kurtosis-tech/ /" \
        > /etc/apt/sources.list.d/kurtosis.list
    substep "Installing kurtosis-cli package..."
    apt_update
    apt-get install -y kurtosis-cli
    ok "Kurtosis installed"
fi
step_done "Kurtosis"

# ─── 6. Foundry (forge, cast, anvil) ─────────────────────────────────
step "Installing Foundry toolchain"
if is_installed cast && is_installed forge; then
    info "Foundry already installed, skipping."
else
    export FOUNDRY_DIR="$REAL_HOME/.foundry"
    substep "Running foundryup installer..."
    su - "$REAL_USER" -c 'curl -fsSL https://foundry.paradigm.xyz | bash' || true
    substep "Installing Foundry nightly ($FOUNDRY_NIGHTLY)..."
    su - "$REAL_USER" -c "$REAL_HOME/.foundry/bin/foundryup --version $FOUNDRY_NIGHTLY" || \
    su - "$REAL_USER" -c "$REAL_HOME/.foundry/bin/foundryup"
    substep "Symlinking forge, cast, anvil, chisel to /usr/local/bin..."
    for bin in forge cast anvil chisel; do
        if [[ -f "$REAL_HOME/.foundry/bin/$bin" ]]; then
            ln -sf "$REAL_HOME/.foundry/bin/$bin" /usr/local/bin/
        fi
    done
    ok "Foundry installed"
fi
step_done "Foundry"

# ─── 7. Polygon CLI (polycli) ────────────────────────────────────────
step "Installing polycli $POLYCLI_VERSION"
if is_installed polycli; then
    info "polycli already installed, skipping."
else
    POLYCLI_BUILD_DIR="/tmp/polygon-cli-build"
    rm -rf "$POLYCLI_BUILD_DIR"
    substep "Cloning polygon-cli $POLYCLI_VERSION..."
    git clone --depth 1 --branch "$POLYCLI_VERSION" \
        https://github.com/maticnetwork/polygon-cli.git "$POLYCLI_BUILD_DIR"
    pushd "$POLYCLI_BUILD_DIR" >/dev/null
    export PATH="/usr/local/go/bin:$PATH"
    substep "Building polycli from source (this may take a minute)..."
    go build -o polycli main.go
    substep "Installing polycli to /usr/local/bin..."
    mv polycli /usr/local/bin/polycli
    chmod +x /usr/local/bin/polycli
    popd >/dev/null
    rm -rf "$POLYCLI_BUILD_DIR"
    ok "polycli installed"
fi
step_done "polycli"

# ─── 8. yq ───────────────────────────────────────────────────────────
step "Installing yq"
if is_installed yq; then
    info "yq already installed, skipping."
else
    substep "Downloading yq ${YQ_VERSION} for ${YQARCH}..."
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQARCH}" \
        -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
    ok "yq installed"
fi

substep "Installing pip-based yq (provides tomlq/xq) into venv..."
"$BDK6_VENV/bin/pip" install yq >/dev/null 2>&1 || true
step_done "yq"

# ─── 9. jq ───────────────────────────────────────────────────────────
step "Installing jq"
if is_installed jq; then
    info "jq already installed, skipping."
else
    substep "Installing jq via apt..."
    apt-get install -y jq
    ok "jq installed"
fi
step_done "jq"

# ─── 10. Python dependencies (mkdocs) ────────────────────────────────
step "Installing Python dependencies"
if [[ -f "$REPO_ROOT/scripts/requirements.txt" ]]; then
    substep "Installing from scripts/requirements.txt into venv..."
    "$BDK6_VENV/bin/pip" install -r "$REPO_ROOT/scripts/requirements.txt" >/dev/null 2>&1 || true
    ok "Python requirements installed"
else
    warn "scripts/requirements.txt not found, skipping."
fi
step_done "Python deps"

# ─── 11. Verification ────────────────────────────────────────────────
step "Verifying installations"
echo ""
FAIL=0

verify() {
    local name="$1" cmd="$2"
    if is_installed "$cmd"; then
        local ver=""
        case "$cmd" in
            go)       ver="$(go version 2>/dev/null | awk '{print $3}')" ;;
            node)     ver="$(node --version 2>/dev/null)" ;;
            podman)   ver="$(podman --version 2>/dev/null | awk '{print $3}')" ;;
            docker)   ver="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')" ;;
            kurtosis) ver="$(kurtosis version 2>/dev/null | head -1 | awk '{print $NF}')" ;;
            cast)     ver="$(cast --version 2>/dev/null | head -1 | awk '{print $2}')" ;;
            forge)    ver="$(forge --version 2>/dev/null | head -1 | awk '{print $2}')" ;;
            polycli)  ver="$(polycli version 2>/dev/null | head -1)" ;;
            yq)       ver="$(yq --version 2>/dev/null | awk '{print $NF}')" ;;
            jq)       ver="$(jq --version 2>/dev/null)" ;;
            python3)  ver="$(python3 --version 2>/dev/null | awk '{print $2}')" ;;
            protoc)   ver="$(protoc --version 2>/dev/null | awk '{print $2}')" ;;
            psql)     ver="$(psql --version 2>/dev/null | awk '{print $3}')" ;;
            *)        ver="ok" ;;
        esac
        printf "  \e[1;32m%-6s\e[0m %-22s %s\n" "[OK]" "$name" "$ver"
    else
        printf "  \e[1;31m%-6s\e[0m %-22s\n" "[FAIL]" "$name"
        FAIL=1
    fi
}

verify "Podman"          podman
# Docker CLI is installed later during Kurtosis deployment — soft check only
if is_installed docker; then
    printf "  \e[1;32m%-6s\e[0m %-22s %s\n" "[OK]" "Docker CLI" "$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
else
    printf "  \e[1;33m%-6s\e[0m %-22s %s\n" "[NOTE]" "Docker CLI" "(installed during deployment)"
fi
verify "Go"              go
verify "Node.js"         node
verify "Kurtosis"        kurtosis
verify "Foundry (cast)"  cast
verify "Foundry (forge)" forge
verify "Foundry (anvil)" anvil
verify "polycli"         polycli
verify "yq"              yq
verify "jq"              jq
verify "Python 3"        python3
verify "protoc"          protoc
verify "psql"            psql
verify "git"             git
verify "curl"            curl
verify "make"            make
verify "gcc"             gcc

# Check compose support
if podman compose version &>/dev/null 2>&1; then
    printf "  \e[1;32m%-6s\e[0m %-22s %s\n" "[OK]" "Podman Compose" "built-in"
elif is_installed podman-compose; then
    printf "  \e[1;32m%-6s\e[0m %-22s %s\n" "[OK]" "podman-compose" "$(podman-compose version 2>/dev/null | head -1)"
else
    printf "  \e[1;31m%-6s\e[0m %-22s\n" "[FAIL]" "Compose"
    FAIL=1
fi

echo ""
step_done "Verification"

if [[ $FAIL -eq 0 ]]; then
    echo ""
    show_progress "Complete!"
    echo ""
    echo -e "\e[1;32m=============================================="
    echo "  BDK6 — All dependencies installed!"
    echo "  Container runtime: Podman (Apache 2.0)"
    echo "==============================================\e[0m"
    echo ""
    info "Note: 'docker' command is aliased to podman for full Kurtosis compatibility."
    echo ""

    # ─── Clean slate for Kurtosis ───────────────────────────────────────
    substep "Cleaning up stale Kurtosis containers and networks..."
    podman rm -f $(podman ps -aq --filter label=com.kurtosistech.app-id=kurtosis) 2>/dev/null || true
    for net in $(podman network ls --format '{{.Name}}' 2>/dev/null); do
        if [[ "$net" == kt-* ]]; then
            podman network rm -f "$net" 2>/dev/null || true
        fi
    done

    # Ensure bridge network exists
    substep "Ensuring 'bridge' network exists for Kurtosis..."
    if ! podman network exists bridge 2>/dev/null; then
        podman network create bridge >/dev/null 2>&1 || true
        ok "Created 'bridge' network"
    else
        info "'bridge' network already exists."
    fi

    # ─── Verify Docker API proxy ────────────────────────────────────────
    substep "Verifying Docker API proxy..."
    PROXY_OK=false
    for attempt in 1 2 3 4 5 6; do
        if curl -sf --unix-socket /var/run/docker.sock http://localhost/version &>/dev/null; then
            ok "Docker API proxy responding"
            PROXY_OK=true
            break
        fi
        sleep 2
    done
    if [[ "$PROXY_OK" != true ]]; then
        error "Docker API proxy not responding after 12s"
        # Safe pipeline: capture then print (avoids SIGPIPE with set -e)
        STATUS_OUT="$(systemctl status podman-api podman-docker-proxy --no-pager 2>&1 || true)"
        echo "$STATUS_OUT" | head -20 || true
    fi

    # ─── Deploy BDK6 via Kurtosis ───────────────────────────────────────
    # Kurtosis 2.1.0 requires Docker CE for enclave creation.
    # Podman remains the primary container runtime (Apache 2.0).
    info "Preparing Kurtosis deployment..."

    # ── 1. Kill everything that could conflict ───────────────────────
    substep "Cleaning up all previous state..."

    # Flush stale iptables DNAT rules from Podman port-forwarding
    iptables -t nat -F BDK_KURTOSIS 2>/dev/null || true
    iptables -t nat -D OUTPUT -j BDK_KURTOSIS 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j BDK_KURTOSIS_POST 2>/dev/null || true
    iptables -t nat -F BDK_KURTOSIS_POST 2>/dev/null || true
    iptables -t nat -X BDK_KURTOSIS 2>/dev/null || true
    iptables -t nat -X BDK_KURTOSIS_POST 2>/dev/null || true

    # Stop Podman services that fight Docker for /var/run/docker.sock
    systemctl stop podman-docker-proxy podman-api podman.socket podman.service 2>/dev/null || true
    systemctl disable podman-docker-proxy podman-api 2>/dev/null || true
    pkill -f "podman system service" 2>/dev/null || true
    pkill -f "podman-docker-proxy" 2>/dev/null || true
    pkill -f "socat.*TCP-LISTEN" 2>/dev/null || true
    rm -f /run/podman/podman.sock /run/podman/podman-real.sock 2>/dev/null || true

    # Kill any existing Kurtosis containers
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        docker rm -f $(docker ps -aq --filter label=com.kurtosistech.app-id=kurtosis) 2>/dev/null || true
    fi

    # ── 2. Ensure Docker CE is installed and running ─────────────────
    if ! command -v dockerd &>/dev/null; then
        substep "Installing Docker CE for Kurtosis deployment..."
        UBUNTU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-$(lsb_release -cs)}}")"

        rm -f /etc/apt/sources.list.d/docker.list
        if [[ -f /etc/apt/sources.list.d/additional-repositories.list ]]; then
            sed -i '/download\.docker\.com/d' /etc/apt/sources.list.d/additional-repositories.list 2>/dev/null || true
        fi

        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=${GOARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
            > /etc/apt/sources.list.d/docker.list
        apt_update
        apt-get install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
        ok "Docker CE installed"
    fi

    # Configure Docker daemon (MTU fix for Kurtosis enclave git clones)
    substep "Configuring Docker daemon..."
    mkdir -p /etc/docker
    if [[ -f /etc/docker/daemon.json ]]; then
        # Merge mtu into existing config
        if ! grep -q '"mtu"' /etc/docker/daemon.json 2>/dev/null; then
            python3 -c "
import json
with open('/etc/docker/daemon.json') as f:
    cfg = json.load(f)
cfg['mtu'] = 1400
with open('/etc/docker/daemon.json','w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null || true
        fi
    else
        echo '{"mtu": 1400}' > /etc/docker/daemon.json
    fi

    # Make sure Docker daemon is running with new config
    systemctl enable docker
    systemctl restart docker
    groupadd -f docker
    usermod -aG docker "$REAL_USER"

    # Wait for Docker socket
    for i in $(seq 1 10); do
        docker info &>/dev/null && break
        sleep 1
    done

    # Clean stale credential helpers
    DOCKER_CONFIG="$REAL_HOME/.docker/config.json"
    if [[ -f "$DOCKER_CONFIG" ]] && grep -q 'credsStore.*desktop' "$DOCKER_CONFIG" 2>/dev/null; then
        su -s /bin/bash "$REAL_USER" -c "sed -i '/.credsStore/d; /.currentContext/d' '$DOCKER_CONFIG'" 2>/dev/null || true
    fi

    # Create Kurtosis log directory
    mkdir -p /var/log/kurtosis
    chown -R "$REAL_USER" /var/log/kurtosis
    chmod -R 755 /var/log/kurtosis

    ok "Docker CE running (MTU=1400)"

    # ── 3. Clean stale enclaves and start Kurtosis engine ──────────
    substep "Removing stale Kurtosis enclaves..."
    su - "$REAL_USER" -s /bin/bash -c "sg docker -c 'kurtosis engine stop'" 2>/dev/null || true
    docker rm -f $(docker ps -aq --filter label=com.kurtosistech.app-id=kurtosis) 2>/dev/null || true
    su - "$REAL_USER" -s /bin/bash -c "sg docker -c 'kurtosis clean --all'" 2>/dev/null || true

    substep "Starting Kurtosis engine..."
    su - "$REAL_USER" -s /bin/bash -c "sg docker -c 'kurtosis engine restart'" 2>&1 || true

    # Countdown while gRPC initializes
    substep "Waiting for Kurtosis engine gRPC to initialize..."
    for remaining in $(seq 20 -1 1); do
        printf "\r       Engine initializing... %2ds " "$remaining"
        sleep 1
    done
    printf "\r       Engine initializing... done.    \n"

    # Poll for readiness
    GRPC_READY=false
    for i in $(seq 1 12); do
        if su - "$REAL_USER" -s /bin/bash -c "sg docker -c 'kurtosis engine status'" 2>&1 | grep -q "engine is running"; then
            GRPC_READY=true
            ok "Kurtosis engine ready"
            break
        fi
        echo -n "."
        sleep 5
    done
    echo ""

    # ── 4. Deploy BDK6 enclave ───────────────────────────────────────
    if [[ "$GRPC_READY" == true ]]; then
        substep "Deploying BDK6 enclave (this takes 5-20 minutes)..."
        su - "$REAL_USER" -s /bin/bash -c "sg docker -c 'cd $REPO_ROOT && kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always .'" 2>&1 || {
            warn "BDK6 deployment returned an error. Check output above."
            info "Retry: newgrp docker && cd $REPO_ROOT"
            info "  kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always ."
        }
    else
        warn "Kurtosis engine did not become ready."
        info "Run manually:"
        info "  newgrp docker"
        info "  kurtosis engine restart"
        info "  sleep 20"
        info "  cd $REPO_ROOT && kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always ."
    fi
else
    warn "Some dependencies failed to install. Review the output above."
    exit 1
fi

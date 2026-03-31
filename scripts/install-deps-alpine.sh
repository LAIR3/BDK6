#!/usr/bin/env sh
#
# install-deps-alpine.sh
# Install all BDK6 dependencies on Alpine Linux 3.19+
# Uses Podman as the container runtime (Docker-API compatible)
# Usage: run as root (no sudo on Alpine by default)
#
# If bash is not yet available, install it and re-exec under bash
# (needed for the progress bar library)
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        echo "[INFO]  Installing bash for progress bar support..."
        apk add --no-cache bash ncurses >/dev/null 2>&1
    fi
    exec bash "$0" "$@"
fi

# Now running under bash
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────
GO_VERSION="1.24.4"
NODE_MAJOR=20
POLYCLI_VERSION="v0.1.108"
YQ_VERSION="v4.44.1"
FOUNDRY_NIGHTLY="nightly-f625d0fa7c51e65b4bf1e8f7931cd1c6e2e285e9"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Detect architecture ─────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  GOARCH="amd64"; YQARCH="amd64" ;;
    aarch64) GOARCH="arm64"; YQARCH="arm64" ;;
    *) echo "FATAL: Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ─── Progress bar ─────────────────────────────────────────────────────
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

# ─── Root check ──────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

echo ""
echo "=============================================="
echo "  BDK6 Dependency Installer — Alpine"
echo "=============================================="
echo "  Architecture : $ARCH ($GOARCH)"
echo "  Runtime      : Podman (Docker-compatible)"
echo "  Steps        : $TOTAL_STEPS"
echo "=============================================="
show_progress "Starting..."

# ─── 1. System packages ──────────────────────────────────────────────
step "Installing system packages"
substep "Updating apk package index..."
apk update
substep "Installing build tools and runtime dependencies..."
apk add --no-cache \
    git curl wget bc make gcc g++ musl-dev libc-dev \
    ca-certificates \
    protobuf protobuf-dev \
    postgresql-client \
    python3 py3-pip \
    bash coreutils grep sed gawk \
    ncurses \
    linux-headers \
    openrc \
    shadow \
    unzip tar \
    gcompat
ok "System packages installed"

# Create BDK6 Python virtual environment
BDK6_VENV="/opt/bdk6/venv"
substep "Creating Python venv at $BDK6_VENV..."
python3 -m venv "$BDK6_VENV"
export PATH="$BDK6_VENV/bin:$PATH"
"$BDK6_VENV/bin/pip" install --upgrade pip setuptools >/dev/null 2>&1 || true
ok "Python venv ready"
step_done "System packages"

# ─── 2. Go ───────────────────────────────────────────────────────────
step "Installing Go $GO_VERSION"
if is_installed go && go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
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

substep "Persisting PATH globally..."
cat > /etc/profile.d/bdk6-path.sh << 'PATHEOF'
export PATH="/opt/bdk6/venv/bin:/usr/local/go/bin:$HOME/go/bin:$HOME/.foundry/bin:$PATH"
PATHEOF
chmod +x /etc/profile.d/bdk6-path.sh
export PATH="/opt/bdk6/venv/bin:/usr/local/go/bin:$HOME/go/bin:$HOME/.foundry/bin:$PATH"
step_done "Go"

# ─── 3. Node.js 20.x LTS ────────────────────────────────────────────
step "Installing Node.js ${NODE_MAJOR}.x LTS"
if is_installed node && node --version 2>/dev/null | grep -q "^v${NODE_MAJOR}\."; then
    info "Node.js $(node --version) already installed, skipping."
else
    substep "Installing Node.js from apk..."
    apk add --no-cache nodejs npm
    INSTALLED_NODE="$(node --version 2>/dev/null || echo 'none')"
    if ! echo "$INSTALLED_NODE" | grep -q "^v${NODE_MAJOR}\."; then
        warn "apk provided Node $INSTALLED_NODE; fetching v${NODE_MAJOR}.x musl build..."
        substep "Downloading Node.js ${NODE_MAJOR}.x musl binary..."
        NODE_FULL="$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/" \
            | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        if [[ -n "$NODE_FULL" ]]; then
            NODE_URL="https://unofficial-builds.nodejs.org/download/release/${NODE_FULL}/node-${NODE_FULL}-linux-${GOARCH}-musl.tar.gz"
            if curl -fsSL --head "$NODE_URL" >/dev/null 2>&1; then
                curl -fsSL "$NODE_URL" -o /tmp/node.tar.gz
                tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1
                rm -f /tmp/node.tar.gz
            else
                warn "Musl build not available; using apk Node $INSTALLED_NODE"
            fi
        fi
    fi
    ok "Node.js $(node --version) installed"
fi
step_done "Node.js"

# ─── 4. Podman (container runtime) ───────────────────────────────────
step "Installing Podman container runtime"
if is_installed podman; then
    info "Podman $(podman --version | awk '{print $3}') already installed, skipping."
else
    substep "Installing Podman and rootless dependencies..."
    apk add --no-cache \
        podman \
        fuse-overlayfs \
        slirp4netns \
        crun \
        shadow-uidmap
    substep "Installing podman-compose into venv..."
    "$BDK6_VENV/bin/pip" install podman-compose >/dev/null 2>&1 || true
    ok "Podman installed"
fi

# Configure Podman storage for overlay
substep "Configuring Podman storage driver..."
mkdir -p /etc/containers
if [[ ! -f /etc/containers/storage.conf ]] || ! grep -q 'driver.*=.*"overlay"' /etc/containers/storage.conf 2>/dev/null; then
    cat > /etc/containers/storage.conf << 'STOREOF'
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
STOREOF
fi

# Configure registries for unqualified image pulls
substep "Configuring container registries..."
if [[ ! -f /etc/containers/registries.conf ]] || ! grep -q 'unqualified-search-registries' /etc/containers/registries.conf 2>/dev/null; then
    cat > /etc/containers/registries.conf << 'REGEOF'
unqualified-search-registries = ["docker.io", "ghcr.io", "quay.io"]
REGEOF
fi

# Docker CLI compatibility — symlink podman as docker
substep "Setting up Docker CLI compatibility (podman -> docker)..."
ln -sf "$(command -v podman)" /usr/local/bin/docker

# Create docker-compose compatibility wrapper
cat > /usr/local/bin/docker-compose << 'COMPEOF'
#!/bin/sh
exec podman compose "$@"
COMPEOF
chmod +x /usr/local/bin/docker-compose

# Set default network to "bridge" for Kurtosis/Docker compatibility
substep "Setting Podman default network to 'bridge'..."
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

# Set up Podman API service via OpenRC (Alpine uses OpenRC, not systemd)
substep "Setting up Podman API service (OpenRC)..."
cat > /etc/init.d/podman-api << 'INITEOF'
#!/sbin/openrc-run
description="Podman API Service"
command="/usr/bin/podman"
command_args="system service --time=0 unix:///run/podman/podman.sock"
command_background=true
pidfile="/run/podman-api.pid"
directory="/"

depend() {
    after localmount net
}

start_pre() {
    mkdir -p /run/podman
}

start_post() {
    # Wait for socket, then set permissions
    local i=0
    while [ $i -lt 10 ] && [ ! -S /run/podman/podman.sock ]; do
        sleep 0.5
        i=$((i+1))
    done
    [ -S /run/podman/podman.sock ] && chmod 0660 /run/podman/podman.sock
}
INITEOF
chmod +x /etc/init.d/podman-api

# Set up Docker API proxy via OpenRC (fixes Podman bridge network name filter bug)
substep "Setting up Docker API proxy (OpenRC)..."
cat > /etc/init.d/podman-docker-proxy << PROXYINIT
#!/sbin/openrc-run
description="Podman Docker API Proxy (Kurtosis bridge network workaround)"
command="/usr/bin/python3"
command_args="$SCRIPT_DIR/podman-docker-proxy.py"
command_background=true
pidfile="/run/podman-docker-proxy.pid"

depend() {
    need podman-api
}

start_pre() {
    export UPSTREAM_SOCK=/run/podman/podman.sock
}
PROXYINIT
chmod +x /etc/init.d/podman-docker-proxy

# Enable and start services
rc-update add podman-api default 2>/dev/null || true
rc-update add podman-docker-proxy default 2>/dev/null || true
# Remove old podman service if it exists
rc-update del podman default 2>/dev/null || true
rm -f /etc/init.d/podman 2>/dev/null || true

service podman-api restart 2>/dev/null || service podman-api start 2>/dev/null || true
sleep 2
service podman-docker-proxy restart 2>/dev/null || service podman-docker-proxy start 2>/dev/null || true
sleep 1

if curl -sf --unix-socket /var/run/docker.sock http://localhost/version &>/dev/null; then
    ok "Podman API + Docker proxy running (OpenRC)"
else
    warn "Docker API proxy not yet responding"
fi

# Ensure bridge network exists
substep "Ensuring 'bridge' network exists..."
if ! podman network exists bridge 2>/dev/null; then
    podman network create bridge >/dev/null 2>&1 || true
fi

# Configure rootless container support
REAL_USER="${SUDO_USER:-${DOAS_USER:-}}"
if [[ -n "$REAL_USER" ]] && [[ "$REAL_USER" != "root" ]]; then
    substep "Configuring rootless podman for $REAL_USER..."
    grep -q "^${REAL_USER}:" /etc/subuid 2>/dev/null || \
        echo "${REAL_USER}:100000:65536" >> /etc/subuid
    grep -q "^${REAL_USER}:" /etc/subgid 2>/dev/null || \
        echo "${REAL_USER}:100000:65536" >> /etc/subgid
    info "Configured rootless podman for $REAL_USER."
fi
ok "Podman container runtime ready"
step_done "Podman"

# ─── 5. Kurtosis CLI (direct binary) ─────────────────────────────────
step "Installing Kurtosis CLI"
if is_installed kurtosis; then
    info "Kurtosis already installed, skipping."
else
    substep "Downloading Kurtosis CLI binary..."
    KURTOSIS_TAR="kurtosis-cli_${GOARCH}.tar.gz"
    KURTOSIS_URL="https://github.com/kurtosis-tech/kurtosis-cli-release-artifacts/releases/latest/download/${KURTOSIS_TAR}"
    if curl -fsSL "$KURTOSIS_URL" -o "/tmp/${KURTOSIS_TAR}" 2>/dev/null; then
        substep "Extracting to /usr/local/bin..."
        tar -xzf "/tmp/${KURTOSIS_TAR}" -C /usr/local/bin/ 2>/dev/null || true
        chmod +x /usr/local/bin/kurtosis 2>/dev/null || true
        rm -f "/tmp/${KURTOSIS_TAR}"
        ok "Kurtosis installed"
    else
        substep "Trying fallback URL..."
        KURTOSIS_URL2="https://github.com/kurtosis-tech/kurtosis/releases/latest/download/kurtosis-cli_linux_${GOARCH}.tar.gz"
        if curl -fsSL "$KURTOSIS_URL2" -o "/tmp/kurtosis.tar.gz" 2>/dev/null; then
            tar -xzf "/tmp/kurtosis.tar.gz" -C /usr/local/bin/ 2>/dev/null || true
            chmod +x /usr/local/bin/kurtosis 2>/dev/null || true
            rm -f "/tmp/kurtosis.tar.gz"
            ok "Kurtosis installed (fallback URL)"
        else
            warn "Could not download Kurtosis binary. Install manually from https://docs.kurtosis.com/install/"
        fi
    fi
fi
step_done "Kurtosis"

# ─── 6. Foundry (forge, cast, anvil) ─────────────────────────────────
step "Installing Foundry toolchain"
if is_installed cast && is_installed forge; then
    info "Foundry already installed, skipping."
else
    export FOUNDRY_DIR="${HOME}/.foundry"
    substep "Running foundryup installer..."
    curl -fsSL https://foundry.paradigm.xyz | bash || true
    if [[ -f "${HOME}/.foundry/bin/foundryup" ]]; then
        substep "Installing Foundry nightly ($FOUNDRY_NIGHTLY)..."
        "${HOME}/.foundry/bin/foundryup" --version "$FOUNDRY_NIGHTLY" 2>/dev/null || \
        "${HOME}/.foundry/bin/foundryup" || true
    fi
    substep "Symlinking forge, cast, anvil, chisel to /usr/local/bin..."
    for bin in forge cast anvil chisel; do
        if [[ -f "${HOME}/.foundry/bin/$bin" ]]; then
            ln -sf "${HOME}/.foundry/bin/$bin" /usr/local/bin/
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
    substep "Building polycli from source (this may take a minute)..."
    CGO_ENABLED=1 /usr/local/go/bin/go build -o polycli main.go
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
    substep "Installing jq via apk..."
    apk add --no-cache jq
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
            kurtosis) ver="$(kurtosis version 2>/dev/null | head -1 | awk '{print $NF}')" ;;
            cast)     ver="$(cast --version 2>/dev/null | head -1 | awk '{print $2}')" ;;
            forge)    ver="$(forge --version 2>/dev/null | head -1 | awk '{print $2}')" ;;
            polycli)  ver="$(polycli version 2>/dev/null | head -1)" ;;
            yq)       ver="$(yq --version 2>/dev/null | awk '{print $NF}')" ;;
            jq)       ver="$(jq --version 2>/dev/null)" ;;
            python3)  ver="$(python3 --version 2>/dev/null | awk '{print $2}')" ;;
            protoc)   ver="$(protoc --version 2>/dev/null | awk '{print $2}')" ;;
            psql)     ver="$(psql --version 2>/dev/null | awk '{print $3}')" ;;
            docker)   ver="(-> podman)" ;;
            *)        ver="ok" ;;
        esac
        printf "  \e[1;32m%-6s\e[0m %-22s %s\n" "[OK]" "$name" "$ver"
    else
        printf "  \e[1;31m%-6s\e[0m %-22s\n" "[FAIL]" "$name"
        FAIL=1
    fi
}

verify "Podman"          podman
verify "docker (compat)" docker
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
verify "bash"            bash

# Check podman compose support
if podman compose version >/dev/null 2>&1; then
    printf "  \e[1;32m%-6s\e[0m %-22s %s\n" "[OK]" "Podman Compose" "built-in"
elif is_installed docker-compose; then
    printf "  \e[1;32m%-6s\e[0m %-22s %s\n" "[OK]" "Compose (wrapper)" "via docker-compose"
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
    echo "  Container runtime: Podman (Docker-compatible)"
    echo "==============================================\e[0m"
    echo ""
    # ─── Deploy BDK6 via Kurtosis ───────────────────────────────────────
    # Kurtosis 2.1.0 requires Docker CE for enclave creation.
    # Alpine provides Docker via apk (no external repo needed).
    info "Preparing Kurtosis deployment..."

    if ! command -v dockerd &>/dev/null; then
        substep "Installing Docker CE for Kurtosis deployment..."
        apk add --no-cache docker docker-cli-compose
        rc-update add docker default 2>/dev/null || true
        service docker start 2>/dev/null || true
        ok "Docker CE installed (Alpine apk)"
    else
        info "Docker CE already available."
    fi

    # Clean stale credential helpers
    DOCKER_CONFIG="${REAL_HOME:+$REAL_HOME/.docker/config.json}"
    DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker/config.json}"
    if [[ -f "$DOCKER_CONFIG" ]] && grep -q 'credsStore.*desktop' "$DOCKER_CONFIG" 2>/dev/null; then
        sed -i '/.credsStore/d; /.currentContext/d' "$DOCKER_CONFIG" 2>/dev/null || true
    fi

    # Clean previous Kurtosis state
    substep "Cleaning up previous Kurtosis state..."
    kurtosis engine stop 2>/dev/null || true
    docker rm -f $(docker ps -aq --filter label=com.kurtosistech.app-id=kurtosis) 2>/dev/null || true
    kurtosis clean --all 2>/dev/null || true

    # Start Kurtosis engine via Docker
    substep "Starting Kurtosis engine via Docker..."
    kurtosis engine start 2>&1 || true

    # Wait for engine to be ready
    substep "Waiting for Kurtosis engine..."
    GRPC_READY=false
    for i in $(seq 1 20); do
        if kurtosis engine status 2>&1 | grep -q "engine is running"; then
            GRPC_READY=true
            ok "Kurtosis engine ready"
            break
        fi
        echo -n "."
        sleep 3
    done
    echo ""

    if [[ "$GRPC_READY" == true ]]; then
        substep "Deploying BDK6 enclave (this takes 5-20 minutes)..."
        cd "$REPO_ROOT"
        kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always . 2>&1 || {
            warn "BDK6 deployment returned an error. Check output above."
            info "Retry: cd $REPO_ROOT"
            info "  kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always ."
        }
    else
        warn "Kurtosis engine did not become ready within 60s."
        info "Try manually:"
        info "  . /etc/profile.d/bdk6-path.sh"
        info "  kurtosis engine restart"
        info "  cd $REPO_ROOT && kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always ."
    fi
    echo ""
    info "Podman (Apache 2.0) is the primary container runtime."
    info "Docker is used only for Kurtosis enclave deployment."
    info "'podman' and 'docker' commands are both available."
else
    warn "Some dependencies failed to install. Review the output above."
    exit 1
fi

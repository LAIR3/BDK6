#!/usr/bin/env bash
#
# install-deps-ubuntu-docker.sh
# Install all BDK6 dependencies on Ubuntu/Mint with Docker CE
# Usage: sudo ./install-deps-ubuntu-docker.sh [--clean]
#
# Default: resumes from where it left off, reuses existing installs.
# --clean: wipe venv, re-download tools, fresh install from scratch.
#
# For the Podman (Apache 2.0) version, use install-deps-ubuntu.sh instead.
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

# ─── Detect architecture ─────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  GOARCH="amd64"; YQARCH="amd64"; DOCKER_ARCH="amd64" ;;
    aarch64) GOARCH="arm64"; YQARCH="arm64"; DOCKER_ARCH="arm64" ;;
    *) echo "FATAL: Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ─── Detect the real user (when run with sudo) ───────────────────────
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# ─── Detect Ubuntu codename (works on Mint/derivatives too) ──────────
# Mint sets UBUNTU_CODENAME=jammy; native Ubuntu uses VERSION_CODENAME
UBUNTU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-$(lsb_release -cs)}}")"

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

# apt-get update that tolerates third-party repo failures
apt_update() {
    if ! apt-get update -qq 2>&1; then
        warn "apt update had warnings from third-party repos (non-fatal, continuing...)"
    fi
}

# ─── Root check ──────────────────────────────────────────────────────
# ─── Root check — auto-elevate with sudo if needed ──────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Root privileges required. Requesting sudo..."
    exec sudo bash "$0" "$@"
fi

echo ""
echo "=============================================="
echo "  BDK6 Dependency Installer — Docker"
echo "=============================================="
echo "  Architecture : $ARCH ($GOARCH)"
echo "  User         : $REAL_USER"
echo "  Codename     : $UBUNTU_CODENAME"
echo "  Mode         : $( [[ "$CLEAN_INSTALL" == true ]] && echo "clean install" || echo "resume (use --clean for fresh)")"
echo "  Runtime      : Docker CE"
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

# ─── 4. Docker CE and Docker Compose plugin ──────────────────────────
step "Installing Docker CE and Docker Compose plugin"

if is_installed docker && docker compose version &>/dev/null; then
    info "Docker $(docker --version | awk '{print $3}' | tr -d ',') already installed, skipping."
else
    substep "Removing conflicting packages..."
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        apt-get remove -y "$pkg" 2>/dev/null || true
    done

    # Clean up ALL stale Docker repos (additional-repositories, docker.list, etc.)
    substep "Cleaning up stale Docker apt repositories..."
    rm -f /etc/apt/sources.list.d/docker.list
    # Remove Docker entries from additional-repositories.list (Mint/derivative leftover)
    if [[ -f /etc/apt/sources.list.d/additional-repositories.list ]]; then
        if grep -q 'download.docker.com' /etc/apt/sources.list.d/additional-repositories.list; then
            sed -i '/download\.docker\.com/d' /etc/apt/sources.list.d/additional-repositories.list
            # Remove file if now empty
            if [[ ! -s /etc/apt/sources.list.d/additional-repositories.list ]]; then
                rm -f /etc/apt/sources.list.d/additional-repositories.list
            fi
        fi
    fi

    substep "Adding Docker GPG key..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    chmod a+r /etc/apt/keyrings/docker.gpg

    substep "Adding Docker repository for ${DOCKER_ARCH} (${UBUNTU_CODENAME})..."
    echo "deb [arch=${DOCKER_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    substep "Installing Docker CE, CLI, containerd, buildx, compose..."
    apt_update
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    substep "Enabling and starting Docker service..."
    systemctl enable docker
    systemctl start docker
    ok "Docker installed"
fi

substep "Checking docker group membership for $REAL_USER..."
if ! id -nG "$REAL_USER" | grep -qw docker; then
    groupadd -f docker
    usermod -aG docker "$REAL_USER"
    info "Added $REAL_USER to docker group (re-login or 'newgrp docker' required)."
else
    info "$REAL_USER already in docker group."
fi
step_done "Docker"

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

verify "Docker"          docker
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

if docker compose version &>/dev/null; then
    printf "  \e[1;32m%-6s\e[0m %-22s %s\n" "[OK]" "Docker Compose" "$(docker compose version --short 2>/dev/null)"
else
    printf "  \e[1;31m%-6s\e[0m %-22s\n" "[FAIL]" "Docker Compose"
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
    echo "  Container runtime: Docker CE"
    echo "==============================================\e[0m"
    echo ""
    # ─── Launch Kurtosis as the real user with docker group ─────────────
    info "Starting Kurtosis as $REAL_USER..."
    substep "Starting Kurtosis engine..."
    su -s /bin/bash "$REAL_USER" -c "sg docker -c 'kurtosis engine restart'" 2>&1 || {
        warn "Kurtosis engine restart failed. Try: newgrp docker && kurtosis engine restart"
    }

    substep "Deploying BDK6 enclave..."
    su -s /bin/bash "$REAL_USER" -c "sg docker -c 'cd $REPO_ROOT && kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always .'" 2>&1 || {
        warn "BDK6 deployment failed. Check output above, then retry:"
        info "  kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always ."
    }
else
    warn "Some dependencies failed to install. Review the output above."
    exit 1
fi

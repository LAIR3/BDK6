#!/usr/bin/env bash
#
# install-deps-ubuntu.sh
# Install all BDK6 dependencies on Ubuntu 22.04+ / 24.04 LTS
# Usage: sudo ./install-deps-ubuntu.sh
#
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────
GO_VERSION="1.22.5"
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

# ─── Helpers ──────────────────────────────────────────────────────────
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; }
step()  { echo ""; echo "=====> $*"; }

trap 'error "Script failed at line $LINENO. Command: $BASH_COMMAND"' ERR

is_installed() {
    command -v "$1" &>/dev/null
}

# ─── Root check ──────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)."
    exit 1
fi

echo "=============================================="
echo "  BDK6 Dependency Installer — Ubuntu"
echo "=============================================="
echo "  Architecture: $ARCH ($GOARCH)"
echo "  User: $REAL_USER"
echo "=============================================="

# ─── System packages ─────────────────────────────────────────────────
step "Installing system packages"
apt-get update -qq
apt-get install -y --no-install-recommends \
    git curl wget bc make gcc g++ build-essential \
    ca-certificates gnupg lsb-release \
    protobuf-compiler \
    postgresql-client \
    python3 python3-pip python3-venv \
    software-properties-common \
    apt-transport-https \
    unzip

# ─── Go ──────────────────────────────────────────────────────────────
step "Installing Go $GO_VERSION"
if is_installed go && [[ "$(go version 2>/dev/null)" == *"go${GO_VERSION}"* ]]; then
    info "Go $GO_VERSION already installed, skipping."
else
    GO_TAR="go${GO_VERSION}.linux-${GOARCH}.tar.gz"
    curl -fsSL "https://go.dev/dl/${GO_TAR}" -o "/tmp/${GO_TAR}"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${GO_TAR}"
    rm -f "/tmp/${GO_TAR}"
    export PATH="/usr/local/go/bin:$PATH"
    info "Go $(go version) installed."
fi

# Persist PATH for the real user
PROFILE_LINE='export PATH="/usr/local/go/bin:$HOME/go/bin:$HOME/.foundry/bin:$PATH"'
for rc in "$REAL_HOME/.bashrc" "$REAL_HOME/.profile"; do
    if [[ -f "$rc" ]] && ! grep -qF '/usr/local/go/bin' "$rc"; then
        echo "$PROFILE_LINE" >> "$rc"
    fi
done

# ─── Node.js 20.x LTS ───────────────────────────────────────────────
step "Installing Node.js ${NODE_MAJOR}.x LTS"
if is_installed node && [[ "$(node --version 2>/dev/null)" == v${NODE_MAJOR}.* ]]; then
    info "Node.js $(node --version) already installed, skipping."
else
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg --yes
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq
    apt-get install -y nodejs
    info "Node.js $(node --version) installed."
fi

# ─── Docker CE + Compose plugin ─────────────────────────────────────
step "Installing Docker CE and Docker Compose plugin"
if is_installed docker && docker compose version &>/dev/null; then
    info "Docker $(docker --version | awk '{print $3}' | tr -d ',') already installed, skipping."
else
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        apt-get remove -y "$pkg" 2>/dev/null || true
    done

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=${DOCKER_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    info "Docker installed."
fi

# Add real user to docker group
if ! id -nG "$REAL_USER" | grep -qw docker; then
    groupadd -f docker
    usermod -aG docker "$REAL_USER"
    info "Added $REAL_USER to docker group (re-login or 'newgrp docker' required)."
else
    info "$REAL_USER already in docker group."
fi

# ─── Kurtosis CLI ───────────────────────────────────────────────────
step "Installing Kurtosis CLI"
if is_installed kurtosis; then
    info "Kurtosis already installed, skipping."
else
    echo "deb [trusted=yes] https://apt.fury.io/kurtosis-tech/ /" \
        > /etc/apt/sources.list.d/kurtosis.list
    apt-get update -qq
    apt-get install -y kurtosis-cli
    info "Kurtosis installed."
fi

# ─── Foundry (forge, cast, anvil) ───────────────────────────────────
step "Installing Foundry toolchain"
if is_installed cast && is_installed forge; then
    info "Foundry already installed, skipping."
else
    export FOUNDRY_DIR="$REAL_HOME/.foundry"
    su - "$REAL_USER" -c 'curl -fsSL https://foundry.paradigm.xyz | bash' || true
    su - "$REAL_USER" -c "$REAL_HOME/.foundry/bin/foundryup --version $FOUNDRY_NIGHTLY" || \
    su - "$REAL_USER" -c "$REAL_HOME/.foundry/bin/foundryup"
    for bin in forge cast anvil chisel; do
        if [[ -f "$REAL_HOME/.foundry/bin/$bin" ]]; then
            ln -sf "$REAL_HOME/.foundry/bin/$bin" /usr/local/bin/
        fi
    done
    info "Foundry installed."
fi

# ─── Polygon CLI (polycli) ──────────────────────────────────────────
step "Installing polycli $POLYCLI_VERSION"
if is_installed polycli; then
    info "polycli already installed, skipping."
else
    POLYCLI_BUILD_DIR="/tmp/polygon-cli-build"
    rm -rf "$POLYCLI_BUILD_DIR"
    git clone --depth 1 --branch "$POLYCLI_VERSION" \
        https://github.com/maticnetwork/polygon-cli.git "$POLYCLI_BUILD_DIR"
    pushd "$POLYCLI_BUILD_DIR" >/dev/null
    export PATH="/usr/local/go/bin:$PATH"
    CGO_ENABLED=0 go build -o polycli main.go
    mv polycli /usr/local/bin/polycli
    chmod +x /usr/local/bin/polycli
    popd >/dev/null
    rm -rf "$POLYCLI_BUILD_DIR"
    info "polycli installed."
fi

# ─── yq ──────────────────────────────────────────────────────────────
step "Installing yq"
if is_installed yq; then
    info "yq already installed, skipping."
else
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQARCH}" \
        -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
    info "yq installed."
fi

# pip-based yq (provides tomlq/xq, used in some Dockerfiles)
pip3 install --break-system-packages yq 2>/dev/null || pip3 install yq || true

# ─── jq ──────────────────────────────────────────────────────────────
step "Installing jq"
if is_installed jq; then
    info "jq already installed, skipping."
else
    apt-get install -y jq
    info "jq installed."
fi

# ─── Python dependencies (mkdocs) ───────────────────────────────────
step "Installing Python dependencies"
if [[ -f "$REPO_ROOT/scripts/requirements.txt" ]]; then
    pip3 install --break-system-packages -r "$REPO_ROOT/scripts/requirements.txt" \
        2>/dev/null || pip3 install -r "$REPO_ROOT/scripts/requirements.txt" || true
    info "Python requirements installed."
else
    warn "scripts/requirements.txt not found, skipping."
fi

# ─── Verification ────────────────────────────────────────────────────
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
        printf "  %-4s %-22s %s\n" "[OK]" "$name" "$ver"
    else
        printf "  %-4s %-22s\n" "[FAIL]" "$name"
        FAIL=1
    fi
}

verify "Go"              go
verify "Node.js"         node
verify "Docker"          docker
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
    printf "  %-4s %-22s %s\n" "[OK]" "Docker Compose" "$(docker compose version --short 2>/dev/null)"
else
    printf "  %-4s %-22s\n" "[FAIL]" "Docker Compose"
    FAIL=1
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
    info "All BDK6 dependencies installed successfully."
    echo ""
    info "Next steps:"
    info "  1. Log out and back in (or run 'newgrp docker') for docker group"
    info "  2. Run: kurtosis engine restart"
    info "  3. Run: kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always ."
else
    warn "Some dependencies failed to install. Review the output above."
    exit 1
fi

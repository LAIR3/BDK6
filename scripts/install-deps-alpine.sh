#!/usr/bin/env sh
#
# install-deps-alpine.sh
# Install all BDK6 dependencies on Alpine Linux 3.19+
# Usage: run as root (no sudo on Alpine by default)
#
set -eu

# ─── Constants ────────────────────────────────────────────────────────
GO_VERSION="1.24.4"
NODE_MAJOR=20
POLYCLI_VERSION="v0.1.108"
YQ_VERSION="v4.44.1"
FOUNDRY_NIGHTLY="nightly-f625d0fa7c51e65b4bf1e8f7931cd1c6e2e285e9"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Detect architecture ─────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  GOARCH="amd64"; YQARCH="amd64" ;;
    aarch64) GOARCH="arm64"; YQARCH="arm64" ;;
    *) echo "FATAL: Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ─── Helpers ──────────────────────────────────────────────────────────
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; }
step()  { echo ""; echo "=====> $*"; }

is_installed() {
    command -v "$1" >/dev/null 2>&1
}

# ─── Root check ──────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

echo "=============================================="
echo "  BDK6 Dependency Installer — Alpine"
echo "=============================================="
echo "  Architecture: $ARCH ($GOARCH)"
echo "=============================================="

# ─── System packages ─────────────────────────────────────────────────
step "Installing system packages"
apk update
apk add --no-cache \
    git curl wget bc make gcc g++ musl-dev libc-dev \
    ca-certificates \
    protobuf protobuf-dev \
    postgresql-client \
    python3 py3-pip \
    bash coreutils grep sed gawk \
    linux-headers \
    openrc \
    shadow \
    unzip tar \
    gcompat

# ─── Go ──────────────────────────────────────────────────────────────
step "Installing Go $GO_VERSION"
if is_installed go && go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
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

# Persist PATH globally
cat > /etc/profile.d/bdk6-path.sh << 'PATHEOF'
export PATH="/usr/local/go/bin:$HOME/go/bin:$HOME/.foundry/bin:$PATH"
PATHEOF
chmod +x /etc/profile.d/bdk6-path.sh
export PATH="/usr/local/go/bin:$HOME/go/bin:$HOME/.foundry/bin:$PATH"

# ─── Node.js 20.x LTS ───────────────────────────────────────────────
step "Installing Node.js ${NODE_MAJOR}.x LTS"
if is_installed node && node --version 2>/dev/null | grep -q "^v${NODE_MAJOR}\."; then
    info "Node.js $(node --version) already installed, skipping."
else
    apk add --no-cache nodejs npm
    INSTALLED_NODE="$(node --version 2>/dev/null || echo 'none')"
    if ! echo "$INSTALLED_NODE" | grep -q "^v${NODE_MAJOR}\."; then
        warn "apk provided Node $INSTALLED_NODE; fetching v${NODE_MAJOR}.x musl build..."
        # Get the latest v20.x version string
        NODE_FULL="$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/" \
            | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        if [ -n "$NODE_FULL" ]; then
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
    info "Node.js $(node --version) installed."
fi

# ─── Docker ──────────────────────────────────────────────────────────
step "Installing Docker"
if is_installed docker; then
    info "Docker already installed, skipping."
else
    apk add --no-cache docker docker-cli-compose
    info "Docker installed."
fi

# Enable and start Docker via openrc
rc-update add docker default 2>/dev/null || true
service docker start 2>/dev/null || true

# Add user to docker group if SUDO_USER or DOAS_USER is set
REAL_USER="${SUDO_USER:-${DOAS_USER:-}}"
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    addgroup "$REAL_USER" docker 2>/dev/null || true
    info "Added $REAL_USER to docker group."
fi

# ─── Kurtosis CLI (direct binary) ───────────────────────────────────
step "Installing Kurtosis CLI"
if is_installed kurtosis; then
    info "Kurtosis already installed, skipping."
else
    # Download from GitHub releases
    KURTOSIS_TAR="kurtosis-cli_${GOARCH}.tar.gz"
    KURTOSIS_URL="https://github.com/kurtosis-tech/kurtosis-cli-release-artifacts/releases/latest/download/${KURTOSIS_TAR}"
    if curl -fsSL "$KURTOSIS_URL" -o "/tmp/${KURTOSIS_TAR}" 2>/dev/null; then
        tar -xzf "/tmp/${KURTOSIS_TAR}" -C /usr/local/bin/ 2>/dev/null || true
        chmod +x /usr/local/bin/kurtosis 2>/dev/null || true
        rm -f "/tmp/${KURTOSIS_TAR}"
        info "Kurtosis installed."
    else
        # Fallback: try the alternative URL pattern
        KURTOSIS_URL2="https://github.com/kurtosis-tech/kurtosis/releases/latest/download/kurtosis-cli_linux_${GOARCH}.tar.gz"
        if curl -fsSL "$KURTOSIS_URL2" -o "/tmp/kurtosis.tar.gz" 2>/dev/null; then
            tar -xzf "/tmp/kurtosis.tar.gz" -C /usr/local/bin/ 2>/dev/null || true
            chmod +x /usr/local/bin/kurtosis 2>/dev/null || true
            rm -f "/tmp/kurtosis.tar.gz"
            info "Kurtosis installed (fallback URL)."
        else
            warn "Could not download Kurtosis binary. Install manually from https://docs.kurtosis.com/install/"
        fi
    fi
fi

# ─── Foundry (forge, cast, anvil) ───────────────────────────────────
step "Installing Foundry toolchain"
if is_installed cast && is_installed forge; then
    info "Foundry already installed, skipping."
else
    export FOUNDRY_DIR="${HOME}/.foundry"
    # foundryup requires bash (installed above)
    curl -fsSL https://foundry.paradigm.xyz | bash || true
    if [ -f "${HOME}/.foundry/bin/foundryup" ]; then
        "${HOME}/.foundry/bin/foundryup" --version "$FOUNDRY_NIGHTLY" 2>/dev/null || \
        "${HOME}/.foundry/bin/foundryup" || true
    fi
    for bin in forge cast anvil chisel; do
        if [ -f "${HOME}/.foundry/bin/$bin" ]; then
            ln -sf "${HOME}/.foundry/bin/$bin" /usr/local/bin/
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
    cd "$POLYCLI_BUILD_DIR"
    /usr/local/go/bin/go build -o polycli main.go
    mv polycli /usr/local/bin/polycli
    chmod +x /usr/local/bin/polycli
    rm -rf "$POLYCLI_BUILD_DIR"
    cd /
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

# pip-based yq (provides tomlq/xq)
pip3 install --break-system-packages yq 2>/dev/null || pip3 install yq 2>/dev/null || true

# ─── jq ──────────────────────────────────────────────────────────────
step "Installing jq"
if is_installed jq; then
    info "jq already installed, skipping."
else
    apk add --no-cache jq
    info "jq installed."
fi

# ─── Python dependencies (mkdocs) ───────────────────────────────────
step "Installing Python dependencies"
if [ -f "$REPO_ROOT/scripts/requirements.txt" ]; then
    pip3 install --break-system-packages -r "$REPO_ROOT/scripts/requirements.txt" \
        2>/dev/null || pip3 install -r "$REPO_ROOT/scripts/requirements.txt" 2>/dev/null || true
    info "Python requirements installed."
else
    warn "scripts/requirements.txt not found, skipping."
fi

# ─── Verification ────────────────────────────────────────────────────
step "Verifying installations"
echo ""
FAIL=0

verify() {
    name="$1"; cmd="$2"
    if is_installed "$cmd"; then
        printf "  %-4s %-22s\n" "[OK]" "$name"
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
verify "bash"            bash

if docker compose version >/dev/null 2>&1; then
    printf "  %-4s %-22s\n" "[OK]" "Docker Compose"
else
    printf "  %-4s %-22s\n" "[FAIL]" "Docker Compose"
    FAIL=1
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    info "All BDK6 dependencies installed successfully."
    echo ""
    info "Next steps:"
    info "  1. Source profile: . /etc/profile.d/bdk6-path.sh"
    info "  2. Run: kurtosis engine restart"
    info "  3. Run: kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always ."
else
    warn "Some dependencies failed to install. Review the output above."
    exit 1
fi

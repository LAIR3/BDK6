# Technical Reference

## Deployment architecture

BDK6 uses Kurtosis to orchestrate containers into an isolated enclave:

```
install-deps-ubuntu.sh
  |
  |- Steps 1-11: Install dependencies (Go, Node, Podman, Docker, Kurtosis, Foundry, polycli, yq, jq, Python)
  |- Deploy phase:
       |- Clean stale state (iptables, podman services, old enclaves)
       |- Install Docker CE (if needed) with MTU=1400
       |- kurtosis engine restart + 20s gRPC init countdown
       |- kurtosis run --enclave bdk-v6 --args-file params.yml .
            |
            |- main.star (entry point)
                |- ethereum.star         -> L1: Geth + Lighthouse
                |- deploy_zkevm_contracts_on_l1.star -> zkEVM contracts
                |- databases.star        -> PostgreSQL
                |- cdk_central_environment.star -> Sequencer + prover
                |- cdk_bridge_infra.star -> AggLayer + bridge
                |- cdk_erigon.star       -> cdk-erigon node
                |- observability.star    -> Prometheus + Grafana + Panoptichain
```

## Installer internals

### install-deps-ubuntu.sh

The main installer. Handles Ubuntu 22.04+, Linux Mint 21.x, and derivatives.

**Execution flow:**

1. Auto-elevates to root via `exec sudo bash "$0" "$@"`
2. Sets PATH early to find tools from previous runs under sudo
3. Parses `--clean` flag for fresh vs. resume behavior
4. Runs 11 dependency steps (each with `is_installed` guard)
5. Verification matrix (19 tools checked)
6. Deployment phase (Docker CE + Kurtosis + enclave)

**Resume mode** (default): skips installed tools, reuses `/opt/bdk6/venv`, skips Go if version matches. Only `apt update` and pip installs run unconditionally.

**Clean mode** (`--clean`): removes venv, removes `/usr/local/go`, forces fresh installs.

**Key workarounds in the installer:**

| Issue | Cause | Fix |
|---|---|---|
| Docker repo uses wrong codename on Mint | `VERSION_CODENAME=victoria` | Uses `UBUNTU_CODENAME=jammy` from `/etc/os-release` |
| `docker-credential-desktop` not found | Stale Docker Desktop config | Strips `credsStore` from `~/.docker/config.json` |
| Git clones fail inside enclaves | Docker default MTU=1500 | Sets `{"mtu": 1400}` in `/etc/docker/daemon.json` |
| Kurtosis 5s gRPC timeout | Engine needs ~15s to init | 20s countdown + polling loop |
| Stale enclaves block redeploy | Previous failed run left containers | `kurtosis clean --all` before engine start |

### install-deps-ubuntu-docker.sh

Docker-only variant. Same 11 dependency steps but uses Docker CE directly (no Podman). Simpler deployment path.

### install-deps-alpine.sh

Alpine Linux variant. Key differences:
- Uses `apk` instead of `apt`
- OpenRC instead of systemd (`/etc/init.d/podman-api`, `/etc/init.d/podman-docker-proxy`)
- `gcompat` for glibc compatibility (Foundry, Kurtosis binaries)
- Node.js musl builds from unofficial-builds.nodejs.org
- `docker` from `apk add docker` (Alpine native package)

### podman-docker-proxy.py

Python HTTP proxy that sits between `/var/run/docker.sock` and the real Podman socket. Fixes a Podman 4.x Docker compat API bug where `GET /networks?filters={"name":{"bridge":true}}` returns `[]`.

The proxy intercepts this specific request, calls `GET /networks/bridge` directly, and returns the result as a list. All other requests pass through transparently.

Runs as a systemd service (`podman-docker-proxy.service`) or OpenRC service on Alpine.

### tool_check.sh

Pre-flight validation. Checks:
- Kurtosis >= 1.0
- Podman >= 4.0 or Docker >= 24.7
- jq, yq (>= 3.2), cast, polycli (optional)

## Container runtime architecture

### Dual-runtime model

| Runtime | Purpose | Socket |
|---|---|---|
| Podman 4.6.2 (Kubic) | Primary runtime, Apache 2.0 | `/run/podman/podman.sock` |
| Docker CE 29.x | Kurtosis enclave orchestration | `/var/run/docker.sock` |

Podman is installed first as the system container runtime. Docker CE is added during the deployment phase specifically for Kurtosis, which requires Docker-native network APIs.

### Podman systemd services (Ubuntu)

| Service | Description |
|---|---|
| `podman-api.service` | Runs `podman system service` on `/run/podman/podman.sock` |
| `podman-docker-proxy.service` | Python proxy on `/var/run/docker.sock` (bridge network fix) |

Both are disabled when Docker CE is active for Kurtosis deployment to avoid socket conflicts.

### Podman OpenRC services (Alpine)

| Service | Description |
|---|---|
| `/etc/init.d/podman-api` | Podman API service |
| `/etc/init.d/podman-docker-proxy` | Docker API proxy |

### Podman configuration

**`/etc/containers/containers.conf`:**
```toml
[network]
default_network = "bridge"
```

**`/etc/containers/storage.conf`** (Alpine):
```toml
[storage]
driver = "overlay"
[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
```

**`/etc/containers/registries.conf`** (Alpine):
```toml
unqualified-search-registries = ["docker.io", "ghcr.io", "quay.io"]
```

## Network configuration

### Docker MTU

`/etc/docker/daemon.json`:
```json
{"mtu": 1400}
```

Required for git clones inside Kurtosis enclaves. The default 1500 MTU causes fragmentation when Docker bridge + host interface MTUs don't align.

### Kurtosis enclave networking

Kurtosis creates a dedicated Docker bridge network per enclave. All services within an enclave communicate over this network. The Kurtosis engine connects to services via the Docker API.

### Port mappings

| Port | Service | Protocol |
|---|---|---|
| 9710 | Kurtosis engine gRPC | gRPC/HTTP2 |
| 9711 | Kurtosis engine gRPC (connect) | gRPC/HTTP2 |
| 9730 | Kurtosis reverse proxy | HTTP |
| 9779 | Kurtosis engine REST API | HTTP |
| 8081 | Kurtosis enclave manager | HTTP |
| 8123 | zkEVM RPC (HTTP) | JSON-RPC |
| 8133 | zkEVM RPC (WebSocket) | WS |
| 4444 | AggLayer | HTTP |
| 8484 | Data Availability Committee | HTTP |

## Starlark configuration

### main.star deployment flags

| Flag | Default | Controls |
|---|---|---|
| `deploy_l1` | `True` | Local L1 (Geth + Lighthouse) |
| `deploy_zkevm_contracts_on_l1` | `True` | zkEVM smart contracts |
| `deploy_databases` | `True` | PostgreSQL instances |
| `deploy_cdk_central_environment` | `True` | Sequencer + prover |
| `deploy_cdk_bridge_infra` | `True` | AggLayer + bridge service |
| `deploy_zkevm_permissionless_node` | `False` | Permissionless L2 node |
| `deploy_cdk_erigon_node` | `True` | cdk-erigon node |
| `deploy_observability` | `True` | Prometheus + Grafana |
| `deploy_l2_blockscout` | `False` | Block explorer |
| `deploy_blutgang` | `False` | RPC load balancer |
| `apply_workload` | `False` | Automated load testing |

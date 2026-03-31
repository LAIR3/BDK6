# LAIR3-BDK6 Layer 3 Blockchain Deployment Kit v6

A [Kurtosis](https://github.com/kurtosis-tech/kurtosis) package that deploys a private, portable, and modular Blockchain Deployment Kit as devnet.

LAIR3-BDK6 is the evolution of [BDK5](https://github.com/lair3/bdk5), upgraded with modern Polygon CDK components, AggLayer v0.3 integration with pessimistic proof and unified bridge support, and current infrastructure versions.

## Architecture

BDK6 deploys a complete Polygon CDK stack via Kurtosis Starlark orchestration:

- **L1**: Local Ethereum chain (Geth v1.17.1 + Lighthouse v8.1.3)
- **Contracts**: zkEVM contracts deployed on L1 (Fork ID 12 / Banana)
- **Sequencer**: cdk-erigon v2.64.0 (default) or zkevm-node v0.7.3
- **Prover**: zkevm-prover v8.0.0-RC16 (Fork 12)
- **AggLayer**: agglayer-rs v0.4.4 with pessimistic proof and unified bridge
- **Bridge**: zkevm-bridge-service v0.6.1 with unified bridge support
- **Data Availability**: Rollup (on-chain) or CDK-Validium (off-chain via DAC)
- **Databases**: PostgreSQL 17.4
- **Observability**: Prometheus, Grafana, Panoptichain
- **Block Explorer**: Blockscout (optional)
- **Load Balancer**: Blutgang (optional)

![Architecture Diagram](./docs/img/starlark.png)

## Component Versions

| Component | Version |
|---|---|
| cdk-erigon | v2.64.0-RC10 |
| zkevm-prover | v8.0.0-RC16-fork.12 |
| zkevm-node | v0.7.3 |
| cdk (node) | v0.5.4 |
| agglayer-rs | v0.4.4 |
| zkevm-bridge-service | v0.6.1 |
| zkevm-sequence-sender | v0.2.4 |
| cdk-data-availability | v0.0.13 |
| zkevm-pool-manager | v0.1.2 |
| polycli | v0.1.108 |
| Geth | v1.17.1 |
| Lighthouse | v8.1.3 |
| PostgreSQL | 17.4 |

## Prerequisites

- Linux-based OS: Ubuntu 22.04+, Linux Mint 21.x, or Alpine 3.19+
- At least 8 GB RAM, 2-core CPU, AMD64 or ARM64
- `sudo` access

## Install (One Command)

BDK6 provides automated installers that handle all dependencies, container runtime setup, Kurtosis engine start, and enclave deployment in a single run.

### Podman (default, Apache 2.0 licensed)

```bash
git clone https://github.com/lair3/bdk6.git && cd bdk6
./scripts/install-deps-ubuntu.sh
```

### Docker CE (compatibility)

```bash
./scripts/install-deps-ubuntu-docker.sh
```

### Alpine Linux

```bash
./scripts/install-deps-alpine.sh
```

The installer:

1. Auto-elevates with `sudo` (prompts for password if needed)
2. Installs all 11 dependency groups (system packages, Go 1.24.4, Node.js 20.x, container runtime, Kurtosis, Foundry, polycli, yq, jq, Python deps)
3. **Resumes** from where it left off — skips already-installed tools, reuses the Python venv
4. Starts Kurtosis engine and deploys the BDK6 enclave
5. Use `--clean` for a fresh install from scratch

### What gets installed

| Tool | Version | Purpose |
|---|---|---|
| Podman | 4.6.2+ (Kubic) | Container runtime (Apache 2.0) |
| Go | 1.24.4 | Build polycli, CDK tools |
| Node.js | 20.x LTS | JavaScript toolchain |
| Kurtosis | 2.1.0 | Enclave orchestration |
| Foundry | nightly | forge, cast, anvil, chisel |
| polycli | v0.1.108 | Polygon CLI (load testing, wallet) |
| yq / jq | latest | YAML/JSON processing |
| Python 3 | system | mkdocs, podman-compose |
| PostgreSQL client | 14.x | Database access |
| protobuf-compiler | 3.12+ | Protocol buffer compilation |

### Why Podman + Alpine

BDK6 targets **Podman on Alpine Linux** as the reference deployment platform. This combination is purpose-built for blockchain infrastructure:

**Podman (Apache 2.0)**

- **License purity** — Apache 2.0 throughout the entire stack. No proprietary runtime licensing (Docker CE is Apache 2.0 but Docker Desktop is proprietary; the distinction creates compliance risk for commercial node operators). Podman eliminates this ambiguity entirely.
- **Daemonless** — no persistent root daemon. Each container is a child process of the caller, not a shared daemon. This means a compromised container cannot leverage a daemon socket to escalate across the host — critical when running validator nodes that hold signing keys.
- **Rootless by default** — containers run in user namespaces without real root. Validator and sequencer processes never need root, even for networking. Reduces blast radius of any exploit to the unprivileged user.
- **OCI-compliant** — same images, same registries, same Dockerfiles. `podman-docker` provides a drop-in `docker` CLI alias. Existing Docker workflows work unchanged.

**Alpine Linux**

- **Minimal attack surface** — ~5 MB base image, ~130 packages in a typical install vs. ~700+ on Ubuntu. Fewer packages means fewer CVEs, fewer update cycles, smaller window of vulnerability. For validator nodes exposed to the internet, every unnecessary binary is a liability.
- **musl libc** — smaller, auditable C library (~120 KLOC vs. glibc's ~1.8 MLOC). Static linking is the default, producing self-contained binaries with no shared library dependency chain to attack.
- **Read-only root capable** — Alpine's simplicity enables immutable root filesystem deployments. Validator nodes can boot from a signed, read-only image with only `/var` writable, preventing persistent rootkits.
- **Fast boot, small footprint** — Alpine VMs boot in seconds and run blockchain nodes in <512 MB RAM. This enables rapid horizontal scaling of L2/L3 nodes and cost-effective geographic distribution for decentralization.
- **Native Podman support** — `apk add podman` installs from official repos with no PPAs, no Kubic workarounds. The Alpine + Podman + musl stack is fully self-contained under permissive licenses.
- **Reproducible builds** — Alpine's `abuild` system and pinned package versions enable deterministic node images. Two operators building from the same Dockerfile get byte-identical container layers, enabling trustless verification of node software.

**Together**: an Alpine node running BDK6 via Podman has a fully auditable, license-clean, minimal-privilege stack from kernel to application. No proprietary dependencies, no root daemons, no unnecessary attack surface — the properties blockchain infrastructure demands.

### Runtime architecture

BDK6 uses a dual-runtime approach:

| Runtime | Role | License |
|---|---|---|
| **Podman** | Primary container runtime, systemd services, CLI | Apache 2.0 |
| **Docker CE** | Kurtosis enclave orchestration (devnet setup) | Apache 2.0 |

Kurtosis 2.1.0 requires Docker CE for enclave creation (its Docker API usage exceeds Podman's compat layer). The installer handles both automatically — Podman is installed first as the system runtime, then Docker CE is added specifically for Kurtosis deployment. Both coexist without conflict.

For production node operation after deployment, Podman is the runtime. Docker is only needed during the initial devnet setup phase.

A standalone Docker CE installer (`install-deps-ubuntu-docker.sh`) is also available for Docker-only environments.

### Verify prerequisites

```bash
bash scripts/tool_check.sh
```

## Quick Start

The installer deploys the BDK6 enclave automatically. After `./scripts/install-deps-ubuntu.sh` completes, the stack is running.

To redeploy or deploy with different parameters:

```bash
# Clean and redeploy (default: cdk-validium mode, erigon sequencer)
kurtosis clean --all
kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always .

# Deploy in rollup mode
kurtosis run --enclave bdk-v6 --args-file paramsrollup.yml --image-download always .
```

Deployment takes 5-20 minutes depending on hardware.

## Inspect the Deployment

```bash
# List enclaves
kurtosis enclave ls

# Inspect enclave services
kurtosis enclave inspect bdk-v6

# Check service logs
kurtosis service logs bdk-v6 zkevm-agglayer-001
kurtosis service logs bdk-v6 zkevm-bridge-ui-001

# Open service shell
kurtosis service shell bdk-v6 zkevm-bridge-ui-001
```

## Interact with the Chain

```bash
# Get the L2 RPC URL
export ETH_RPC_URL="$(kurtosis port print bdk-v6 cdk-erigon-node-001 http-rpc)"

# Check block number
cast block-number

# Check pre-funded admin balance
cast balance --ether 0xE34aaF64b29273B7D567FCFc40544c014EEe9970

# Send a transaction
export PK="0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625"
cast send --legacy --private-key "$PK" --value 0.01ether 0x0000000000000000000000000000000000000000
```

## Load Testing

```bash
polycli loadtest --rpc-url "$ETH_RPC_URL" --legacy --private-key "$PK" --verbosity 700 --requests 500 --rate-limit 5 --mode t
polycli loadtest --rpc-url "$ETH_RPC_URL" --legacy --private-key "$PK" --verbosity 700 --requests 500 --rate-limit 10 --mode 2
polycli loadtest --rpc-url "$ETH_RPC_URL" --legacy --private-key "$PK" --verbosity 700 --requests 500 --rate-limit 3 --mode uniswapv3
```

## AggLayer v0.3 Integration

BDK6 includes modern AggLayer integration with:

- **Pessimistic Proof**: Cryptographically ensures no connected chain can withdraw more than it deposited. Uses SP1 zkVM + Plonky3 for proof generation (mock proofs in devnet mode).
- **Unified Bridge**: Enables native asset fungibility across connected chains without wrapping/unwrapping. Supports atomic cross-chain transactions.
- **Settlement**: Both rollup and validium modes settle via AggLayer (no longer validium-only).

AggLayer service runs on port 4444. View logs:
```bash
kurtosis service logs bdk-v6 zkevm-agglayer-001
```

## Permissionless Node

```bash
yq -Y --in-place 'with_entries(if .key == "deploy_zkevm_permissionless_node" then .value = true elif .value | type == "boolean" then .value = false else . end)' params.yml
kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always .
```

## Observability

Enable in params.yml: `deploy_observability: true`

- **Prometheus**: Metrics collection from all services
- **Grafana**: Pre-configured dashboards (default port 3000)
- **Panoptichain**: On-chain metrics monitoring

## PostgreSQL

```bash
# Set master password
export POSTGRES_MASTER_PASSWORD="your_secure_password"

# Connect to database
psql -U master_user -h 127.0.0.1 -p 5432 -d master
```

## Cleanup

```bash
# Clean Kurtosis environments
kurtosis clean --all

# Full container cleanup (works with both Podman and Docker)
podman stop -a 2>/dev/null; docker stop $(docker ps -aq) 2>/dev/null
podman rm -a 2>/dev/null; docker rm $(docker ps -aq) 2>/dev/null
podman system prune -a --volumes 2>/dev/null || docker system prune -a --volumes
```

## Troubleshooting

### Container runtime services (Podman)

```bash
# Check service status
systemctl status podman.socket podman-docker-proxy

# Restart services
sudo systemctl restart podman.socket podman-docker-proxy

# View proxy logs
journalctl -u podman-docker-proxy -f

# Re-run installer (resumes, won't reinstall existing tools)
./scripts/install-deps-ubuntu.sh
```

### Kurtosis engine won't start

```bash
# Full reset
kurtosis clean --all
podman rm -f -a
kurtosis engine restart
```

### Kurtosis logs directory error
```bash
sudo mkdir -p /var/log/kurtosis/
sudo chown -R $USER:$USER /var/log/kurtosis
sudo chmod -R 755 /var/log/kurtosis
kurtosis engine restart
```

### Switch between Podman and Docker

The installers are separate scripts and don't conflict. To switch:

```bash
# Stop current runtime
kurtosis clean --all

# Switch to Docker
./scripts/install-deps-ubuntu-docker.sh

# Or switch back to Podman
./scripts/install-deps-ubuntu.sh
```

## Reference Links

- [Kurtosis Documentation](https://docs.kurtosis.com/)
- [Polygon CDK](https://docs.polygon.technology/cdk/)
- [AggLayer Documentation](https://docs.agglayer.dev/)
- [AggLayer Pessimistic Proof](https://docs.agglayer.dev/agglayer/core-concepts/pessimistic-proof/)
- [Lighthouse](https://lighthouse-book.sigmaprime.io/)
- [Foundry](https://book.getfoundry.sh/)
- [Polygon CLI](https://github.com/maticnetwork/polygon-cli)

## License

Dual licensed under [Apache 2.0](LICENSE-APACHE) and [MIT](LICENSE-MIT).

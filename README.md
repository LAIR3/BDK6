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

Install the following requirements (Ubuntu 22.04+ / 24.04 LTS):

### Go install
```bash
wget https://go.dev/dl/go1.22.5.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -xvf go1.22.5.linux-amd64.tar.gz -C /usr/local/
echo 'export PATH="$PATH:/usr/local/go/bin"' >> ~/.bashrc
source ~/.bashrc
go version
```

### Node.js install
```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install nodejs -y
node -v
```

### Docker install
```bash
# https://docs.docker.com/engine/install/ubuntu/
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove $pkg; done
sudo groupadd docker
sudo usermod -aG docker $USER
newgrp docker
docker ps
```

### Kurtosis install
```bash
echo "deb [trusted=yes] https://apt.fury.io/kurtosis-tech/ /" | sudo tee /etc/apt/sources.list.d/kurtosis.list
sudo apt update
sudo apt install kurtosis-cli
kurtosis engine restart
```

### Polygon CLI install
```bash
snap install yq
sudo apt install bc protoc
git clone https://github.com/maticnetwork/polygon-cli.git
cd polygon-cli
make install
```

### Foundry install
```bash
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc
foundryup
```

### Verify requirements
```bash
sh scripts/tool_check.sh
```

## Quick Start

```bash
# Clean previous environments
kurtosis clean --all

# Deploy with default params (cdk-validium mode, erigon sequencer)
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

# Full Docker cleanup
docker stop $(docker ps -aq)
docker rm $(docker ps -aq)
docker system prune -a --volumes
```

## Troubleshooting

### Kurtosis logs directory error
```bash
sudo mkdir -p /var/log/kurtosis/
sudo chown -R $USER:docker /var/log/kurtosis
sudo chmod -R 755 /var/log/kurtosis
kurtosis engine restart
sudo systemctl restart docker
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

# Usage Guide

## One-command install and deploy

```bash
git clone https://github.com/lair3/bdk6.git
cd bdk6
./scripts/install-deps-ubuntu.sh
```

This single command:

1. Prompts for sudo password (auto-elevates)
2. Installs 11 dependency groups (Go, Node, Podman, Kurtosis, Foundry, polycli, yq, jq, Python, protobuf, PostgreSQL client)
3. Configures Podman as the primary container runtime (Apache 2.0)
4. Installs Docker CE for Kurtosis enclave orchestration
5. Configures Docker MTU, credentials, log directory
6. Starts the Kurtosis engine with a 20-second gRPC initialization countdown
7. Deploys the BDK6 enclave (5-20 minutes)

### Installer options

| Flag | Behavior |
|---|---|
| *(none)* | Resume mode -- skips installed tools, reuses venv |
| `--clean` | Fresh install -- wipes venv, re-downloads Go |

### Platform-specific installers

| Platform | Command |
|---|---|
| Ubuntu 22.04+ / Linux Mint 21.x | `./scripts/install-deps-ubuntu.sh` |
| Ubuntu/Mint (Docker only) | `./scripts/install-deps-ubuntu-docker.sh` |
| Alpine Linux 3.19+ | `./scripts/install-deps-alpine.sh` |

## Verify prerequisites

```bash
bash scripts/tool_check.sh
```

## Manual deployment

If you already have all dependencies installed:

```bash
kurtosis clean --all
kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always .
```

### Rollup mode

```bash
kurtosis run --enclave bdk-v6 --args-file paramsrollup.yml --image-download always .
```

## Inspect the deployment

```bash
# List enclaves
kurtosis enclave ls

# Inspect services
kurtosis enclave inspect bdk-v6

# View service logs
kurtosis service logs bdk-v6 zkevm-agglayer-001
kurtosis service logs bdk-v6 cdk-erigon-node-001

# Open a shell inside a service
kurtosis service shell bdk-v6 zkevm-node-sequencer-001
```

## Interact with the chain

```bash
# Get L2 RPC URL
export ETH_RPC_URL="$(kurtosis port print bdk-v6 cdk-erigon-node-001 http-rpc)"

# Check block number
cast block-number

# Check pre-funded admin balance (100,000 ETH in devnet)
cast balance --ether 0xE34aaF64b29273B7D567FCFc40544c014EEe9970

# Send a transaction
export PK="0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625"
cast send --legacy --private-key "$PK" --value 0.01ether 0x0000000000000000000000000000000000000000

# Check batch progression
cast rpc zkevm_batchNumber
cast rpc zkevm_virtualBatchNumber
cast rpc zkevm_verifiedBatchNumber
```

## Load testing

```bash
polycli loadtest --rpc-url "$ETH_RPC_URL" --legacy --private-key "$PK" --verbosity 700 --requests 500 --rate-limit 5 --mode t
polycli loadtest --rpc-url "$ETH_RPC_URL" --legacy --private-key "$PK" --verbosity 700 --requests 500 --rate-limit 10 --mode 2
polycli loadtest --rpc-url "$ETH_RPC_URL" --legacy --private-key "$PK" --verbosity 700 --requests 500 --rate-limit 3 --mode uniswapv3
```

## Observability

Enable in `params.yml`: `deploy_observability: true` (default).

| Service | Purpose | Access |
|---|---|---|
| Prometheus | Metrics collection | `kurtosis port print bdk-v6 prometheus-001 http` |
| Grafana | Dashboards | `kurtosis port print bdk-v6 grafana-001 dashboards` |
| Panoptichain | On-chain metrics | `kurtosis port print bdk-v6 panoptichain-001 prometheus` |

## Permissionless node

```bash
yq -Y --in-place 'with_entries(if .key == "deploy_zkevm_permissionless_node" then .value = true elif .value | type == "boolean" then .value = false else . end)' params.yml
kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always .
```

## Configuration reference

All parameters are in `params.yml`. Key settings:

| Parameter | Default | Description |
|---|---|---|
| `deploy_l1` | `true` | Deploy local L1 chain |
| `deploy_cdk_bridge_infra` | `true` | Deploy AggLayer + bridge |
| `deploy_observability` | `true` | Deploy Prometheus/Grafana/Panoptichain |
| `deploy_cdk_erigon_node` | `true` | Deploy cdk-erigon sequencer |
| `data_availability_mode` | `cdk-validium` | `cdk-validium` or `rollup` |
| `zkevm_rollup_chain_id` | `10101` | L2 chain ID |
| `zkevm_rollup_fork_id` | `12` | Prover fork version |

## Cleanup

```bash
# Remove BDK6 enclave
kurtosis clean --all

# Full container cleanup
docker system prune -a --volumes
```

## Troubleshooting

### Container runtime services

```bash
# Check Docker status
systemctl status docker

# View Kurtosis engine logs
kurtosis engine logs

# Restart everything
kurtosis clean --all
kurtosis engine restart
sleep 20
kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always .
```

### Re-run installer (safe -- resumes)

```bash
./scripts/install-deps-ubuntu.sh
```

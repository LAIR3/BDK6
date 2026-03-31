# Introduction to BDK6

## What is BDK6?

LAIR3-BDK6 (Blockchain Deployment Kit v6) is a one-command installer and orchestrator for deploying a complete Polygon CDK blockchain stack as a local devnet. It provisions an L1 chain, deploys smart contracts, starts a sequencer, prover, bridge, and aggregation layer -- everything needed to run a private Polygon zkEVM network.

BDK6 is the evolution of [BDK5](https://github.com/lair3/bdk5), rebuilt with modern Polygon CDK components and AggLayer v0.3 integration.

## What does it deploy?

A single `./scripts/install-deps-ubuntu.sh` command installs all dependencies and deploys:

```
L1 (Ethereum)
  Geth v1.17.1 + Lighthouse v8.1.3
  Local beacon chain with 1-second slots

L2 (Polygon CDK)
  cdk-erigon v2.64.0 sequencer
  zkevm-prover v8.0.0-RC16 (Fork 12 / Banana)
  zkevm-bridge-service v0.6.1
  zkevm-sequence-sender v0.2.4

AggLayer v0.3
  agglayer-rs v0.4.4
  Pessimistic proof (mock in devnet)
  Unified bridge
  Certificate settlement

Infrastructure
  PostgreSQL 17.4
  Prometheus + Grafana + Panoptichain (observability)
  Traefik reverse proxy
  Blockscout block explorer (optional)
```

All services run as containers orchestrated by [Kurtosis](https://github.com/kurtosis-tech/kurtosis), a portable enclave manager.

## Who is it for?

- **CDK developers** building rollups or validium chains on Polygon
- **Node operators** evaluating the CDK stack before production deployment
- **Blockchain researchers** studying L2 architecture, bridging, and data availability
- **Protocol engineers** working on AggLayer, pessimistic proof, or unified bridge

## Data availability modes

BDK6 supports two modes, selectable in `params.yml`:

| Mode | Where tx data lives | Config value |
|---|---|---|
| **CDK-Validium** (default) | Off-chain via Data Availability Committee | `cdk-validium` |
| **Rollup** | On-chain on L1 | `rollup` |

## Key concepts

**Kurtosis enclave** -- An isolated environment containing all the containers for one deployment. Clean with `kurtosis clean --all`, inspect with `kurtosis enclave inspect bdk-v6`.

**Starlark** -- The configuration language Kurtosis uses. BDK6's `main.star` orchestrates the deployment sequence. Parameters come from `params.yml`.

**AggLayer** -- Polygon's aggregation layer that enables cross-chain interoperability. BDK6 deploys agglayer-rs with pessimistic proof (ensures no chain can withdraw more than it deposited) and unified bridge (native asset fungibility across chains).

**Fork ID** -- Identifies the prover/executor version. BDK6 uses Fork ID 12 (Banana), the current production fork.

## Next steps

- [USAGE.md](USAGE.md) -- Install and deploy
- [TECHNICAL.md](TECHNICAL.md) -- Architecture deep dive
- [EXPLANATION.md](EXPLANATION.md) -- Design rationale

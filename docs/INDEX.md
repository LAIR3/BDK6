# BDK6 Documentation Index

LAIR3-BDK6 Blockchain Deployment Kit v6 -- Polygon CDK with AggLayer v0.3

## Getting Started

| Document | Description |
|---|---|
| [INTRO.md](INTRO.md) | What BDK6 is, what it deploys, who it's for |
| [USAGE.md](USAGE.md) | Installation, deployment, daily operations |
| [TECHNICAL.md](TECHNICAL.md) | Architecture, installer internals, Podman/Docker runtime |
| [EXPLANATION.md](EXPLANATION.md) | Design decisions, why Podman + Alpine, AggLayer rationale |

## Quickstart Guides

| Guide | Description |
|---|---|
| [quickstart/deploy-stack.md](quickstart/deploy-stack.md) | One-command install and deploy |
| [quickstart/breakdown-deployment.md](quickstart/breakdown-deployment.md) | Step-by-step deployment walkthrough |
| [quickstart/observability.md](quickstart/observability.md) | Prometheus, Grafana, Panoptichain setup |
| [quickstart/set-up-permissionless-node.md](quickstart/set-up-permissionless-node.md) | Run a permissionless L2 node |

## Configuration

| Guide | Description |
|---|---|
| [da-mode.md](da-mode.md) | Data availability modes (rollup vs. CDK-validium) |
| [cdk-policies.md](cdk-policies.md) | CDK policy system overview |
| [manage-policies.md](manage-policies.md) | Configure allowlists and access control |
| [integrate-da.md](integrate-da.md) | Integrate external data availability layers |
| [use-native-token/use-native-token.md](use-native-token/use-native-token.md) | Deploy with a custom native gas token |

## Operations

| Guide | Description |
|---|---|
| [migrate/upgrade.md](migrate/upgrade.md) | Upgrade between BDK versions |
| [migrate/forkid-7-to-9.md](migrate/forkid-7-to-9.md) | Migrate from Fork ID 7 to 9 |
| [trigger-a-reorg/trigger-a-reorg.md](trigger-a-reorg/trigger-a-reorg.md) | Trigger and observe a chain reorganization |
| [test-stack.md](test-stack.md) | Testing the deployed stack |

## Installer Scripts

| Script | Platform | Runtime |
|---|---|---|
| `scripts/install-deps-ubuntu.sh` | Ubuntu/Mint | Podman + Docker CE |
| `scripts/install-deps-ubuntu-docker.sh` | Ubuntu/Mint | Docker CE only |
| `scripts/install-deps-alpine.sh` | Alpine Linux | Podman + Docker (OpenRC) |
| `scripts/tool_check.sh` | All | Verify prerequisites |
| `scripts/podman-docker-proxy.py` | Ubuntu/Mint | Podman Docker API proxy |

## Reference

- [README.md](../README.md) -- Project overview, component versions, quick start
- [params.yml](../params.yml) -- Deployment parameters
- [kurtosis.yml](../kurtosis.yml) -- Kurtosis package metadata
- [main.star](../main.star) -- Starlark orchestration entry point

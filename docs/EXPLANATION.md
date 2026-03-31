# Design Decisions

## Why Podman + Alpine

BDK6 targets Podman on Alpine Linux as the reference platform for blockchain node deployment. This is a deliberate architectural choice.

### License purity

Blockchain infrastructure demands license clarity. Every dependency in the node stack is subject to audit by legal teams, DAOs, and regulatory bodies.

- **Podman**: Apache 2.0. No ambiguity, no dual-licensing, no "community vs. enterprise" distinction.
- **Docker CE**: Apache 2.0 for the engine, but Docker Desktop (required on macOS/Windows) is proprietary with per-seat licensing. This creates a compliance surface that Podman eliminates entirely.
- **Alpine**: MIT-like licensing throughout the base system.

For a validator node holding staking keys or a sequencer processing user transactions, every proprietary dependency is a vector for license disputes, forced upgrades, or vendor lock-in. BDK6's stack is fully auditable from kernel to application.

### Minimal attack surface (Alpine)

A blockchain node is a high-value target. The attack surface is the sum of all code running on the host.

| Metric | Alpine | Ubuntu |
|---|---|---|
| Base image size | ~5 MB | ~75 MB |
| Installed packages | ~130 | ~700+ |
| C library | musl (~120 KLOC) | glibc (~1.8 MLOC) |
| Init system | OpenRC (~15 KLOC) | systemd (~1.4 MLOC) |

Every unnecessary binary is a potential CVE. Alpine's minimalism means:
- Fewer packages to patch
- Smaller update windows
- Less code to audit
- Faster security response

For a validator node exposed to the internet on port 8545, the difference between 130 and 700 packages is the difference between manageable and unmanageable attack surface.

### musl libc

Alpine uses musl instead of glibc. musl is:
- **Auditable**: 120 KLOC vs. 1.8 MLOC. A security team can read the entire C library.
- **Static-linking friendly**: Produces self-contained binaries with no shared library dependency chain.
- **Smaller**: Fewer code paths means fewer bugs.

Go binaries (which most blockchain tools are) work natively with musl via CGO or static compilation.

### Daemonless containers (Podman)

Docker runs a persistent root daemon (`dockerd`). Every container is a child of this daemon. If an attacker compromises the daemon socket (`/var/run/docker.sock`), they own every container on the host.

Podman is daemonless. Each container is a child process of the caller. There is no shared daemon socket to attack. A compromised container cannot escalate to other containers or the host through a daemon.

For validator nodes that hold signing keys, this is critical. The signing key container should be isolated from every other process on the host, including the container runtime.

### Rootless operation

Podman runs containers in user namespaces without real root. The container's "root" maps to an unprivileged UID on the host. Even if an attacker escapes the container, they land as an unprivileged user.

Docker requires root for many operations (bind mounts, port binding < 1024, network namespaces). Podman doesn't.

### Immutable infrastructure

Alpine's simplicity enables read-only root filesystem deployments:

```
/ (read-only, signed image)
/var (writable, ephemeral)
/data (persistent volume, encrypted)
```

A validator node boots from a signed, immutable image. The only writable paths are explicitly designated. Rootkits cannot persist because the root filesystem is read-only.

### Reproducible builds

Alpine's `abuild` system with pinned package versions produces deterministic images. Two operators building from the same Dockerfile get byte-identical container layers.

For blockchain infrastructure, this enables **trustless verification**: an operator can prove their node runs the exact same binary as the reference build, without trusting the builder.

## Why Kurtosis for orchestration

Kurtosis provides:
- **Portable enclaves**: Same deployment on any machine with Docker/Podman
- **Starlark configuration**: Deterministic, reproducible deployment specs
- **Service isolation**: Each enclave is a self-contained network
- **Clean teardown**: `kurtosis clean --all` removes everything

The alternative (docker-compose, Kubernetes) requires more infrastructure. Kurtosis is purpose-built for multi-service development environments.

### Kurtosis + Docker CE for deployment

Kurtosis 2.1.0 requires Docker CE for enclave creation. Its Docker API usage (network inspection, container IP resolution, streaming gRPC) exceeds what Podman's Docker compatibility layer provides in version 4.x.

BDK6 handles this with a dual-runtime approach:
1. **Podman** is installed as the primary container runtime (Apache 2.0)
2. **Docker CE** is installed alongside, used only for Kurtosis enclave deployment
3. Both coexist without conflict

In production, Podman is the runtime. Docker CE is a build-time dependency for the devnet setup phase.

## Why AggLayer v0.3

BDK6 includes AggLayer because it represents the future of Polygon's cross-chain architecture:

- **Pessimistic proof**: Cryptographically ensures no connected chain can withdraw more than it deposited. This is the safety guarantee that makes cross-chain bridges trustable.
- **Unified bridge**: Native asset fungibility across connected chains without wrapping/unwrapping. USDC on chain A is the same USDC on chain B.
- **Settlement via L1**: Both rollup and validium modes settle through AggLayer to Ethereum L1.

In devnet mode, BDK6 uses mock proofs (no real SP1 zkVM computation). This is sufficient for integration testing and development.

## Why Fork ID 12 (Banana)

Fork ID 12 is the current production fork for Polygon zkEVM. It includes:
- Updated prover circuit (v8.0.0-RC16)
- Improved batch processing
- Gas optimization for L2 transactions

BDK6 pins to Fork 12 for compatibility with the production prover. When Fork 13 is released, BDK will update accordingly.

## Design principles

1. **One command**: `./scripts/install-deps-ubuntu.sh` does everything. No manual steps, no "now run this other thing."
2. **Resume, don't restart**: Re-running the installer skips completed steps. It takes seconds on a configured machine.
3. **Fail forward**: Each step has fallbacks. Warnings don't abort. The installer completes with degraded state rather than crashing.
4. **License clean**: Every component is Apache 2.0 or MIT. No proprietary dependencies in the runtime path.
5. **Alpine-first**: The reference platform is Alpine. Ubuntu support is for developer convenience. Production targets Alpine.

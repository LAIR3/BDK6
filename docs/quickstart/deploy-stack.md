---
comments: true
---

## Hardware requirements

- A Linux-based OS (Ubuntu 22.04+, Linux Mint 21.x, or Alpine 3.19+).
- At least 8GB RAM with a 2-core CPU.
- AMD64 or ARM64 architecture.

## Automated install and deploy

The fastest way to get running. One command installs all dependencies, sets up runtimes, starts the Kurtosis engine, and deploys the BDK6 enclave:

```sh
git clone https://github.com/lair3/bdk6.git
cd bdk6
./scripts/install-deps-ubuntu.sh
```

The installer:

- Auto-elevates with `sudo` (prompts for password)
- Installs Podman (Apache 2.0) as the primary container runtime
- Installs Docker CE for Kurtosis enclave orchestration
- Installs Go 1.24.4, Node.js 20.x, Kurtosis, Foundry, polycli, yq, jq, Python deps
- **Resumes** on re-run — skips already-installed tools, reuses the Python venv
- Starts the Kurtosis engine with a countdown timer for gRPC initialization
- Deploys the BDK6 enclave end-to-end
- Use `--clean` for a fresh install from scratch

**Other platforms:**

| Platform | Command |
|---|---|
| Ubuntu/Mint (Podman + Docker) | `./scripts/install-deps-ubuntu.sh` |
| Ubuntu/Mint (Docker only) | `./scripts/install-deps-ubuntu-docker.sh` |
| Alpine Linux (OpenRC) | `./scripts/install-deps-alpine.sh` |

## Manual setup

If you prefer to install dependencies manually:

1. Install the required tools (Go 1.24.4, Node.js 20.x, Docker, Kurtosis, Foundry, polycli, yq, jq).

2. Verify with the tool check script:

    ```sh
    bash scripts/tool_check.sh
    ```

3. Deploy:

    ```sh
    kurtosis run --enclave bdk-v6 --args-file params.yml --image-download always .
    ```

    Deployment takes 5-20 minutes depending on hardware.

When everything is set up and running, we can play around with the test CDK.

## Simple RPC calls

### Inspect the stack

```sh
kurtosis enclave inspect bdk-v6
```

You should see a long output that starts like this:

```sh
Name:            bdk-v6
UUID:            47d8679066a6
Status:          RUNNING
Creation Time:   Wed, 10 Apr 2024 13:58:13 CEST
Flags:

========================================= Files Artifacts =========================================
UUID   Name
```

### Check port mapping

To see the port mapping within the `bdk-v6` enclave for the `zkevm-node-rpc` service and the
`trusted-rpc` port, run the following command:

```sh
kurtosis port print bdk-v6 zkevm-node-rpc-001 http-rpc
```

You should see output that looks something like this (but won't necessarily be the same):

```sh
http://127.0.0.1:65240
```

### Set an environment variable

Let's map the output from the previous step to an environment variable that we can use throughout these instructions.

```sh
export ETH_RPC_URL="$(kurtosis port print bdk-v6 zkevm-node-rpc-001 http-rpc)"
```

### Test cast commands

This is the same environment variable that `cast` uses, so you should now be able to run the following command:

```sh
cast block-number
```

You should see something like this:

```sh
890
```

### Pre-funded account

By default, the CDK is configured in test mode, and this means there is some pre-funded ETH in the admin account that has address: `0xE34aaF64b29273B7D567FCFc40544c014EEe9970`.

Check the balance with the following:

```sh
cast balance --ether 0xE34aaF64b29273B7D567FCFc40544c014EEe9970
```

You should see something like this:

```txt
100000.000000000000000000
```

### Send transaction with cast

```sh
cast send --legacy --private-key 0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625 --value 0.01ether 0x0000000000000000000000000000000000000000
```

You should see something like this as output:

```sh
blockHash               0xc467523f297a9c0b859bedc8feaf44c3e7462de56f7d7899b2039d9a3cfc421d
blockNumber             70
contractAddress
cumulativeGasUsed       21000
effectiveGasPrice       1000000000
from                    0xE34aaF64b29273B7D567FCFc40544c014EEe9970
gasUsed                 21000
logs                    []
logsBloom               0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
root
status                  1
transactionHash         0xa58b3383c1b1f53369723fdc537c88daa03585cb6a89aa49ebd493953d519fdf
transactionIndex        0
type                    0
to                      0x0000000000000000000000000000000000000000
```

### Send transactions with `polygon-cli`

```sh
polycli loadtest --requests 500 --legacy --rpc-url $ETH_RPC_URL --verbosity 700 --rate-limit 5 --mode t --private-key 0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625
polycli loadtest --requests 500 --legacy --rpc-url $ETH_RPC_URL --verbosity 700 --rate-limit 10 --mode t --private-key 0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625
polycli loadtest --requests 500 --legacy --rpc-url $ETH_RPC_URL --verbosity 700 --rate-limit 10 --mode 2 --private-key 0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625
polycli loadtest --requests 500 --legacy --rpc-url $ETH_RPC_URL --verbosity 700 --rate-limit 3 --mode uniswapv3 --private-key 0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625
cast nonce 0xE34aaF64b29273B7D567FCFc40544c014EEe9970
```

### Check the logs

```sh
kurtosis service logs bdk-v6 zkevm-agglayer-001
```

You can open a shell on any service.

```sh
kurtosis service shell bdk-v6 zkevm-node-sequencer-001
```

Another common way to check the status of the system is to make sure that batches go through the normal progression of `trusted`, `virtual`, and `verified`. To check this run:

```sh
cast rpc zkevm_batchNumber
cast rpc zkevm_virtualBatchNumber
cast rpc zkevm_verifiedBatchNumber
```

### Clean up

When everything is done, you might want to clean up with this command which stops everything and deletes it.

```sh
kurtosis clean -a
```

</br>

# Contract verification (BNB mainnet, chainId 56)

## ✅ STATUS: all verified (2026-07-01)
Every contract is verified on BscScan via Etherscan V2: the **13 original core** contracts + the **8 additive
Titans** contracts. TTAN `0x5479Bd2871c644622882B8f7f933D8084c274733` is an EIP-1167 clone and BscScan now
resolves it to the verified `IndexPortfolio` implementation (`getsourcecode` → ContractName: IndexPortfolio).
Re-running `make verify-all` is idempotent (already-verified contracts are skipped).

Covers the **full deployment (original core + additive Titans)**. Compiler settings are read from
`foundry.toml` automatically (solc 0.8.26, `via_ir=true`, `optimizer_runs=200`, `evm_version=cancun`) — they
must match exactly, which they do when you run `forge verify-contract` from this repo.

## ⚠️ Read first — which verifier to use
Tested against your key on 2026-07-01:
- The old **`api.bscscan.com` V1 API is deprecated** (dead). `foundry.toml` is now set to the Etherscan **V2**
  endpoint (`https://api.etherscan.io/v2/api?chainid=56`).
- Your key is **valid** but on the **free plan**, which under V2 **does not cover BSC** ("Free API access is
  not supported for this chain"). So `forge verify-contract --chain bsc` (Etherscan path) needs a **paid
  Etherscan plan**.

Pick one path:

| Path | Cost | Fully automated from Codespaces? | Shows on bscscan.com? |
|---|---|---|---|
| **A. Etherscan V2 API** (paid plan) | paid | ✅ yes | ✅ yes |
| **B. Sourcify** (`--verifier sourcify`) | free | ✅ yes | ⚠️ not on BscScan's tab (shows on sourcify.dev; recognized by tools) |
| **C. BscScan web UI** + `--show-standard-json-input` | free | semi (generate here, paste in browser) | ✅ yes |

If you want the green check on bscscan.com for free, use **C**. If you want one-command automation and don't
mind Sourcify, use **B**. If you'll pay for an Etherscan plan, **A** is the smoothest.

## Contracts + pre-encoded constructor args
| Contract | Address | src path | constructor args (ABI-encoded) |
|---|---|---|---|
| VenusOracleAdapter (NVDAB) | `0x8E00AAADDC258d8F081571D29A9656aD96f4f6b8` | `src/oracle/VenusOracleAdapter.sol:VenusOracleAdapter` | `0x0000…6592b5de…0000…02fca66c…7436` |
| VenusOracleAdapter (SPCXB) | `0x432A4FBdFb65a43B42262726137F428E40f46767` | same | `0x0000…6592b5de…0000…be9d1568…03e1` |
| ChainlinkOnlyDepegMonitor | `0x07Cb968907D81d6B2F3A192738BF58dF50fe3C39` | `src/oracle/ChainlinkOnlyDepegMonitor.sol:ChainlinkOnlyDepegMonitor` | `0x0000…2e7faf4a…0000…be263035…26e3` |
| PancakeV3SwapAdapter | `0x1D34D701358AAC012CD70C3786d23633F5E3F29C` | `src/periphery/PancakeV3SwapAdapter.sol:PancakeV3SwapAdapter` | see `make verify-args` |
| GaugeDistributor | `0xE5B30CFf0108224aac528aaC5Bc2E9C515B8AFc8` | `src/token/GaugeDistributor.sol:GaugeDistributor` | see `make verify-args` |
| FixedWeightStrategy | `0xe597A6C22A385A19C80B1515C5ED68532BB49E99` | `src/core/strategies/FixedWeightStrategy.sol:FixedWeightStrategy` | `0x0000…2e7faf4a…933c` |
| EmissionsAutomation | `0xEa73cE160aB8d5382dE802Ea113d2FD04e8e2787` | `src/token/EmissionsAutomation.sol:EmissionsAutomation` | see `make verify-args` |
| PortfolioToken (TTAN share) | `0x9377916612421DF7F6aA6d90A00156f3A2e8dE3e` | `src/core/PortfolioToken.sol:PortfolioToken` | see `make verify-args` |

Run `make verify-args` to reprint every ABI-encoded arg blob (they're deterministic).

**TTAN Index `0x5479Bd2871c644622882B8f7f933D8084c274733` is an EIP-1167 minimal-proxy clone** of the
IndexPortfolio implementation `0xB52bcfb5B04873bd1bF306c7Cc1C9d4F7edD4fCC` (part of the original live-core
deploy). It has no unique source — verify the implementation once (if not already), then on BscScan use
"Is this a proxy?" so the clone reads through to it. Same for any future portfolio clones.

## A. Etherscan V2 API (paid plan)
```bash
set -a; . ./.env; set +a   # BSCSCAN_API_KEY (on a BSC-covered plan)
forge verify-contract 0x07Cb968907D81d6B2F3A192738BF58dF50fe3C39 \
  src/oracle/ChainlinkOnlyDepegMonitor.sol:ChainlinkOnlyDepegMonitor \
  --chain bsc --watch \
  --constructor-args 0x0000000000000000000000002e7faf4a5c5705d87e7ab58c4a879d7f8adb933c000000000000000000000000be263035a704e5039acab282ab011df8175526e3
```
Repeat per row (swap address, src path, and `--constructor-args`). `make verify-all` runs them all.

## B. Sourcify (free, automated)
```bash
forge verify-contract 0x07Cb968907D81d6B2F3A192738BF58dF50fe3C39 \
  src/oracle/ChainlinkOnlyDepegMonitor.sol:ChainlinkOnlyDepegMonitor \
  --verifier sourcify --chain 56 \
  --constructor-args 0x0000...26e3
```

## C. BscScan web UI (free, manual paste)
For each contract, generate the standard-JSON-input and paste it at
`https://bscscan.com/verifyContract` (choose "Solidity (Standard-Json-Input)", compiler v0.8.26, and paste
the constructor args **without** the leading `0x`):
```bash
forge verify-contract 0x07Cb968907D81d6B2F3A192738BF58dF50fe3C39 \
  src/oracle/ChainlinkOnlyDepegMonitor.sol:ChainlinkOnlyDepegMonitor \
  --show-standard-json-input > verify-ChainlinkOnlyDepegMonitor.json
```

## Sanity check that your key/plan is BSC-enabled (before a big run)
```bash
set -a; . ./.env; set +a
curl -s "https://api.etherscan.io/v2/api?chainid=56&module=account&action=balance&address=0x2e7FaF4a5c5705d87e7AB58c4a879D7F8aDb933C&tag=latest&apikey=$BSCSCAN_API_KEY" | python3 -c "import sys,json;print(json.load(sys.stdin))"
# status=1 => BSC-enabled (path A works). "Free API access is not supported" => use path B or C.
```

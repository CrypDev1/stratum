.PHONY: build test fmt snapshot coverage deploy-testnet clean \
	onboard-assets configure-protocol seed-perp create-gauge create-titans \
	onboard-assets-dry configure-protocol-dry create-titans-dry titans-sim \
	verify-args verify-all verify-sourcify

build:
	forge build

test:
	forge test -vv

fmt:
	forge fmt

snapshot:
	forge snapshot

coverage:
	forge coverage --report summary

deploy-testnet:
	forge script script/Deploy.s.sol:Deploy --rpc-url bsc_testnet --broadcast -vvvv

clean:
	forge clean

# ── Additive integration scripts (broadcast to BNB mainnet; env from .env) ──
onboard-assets:
	forge script script/OnboardAssets.s.sol:OnboardAssets --rpc-url bsc --broadcast -vvvv

configure-protocol:
	forge script script/ConfigureProtocol.s.sol:ConfigureProtocol --rpc-url bsc --broadcast -vvvv

seed-perp:
	forge script script/SeedPerp.s.sol:SeedPerp --rpc-url bsc --broadcast -vvvv

create-gauge:
	forge script script/CreateGauge.s.sol:CreateGauge --rpc-url bsc --broadcast -vvvv

create-titans:
	forge script script/CreateTitans.s.sol:CreateTitans --rpc-url bsc --broadcast -vvvv

# ── Dry-run (SIMULATE ONLY, no --broadcast): forge forks mainnet and simulates the tx sequence ──
onboard-assets-dry:
	forge script script/OnboardAssets.s.sol:OnboardAssets --rpc-url bsc -vvvv

configure-protocol-dry:
	forge script script/ConfigureProtocol.s.sol:ConfigureProtocol --rpc-url bsc -vvvv

create-titans-dry:
	forge script script/CreateTitans.s.sol:CreateTitans --rpc-url bsc -vvvv

# ── Full end-to-end fork simulation incl. a real mint (onboard -> wire -> create TTAN -> mint) ──
titans-sim:
	FORK_RPC=$${FORK_RPC:-https://bsc-dataseed.bnbchain.org} forge test --match-path test/Titans.fork.t.sol -vv

# ── Contract verification (see VERIFY.md). verify-all needs a BSC-covered Etherscan plan; verify-sourcify is free ──
verify-args:
	./script/verify.sh args
verify-all:
	./script/verify.sh etherscan
verify-sourcify:
	./script/verify.sh sourcify

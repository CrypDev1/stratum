.PHONY: build test fmt snapshot coverage deploy-testnet clean \
	onboard-assets configure-protocol seed-perp create-gauge

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

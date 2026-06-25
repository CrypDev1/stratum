.PHONY: build test fmt snapshot coverage deploy-testnet clean

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
	forge script script/Deploy.s.sol:Deploy --rpc-url bsc_testnet --broadcast --verify -vvvv

clean:
	forge clean

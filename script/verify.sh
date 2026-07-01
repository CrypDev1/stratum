#!/usr/bin/env bash
# Verify ALL Stratum contracts on BNB mainnet (chainId 56): the original core + the additive Titans launch.
#   ./script/verify.sh args              # print each contract's ABI-encoded constructor args
#   ./script/verify.sh etherscan         # verify all via Etherscan V2 API (needs a BSC-covered plan + BSCSCAN_API_KEY)
#   ./script/verify.sh sourcify          # verify all via Sourcify (free)
# See VERIFY.md. Constructor args mirror the recorded deploy broadcasts.
set -uo pipefail
MODE="${1:-args}"

# Reference addresses used as constructor args.
ADMIN=0x2e7FaF4a5c5705d87e7AB58c4a879D7F8aDb933C
NAV=0xbe263035a704E5039aCaB282AB011DF8175526e3
POC=0xE28c10B5751bB3E64525fE85951F4A581e253c60
DEPEG=0x7EB90C8F1E8E6bcC0C31A13D37271519dBB50D2a
FEEMGR=0x2BFBdD44A503ee7023D3255C3Bb14754AA2815Ae
IDXIMPL=0xB52bcfb5B04873bd1bF306c7Cc1C9d4F7edD4fCC
VLTIMPL=0xadC5A0bC43CABa6c19DC3701aD92B9b544B1fA95
V2ROUTER=0x10ED43C718714eb63d5aA57B78B54704E256024E
VENUS=0x6592b5DE802159F3E74B2486b091D11a8256ab8A
V3R=0x1b81D678ffb9C0263b24A97847620C99d213eB14
USDT=0x55d398326f99059fF775485246999027B3197955
STRAT=0xf0C2705Cb380c37FA92EEBD9301e13496D859906
VE=0xd2ADC00eF68bFE6Afa912c270413D84E41EE73d8
GC=0xacA48e04ce3b7AD51963fE822Cf04dFB362FA6CE
MINTER=0x11e3f4d2c27e37ad7438deac5C143a06381C4816
GD=0xE5B30CFf0108224aac528aaC5Bc2E9C515B8AFc8
NVDAB=0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436
SPCXB=0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1
TTAN=0x5479Bd2871c644622882B8f7f933D8084c274733

# name|address|src path|encoded constructor args ("" = no-arg constructor)
rows() {
  # ── original core (constructor args mirror broadcast/Deploy.s.sol/56) ──
  echo "NAVOracle|$NAV|src/oracle/NAVOracle.sol:NAVOracle|$(cast abi-encode 'c(address)' $ADMIN)"
  echo "ProofOfCollateral|$POC|src/oracle/ProofOfCollateral.sol:ProofOfCollateral|$(cast abi-encode 'c(address)' $ADMIN)"
  echo "DepegMonitor|$DEPEG|src/oracle/DepegMonitor.sol:DepegMonitor|$(cast abi-encode 'c(address,address)' $ADMIN $NAV)"
  echo "FeeManager|$FEEMGR|src/core/FeeManager.sol:FeeManager|"
  echo "IndexPortfolio|$IDXIMPL|src/core/IndexPortfolio.sol:IndexPortfolio|"
  echo "VaultPortfolio|$VLTIMPL|src/core/VaultPortfolio.sol:VaultPortfolio|"
  echo "PortfolioFactory|0x514ff906D211c86685db3DA68B8d18876A1665bd|src/core/PortfolioFactory.sol:PortfolioFactory|$(cast abi-encode 'c(address,(address,address,address,address,address,address,address,address,uint16))' $ADMIN "($NAV,$POC,$DEPEG,$V2ROUTER,$FEEMGR,$IDXIMPL,$VLTIMPL,$ADMIN,1000)")"
  echo "STRAT|$STRAT|src/token/STRAT.sol:STRAT|$(cast abi-encode 'c(address,uint256)' $ADMIN 0)"
  echo "EmissionsMinter|$MINTER|src/token/EmissionsMinter.sol:EmissionsMinter|$(cast abi-encode 'c(address,address,uint256,uint256)' $ADMIN $STRAT 9512937595129375951 300000000000000000000000000)"
  echo "TeamVesting|0x6356E4429606dD77129EB7821F2DefF500C6599D|src/token/TeamVesting.sol:TeamVesting|$(cast abi-encode 'c(address,address,uint256,uint256)' $STRAT $ADMIN 7776000 63072000)"
  echo "veSTRAT|$VE|src/token/veSTRAT.sol:veSTRAT|$(cast abi-encode 'c(address)' $STRAT)"
  echo "GaugeController|$GC|src/token/GaugeController.sol:GaugeController|$(cast abi-encode 'c(address,address)' $ADMIN $VE)"
  echo "FeeDistributor|0x246de2acC9f613F59C75e13c9b1E60a36D065F04|src/token/FeeDistributor.sol:FeeDistributor|$(cast abi-encode 'c(address,address)' $VE $USDT)"
  # ── additive Titans launch ──
  echo "VenusOracleAdapter(NVDAB)|0x8E00AAADDC258d8F081571D29A9656aD96f4f6b8|src/oracle/VenusOracleAdapter.sol:VenusOracleAdapter|$(cast abi-encode 'c(address,address)' $VENUS $NVDAB)"
  echo "VenusOracleAdapter(SPCXB)|0x432A4FBdFb65a43B42262726137F428E40f46767|src/oracle/VenusOracleAdapter.sol:VenusOracleAdapter|$(cast abi-encode 'c(address,address)' $VENUS $SPCXB)"
  echo "ChainlinkOnlyDepegMonitor|0x07Cb968907D81d6B2F3A192738BF58dF50fe3C39|src/oracle/ChainlinkOnlyDepegMonitor.sol:ChainlinkOnlyDepegMonitor|$(cast abi-encode 'c(address,address)' $ADMIN $NAV)"
  echo "PancakeV3SwapAdapter|0x1D34D701358AAC012CD70C3786d23633F5E3F29C|src/periphery/PancakeV3SwapAdapter.sol:PancakeV3SwapAdapter|$(cast abi-encode 'c(address,address,address,address)' $ADMIN $V3R $NAV $USDT)"
  echo "GaugeDistributor|$GD|src/token/GaugeDistributor.sol:GaugeDistributor|$(cast abi-encode 'c(address,address,address)' $ADMIN $STRAT $GC)"
  echo "FixedWeightStrategy|0xe597A6C22A385A19C80B1515C5ED68532BB49E99|src/core/strategies/FixedWeightStrategy.sol:FixedWeightStrategy|$(cast abi-encode 'c(address)' $ADMIN)"
  echo "EmissionsAutomation|0xEa73cE160aB8d5382dE802Ea113d2FD04e8e2787|src/token/EmissionsAutomation.sol:EmissionsAutomation|$(cast abi-encode 'c(address,address,address,address,uint256)' $ADMIN $MINTER $GD $GD 0)"
  echo "PortfolioToken(TTAN share)|0x9377916612421DF7F6aA6d90A00156f3A2e8dE3e|src/core/PortfolioToken.sol:PortfolioToken|$(cast abi-encode 'c(string,string,address)' 'Titans' 'TTAN' $TTAN)"
}

if [ "$MODE" = "args" ]; then
  rows | while IFS='|' read -r name addr path args; do printf '%-28s %s\n  args: %s\n' "$name" "$addr" "${args:-<none>}"; done
  echo
  echo "TTAN Index 0x5479Bd2871c644622882B8f7f933D8084c274733 is an EIP-1167 clone of IndexPortfolio"
  echo "$IDXIMPL — once the impl is verified, mark the clone a proxy on BscScan (Is this a proxy?)."
  exit 0
fi

case "$MODE" in
  etherscan) VERIFIER_ARGS=(--chain bsc) ;;
  sourcify)  VERIFIER_ARGS=(--verifier sourcify --chain 56) ;;
  *) echo "usage: $0 [args|etherscan|sourcify]"; exit 1 ;;
esac

rows | while IFS='|' read -r name addr path args; do
  echo ">>> verifying $name ($addr)"
  if [ -n "$args" ] && [ "$args" != "0x" ]; then
    forge verify-contract "$addr" "$path" "${VERIFIER_ARGS[@]}" --watch --constructor-args "$args" || echo "!!! $name failed (continuing)"
  else
    forge verify-contract "$addr" "$path" "${VERIFIER_ARGS[@]}" --watch || echo "!!! $name failed (continuing)"
  fi
done

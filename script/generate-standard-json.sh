#!/usr/bin/env bash
#
# Generate per-contract Standard JSON Input files for manual Basescan
# verification. Reads the latest forge broadcast and writes one JSON file
# per deployed contract to ./verify-json/<Name>.json.
#
# Why: Etherscan V2's verifier rejects via_ir projects via the API even
# though local bytecode matches on-chain (we proved this). The UI's
# Standard-Json-Input mode often works where the API fails because it
# uses a slightly different recompile path. Sourcify also works, but
# Basescan's Sourcify integration is not active for Base.
#
# Usage:
#   ./script/generate-standard-json.sh [chain-id]
#
# Then for each contract:
#   1. Visit https://sepolia.basescan.org/verifyContract?a=<address>
#   2. Choose: Solidity (Standard-Json-Input)
#   3. Compiler version: v0.8.28+commit.7893614a
#   4. License: Business Source License 1.1 (or MIT for Mocks)
#   5. Continue → upload the matching ./verify-json/<Name>.json

set -eo pipefail

CHAIN_ID="${1:-84532}"
BROADCAST="broadcast/DeployOddMaki.s.sol/${CHAIN_ID}/run-latest.json"
OUT_DIR="verify-json"

if [ ! -f "$BROADCAST" ]; then
  echo "Error: broadcast file not found at $BROADCAST" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

get_path() {
  case "$1" in
    DiamondCutFacet)        echo "src/facets/DiamondCutFacet.sol" ;;
    DiamondLoupeFacet)      echo "src/facets/DiamondLoupeFacet.sol" ;;
    OwnershipFacet)         echo "src/facets/OwnershipFacet.sol" ;;
    VaultFacet)             echo "src/facets/VaultFacet.sol" ;;
    MarketsFacet)           echo "src/facets/MarketsFacet.sol" ;;
    LimitOrdersFacet)       echo "src/facets/LimitOrdersFacet.sol" ;;
    NegRiskFacet)           echo "src/facets/NegRiskFacet.sol" ;;
    MatchingFacet)          echo "src/facets/MatchingFacet.sol" ;;
    VenueFacet)             echo "src/facets/VenueFacet.sol" ;;
    OrderBookFacet)         echo "src/facets/OrderBookFacet.sol" ;;
    ProtocolFacet)          echo "src/facets/ProtocolFacet.sol" ;;
    MarketGroupFacet)       echo "src/facets/MarketGroupFacet.sol" ;;
    MarketOrdersFacet)      echo "src/facets/MarketOrdersFacet.sol" ;;
    ResolutionFacet)        echo "src/facets/ResolutionFacet.sol" ;;
    ERC1155ReceiverFacet)   echo "src/facets/ERC1155ReceiverFacet.sol" ;;
    AccessControlFacet)     echo "src/facets/AccessControlFacet.sol" ;;
    TagsFacet)              echo "src/facets/TagsFacet.sol" ;;
    MetadataFacet)          echo "src/facets/MetadataFacet.sol" ;;
    PriceMarketFacet)       echo "src/facets/PriceMarketFacet.sol" ;;
    PythResolutionFacet)    echo "src/facets/PythResolutionFacet.sol" ;;
    BatchOrdersFacet)       echo "src/facets/BatchOrdersFacet.sol" ;;
    OddMaki)                echo "src/OddMaki.sol" ;;
    MockERC20)              echo "test/helpers/MockERC20.sol" ;;
    MockCTF)                echo "test/helpers/MockCTF.sol" ;;
    MockUmaOracle)          echo "test/helpers/MockUmaOracle.sol" ;;
    *)                      echo "" ;;
  esac
}

domain="https://sepolia.basescan.org"
[ "$CHAIN_ID" = "8453" ] && domain="https://basescan.org"

echo "Generating Standard JSON Input files into ./${OUT_DIR}/ ..."
echo

while read -r addr name; do
  path="$(get_path "$name")"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    echo "  SKIP   $name (no path / source missing)"
    continue
  fi
  out="$OUT_DIR/${name}.json"
  forge verify-contract \
    --show-standard-json-input \
    --num-of-optimizations 200 \
    --via-ir \
    "$addr" \
    "$path:$name" > "$out" 2>/dev/null
  size=$(wc -c < "$out" | tr -d ' ')
  printf "  %-22s %s  (%s bytes)\n" "$name" "$out" "$size"
  echo "                          ↳ ${domain}/verifyContract?a=${addr}"
done < <(jq -r '.transactions[] | select(.transactionType=="CREATE") | "\(.contractAddress) \(.contractName)"' "$BROADCAST")

cat <<EOF

For each contract, on the BaseScan verify page:
  Compiler Type:     Solidity (Standard-Json-Input)
  Compiler Version:  v0.8.28+commit.7893614a
  License Type:      Business Source License 1.1   (use "MIT License" for MockERC20/MockCTF/MockUmaOracle)
  Click Continue, then upload the matching ./${OUT_DIR}/<Name>.json file.

If the UI succeeds where the API failed, that's the workaround. If the UI also
fails with "bytecode does not match", the only remaining fix is to add
\`bytecode_hash = "none"\` to foundry.toml and redeploy — see DeployOddMaki.s.sol
header for context.
EOF

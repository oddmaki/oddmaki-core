#!/usr/bin/env bash
#
# Verify all contracts from the latest forge broadcast via Sourcify.
#
# Why this exists: `forge script ... --verify --verifier sourcify` silently
# ignores --verifier and falls back to Etherscan, whose V2 multi-chain
# verifier has issues recompiling via_ir projects (bytecode mismatch even
# when local compile matches on-chain byte-for-byte). Sourcify matches on
# metadata content and is reliable; Basescan picks up verified sources
# via its Sourcify integration.
#
# Usage: ./script/verify-deployment.sh [chain-id]
#   chain-id defaults to 84532 (Base Sepolia). Use 8453 for Base mainnet.

set -eo pipefail

CHAIN_ID="${1:-84532}"
BROADCAST="broadcast/DeployOddMaki.s.sol/${CHAIN_ID}/run-latest.json"

if [ ! -f "$BROADCAST" ]; then
  echo "Error: broadcast file not found at $BROADCAST" >&2
  echo "Run a deploy first (without --verify):" >&2
  echo "  forge script script/DeployOddMaki.s.sol:DeployOddMakiScript --rpc-url \$RPC_URL --account deployer --broadcast" >&2
  exit 1
fi

# Map a contract name to its source file path. Returns empty string if unknown.
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

ok=0
skipped=0
failed=0

while read -r addr name; do
  path="$(get_path "$name")"
  if [ -z "$path" ]; then
    echo "  SKIP   $name @ $addr (no source path mapping)"
    skipped=$((skipped + 1))
    continue
  fi
  if [ ! -f "$path" ]; then
    echo "  SKIP   $name @ $addr (source missing: $path)"
    skipped=$((skipped + 1))
    continue
  fi
  out=$(forge verify-contract --verifier sourcify --chain-id "$CHAIN_ID" "$addr" "$path:$name" 2>&1 || true)
  if echo "$out" | grep -q "Response:.*OK"; then
    echo "  OK     $name @ $addr"
    ok=$((ok + 1))
  else
    echo "  FAIL   $name @ $addr"
    echo "$out" | sed 's/^/         /'
    failed=$((failed + 1))
  fi
done < <(jq -r '.transactions[] | select(.transactionType=="CREATE") | "\(.contractAddress) \(.contractName)"' "$BROADCAST")

echo
echo "Summary: ${ok} verified, ${skipped} skipped, ${failed} failed"
echo "Sourcify processes async. Check status at:"
echo "  https://sourcify.dev/#/lookup/<address>"
echo "Basescan picks up the verified source automatically once Sourcify finalizes."

[ "$failed" -eq 0 ]

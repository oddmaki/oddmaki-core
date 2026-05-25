#!/usr/bin/env bash
#
# Generate per-contract Standard JSON Input files for manual Basescan
# verification. For every facet listed in ./deployments/<network>/latest.json,
# this script figures out which git tag produced the on-chain bytecode and
# builds the standard-json against that tag (via a temporary git worktree),
# not against HEAD.
#
# Why pin to a tag: the on-chain bytecode for a facet was produced by the
# repo at the commit/tag of its last deploy. Any later commit that touches
# the facet, its imports, or even shared SPDX/license headers will change
# metadata and produce a non-matching bytecode. Verification fails with
# "bytecode does not match" if we generate the JSON from HEAD when HEAD
# has drifted from the deploy point.
#
# Tag-per-facet rule:
#   - latest version in deployments/<network>/v*.json where the facet
#     appears in .upgrade.changedContracts → that version's tag (v<X.Y.Z>)
#   - otherwise → $DEFAULT_TAG (v1.0.0, the original deploy)
#
# Usage:
#   ./script/generate-standard-json.sh [chain-id]
#
# Then for each contract:
#   1. Visit https://sepolia.basescan.org/verifyContract?a=<address>
#   2. Choose: Solidity (Standard-Json-Input)
#   3. Compiler version: v0.8.28+commit.7893614a
#   4. License: Business Source License 1.1
#   5. Continue → upload the matching ./verify-json/<Name>.json

set -eo pipefail

CHAIN_ID="${1:-84532}"
NETWORK_DIR="base-sepolia"
[ "$CHAIN_ID" = "8453" ] && NETWORK_DIR="base"
LATEST="deployments/${NETWORK_DIR}/latest.json"
OUT_DIR="verify-json"
DEFAULT_TAG="v1.0.0"

if [ ! -f "$LATEST" ]; then
  echo "Error: deployments file not found at $LATEST" >&2
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

ROOT_DIR="$(pwd)"
WORKTREE_BASE="$(mktemp -d)"
MAP="$(mktemp)"
cleanup() {
  for wt in "$WORKTREE_BASE"/*; do
    [ -d "$wt" ] && git worktree remove --force "$wt" >/dev/null 2>&1 || true
  done
  rm -rf "$WORKTREE_BASE"
  rm -f "$MAP"
}
trap cleanup EXIT

# Build the (tag, address, name) map.
while read -r addr name; do
  path="$(get_path "$name")"
  [ -z "$path" ] && continue
  tag="$DEFAULT_TAG"
  for vfile in $(ls "deployments/${NETWORK_DIR}"/v*.json 2>/dev/null | sort -V); do
    if jq -e --arg n "$name" '(.upgrade.changedContracts // []) | any(. == $n)' "$vfile" >/dev/null; then
      tag="v$(jq -r .version "$vfile")"
    fi
  done
  printf '%s\t%s\t%s\n' "$tag" "$addr" "$name"
done < <(jq -r '.contracts | to_entries[] | "\(.value) \(.key)"' "$LATEST") > "$MAP"

# Show the plan.
echo "Plan:"
awk -F'\t' '{printf "  [%-7s] %-22s %s\n", $1, $3, $2}' "$MAP" | sort
echo

# Verify all required tags exist locally.
TAGS=$(awk -F'\t' '{print $1}' "$MAP" | sort -uV)
for tag in $TAGS; do
  if ! git rev-parse "$tag" >/dev/null 2>&1; then
    echo "Error: git tag '$tag' not found locally." >&2
    echo "       Available: $(git tag | tr '\n' ' ')" >&2
    echo "       Run 'git fetch --tags' if a remote has it." >&2
    exit 1
  fi
done

# Process each unique tag in a temporary worktree.
for tag in $TAGS; do
  WT="${WORKTREE_BASE}/${tag}"
  echo "=== Building at $tag (worktree: $WT) ==="
  git worktree add --detach "$WT" "$tag" >/dev/null
  (
    cd "$WT"
    echo "  Building (forge build) to populate the artifact cache..."
    if ! forge build >/tmp/forge-build.log 2>&1; then
      echo "  ERROR: forge build failed at $tag"
      sed 's/^/    /' /tmp/forge-build.log
      exit 1
    fi
    awk -F'\t' -v t="$tag" '$1==t {print $2 "\t" $3}' "$MAP" |
      while IFS=$'\t' read -r addr name; do
        path="$(get_path "$name")"
        if [ ! -f "$path" ]; then
          echo "  SKIP   $name @ $addr (source missing at $tag: $path)"
          continue
        fi
        out="${ROOT_DIR}/${OUT_DIR}/${name}.json"
        if ! forge verify-contract \
              --show-standard-json-input \
              --compiler-version 0.8.28 \
              --num-of-optimizations 200 \
              --via-ir \
              "$addr" \
              "$path:$name" > "$out" 2>/tmp/forge-verify.err; then
          echo "  FAIL   $name @ $addr"
          sed 's/^/         /' /tmp/forge-verify.err
          continue
        fi
        size=$(wc -c < "$out" | tr -d ' ')
        printf "  %-22s %s  (%s bytes)\n" "$name" "$out" "$size"
        echo "                          ↳ ${domain}/verifyContract?a=${addr}"
      done
  )
done

cat <<EOF

For each contract, on the BaseScan verify page:
  Compiler Type:     Solidity (Standard-Json-Input)
  Compiler Version:  v0.8.28+commit.7893614a
  License Type:      Business Source License 1.1
  Click Continue, then upload the matching ./${OUT_DIR}/<Name>.json file.

For OddMaki (the diamond proxy), also paste constructor args from:
  ./${OUT_DIR}/OddMaki.constructor-args.txt

If the UI still fails with "bytecode does not match" for a facet, the
tag mapping for that facet is wrong. Inspect with:
  git worktree add /tmp/wt <tag> && cd /tmp/wt && forge build
and compare \`out/<Facet>.sol/<Facet>.json\` deployedBytecode against the
on-chain code from \`cast code <address> --rpc-url <rpc>\`.
EOF

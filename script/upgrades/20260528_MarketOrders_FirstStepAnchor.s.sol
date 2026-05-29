// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamond} from "../../src/interfaces/IDiamond.sol";
import {MarketOrdersFacet} from "../../src/facets/MarketOrdersFacet.sol";

/**
 * @title 20260528 — MarketOrders: first-step anchor (drop mark-price dependency)
 * @notice Refactors `LibMarketTakeService` to anchor slippage against the
 *         first-step cheapest crossable tick instead of the on-chain mark
 *         price. Matches Polymarket-style semantics: the displayed best
 *         price IS the anchor; slippage is expressed as a percent above it.
 *
 *         Motivation (production bug reported 2026-05-28):
 *         A market BUY of No on a market with only Yes bids resting (50¢ and
 *         56¢) and no trades reverted with `NoReferencePrice`, even though
 *         the implied No ask (44¢ via mint complement of Yes 56) was a
 *         perfectly defensible anchor. The old design conflated "mark price"
 *         (a UI concept, fairly returns undefined when no midpoint + no
 *         trades) with the slippage anchor (a take-execution concept, which
 *         only requires takeable inventory). This patch separates them.
 *
 *         What changes inside the library:
 *         - `LibMarkPriceService.getMarkPriceTick` is no longer called from
 *           the take service. The mark-price view stays available on
 *           OrderBookFacet (for "% chance" UI badges); the take service
 *           ignores it entirely.
 *         - Step 0 of the take loop snapshots the cheapest crossable cost
 *           (across normal-fill and mint/merge paths) as the anchor, then
 *           computes the slippage cap from that anchor and holds it
 *           constant for the rest of the loop.
 *         - `NoReferencePrice` error removed (was previously thrown at facet
 *           entry; now the facet's existing `NoLiquidityAvailable` revert
 *           catches the truly-empty-book case at the end of the loop).
 *
 *         Observable effects:
 *         - States that produced `NoReferencePrice` and had takeable
 *           inventory (one-sided implied book) now fill cleanly.
 *         - States with truly empty inventory on the user's side still
 *           revert (`NoLiquidityAvailable`), same behaviour as before.
 *         - The slippage cap is unchanged in semantics: it locks at
 *           step 0 against the cheapest available cost, so a taker
 *           still cannot "self-justify" extra slippage by walking the
 *           book. Covered by `test_buy_capLockedAtStepZero`.
 *         - 0% slippage now fills the displayed best price exactly,
 *           without walking deeper (the cap = anchor with no headroom).
 *           Covered by `test_buy_slippageZero_capsAtFirstLevel`.
 *
 *         Diamond cut shape:
 *           - Replace: placeMarketBuy(uint256,uint256,uint256,uint256,uint8)
 *           - Replace: placeMarketSell(uint256,uint256,uint256,uint256,uint8)
 *         Both selectors unchanged; only the bytecode behind them is new.
 *         `LibMarketTakeService` is internal-linked into `MarketOrdersFacet`
 *         at compile time so the only on-chain artefact is the replacement
 *         facet. `OrderBookFacet`, `MatchingFacet`, and `LibMarkPriceService`
 *         are untouched.
 *
 *         Storage migration: none.
 *
 *         Downstream impact:
 *         - SDK: no ABI surface change. The `markTick` field of
 *           `MarketOrderBuy` / `MarketOrderSell` events is preserved but its
 *           semantic is now "first-step anchor" rather than "mark price."
 *           SDK helper `previewMarketBuy` should be passed the implied ask
 *           (from `getImpliedTopOfBook`) as the `markPrice` input — that's
 *           what the contract will actually anchor against.
 *         - Subgraph: no event shape change; the `markTick` field
 *           continues to index, no migration needed.
 *         - Venue-starter: drop the strict "no mark price → disable Trade"
 *           gate. When the implied book has takeable supply on the user's
 *           side, the contract will accept and fill the order.
 *
 * ─── Required env ─────────────────────────────────────────────────────────
 *   DIAMOND_ADDRESS  — live OddMaki Diamond proxy on the target network.
 *   SAFE_MODE        — optional. When `true`, the script deploys the new
 *                      MarketOrdersFacet but does NOT call diamondCut.
 *                      Instead it prints the calldata for submission via
 *                      Safe{Wallet}'s Transaction Builder.
 *
 * ─── Run modes ────────────────────────────────────────────────────────────
 * Testnet (Base Sepolia) — EOA owner:
 *   source .env
 *   forge script script/upgrades/20260528_MarketOrders_FirstStepAnchor.s.sol \
 *       --rpc-url $RPC_URL --account deployer --broadcast -vvvv
 *
 * Mainnet (Base) — Safe owner, print calldata:
 *   source .env.mainnet
 *   forge script script/upgrades/20260528_MarketOrders_FirstStepAnchor.s.sol \
 *       --rpc-url $RPC_URL \
 *       --account deployer-mainnet \
 *       --sender <deployer-mainnet-address> \
 *       --broadcast -vvvv
 *
 * Simulation only — no broadcast:
 *   forge script script/upgrades/20260528_MarketOrders_FirstStepAnchor.s.sol \
 *       --rpc-url $RPC_URL --sender <owner-or-safe-addr> -vvvv
 *
 * ─── After broadcast ──────────────────────────────────────────────────────
 *   - Verify the new facet on the explorer:
 *       forge verify-contract <new-facet-addr> src/facets/MarketOrdersFacet.sol:MarketOrdersFacet \
 *           --chain <base|base-sepolia> --watch
 *   - Snapshot the deployment:
 *       node script/save-deployment.js <network> <version> "<notes>" \
 *           --upgrade 20260528_MarketOrders_FirstStepAnchor.s.sol
 *   - Loupe check — confirm both selectors point at the new facet:
 *       cast call $DIAMOND_ADDRESS "facetAddress(bytes4)(address)" \
 *           $(cast sig "placeMarketBuy(uint256,uint256,uint256,uint256,uint8)") --rpc-url $RPC_URL
 *       cast call $DIAMOND_ADDRESS "facetAddress(bytes4)(address)" \
 *           $(cast sig "placeMarketSell(uint256,uint256,uint256,uint256,uint8)") --rpc-url $RPC_URL
 *     Expect: both return the new facet address printed by this script.
 *   - Smoke test by reproducing the reported scenario: place Yes bids at
 *     50 and 56, no trades, submit a market BUY for No with 5%
 *     slippage — should mint-fill against Yes 56.
 */
contract UpgradeMarketOrdersFirstStepAnchor is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        bool safeMode = vm.envOr("SAFE_MODE", false);

        vm.startBroadcast();

        // 1. Deploy the new MarketOrdersFacet implementation. The refactored
        //    LibMarketTakeService is internal-linked into it at compile time,
        //    so this is the only on-chain artefact.
        MarketOrdersFacet newFacet = new MarketOrdersFacet();

        // 2. Build the cut. Single FacetCut entry: Replace both surviving
        //    selectors so they point at the new bytecode.
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](1);

        bytes4[] memory replaceSelectors = new bytes4[](2);
        replaceSelectors[0] = MarketOrdersFacet.placeMarketBuy.selector;
        replaceSelectors[1] = MarketOrdersFacet.placeMarketSell.selector;
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(newFacet),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: replaceSelectors
        });

        if (safeMode) {
            vm.stopBroadcast();

            bytes memory cutCalldata = abi.encodeWithSelector(
                IDiamondCut.diamondCut.selector,
                cuts,
                address(0),
                hex""
            );

            console.log("");
            console.log("=== Safe Transaction Builder ===");
            console.log("To:    ", diamond);
            console.log("Value:  0");
            console.log("Data:");
            console.logBytes(cutCalldata);
            console.log("");
            console.log("New MarketOrdersFacet deployed at:", address(newFacet));
            return;
        }

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        vm.stopBroadcast();

        console.log("Diamond cut executed against:    ", diamond);
        console.log("New MarketOrdersFacet address:   ", address(newFacet));
    }
}

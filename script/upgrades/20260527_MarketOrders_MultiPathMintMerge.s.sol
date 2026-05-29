// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamond} from "../../src/interfaces/IDiamond.sol";
import {MarketOrdersFacet} from "../../src/facets/MarketOrdersFacet.sol";
import {OrderBookFacet} from "../../src/facets/OrderBookFacet.sol";
import {MatchingFacet} from "../../src/facets/MatchingFacet.sol";

/**
 * @title 20260527 — MarketOrders: multi-path (normal + mint/merge), slippage-anchored
 * @notice Replaces the legacy single-path market-order surface with a unified
 *         multi-path implementation:
 *           - Market BUY walks both the same-outcome SELL book (normal fill)
 *             AND the opposite-outcome BUY book (mint fill via CTF.splitPosition),
 *             picking the cheapest crossable path per step. Slippage is anchored
 *             to the on-chain mark price at facet entry (no caller-supplied price).
 *           - Market SELL walks the same-outcome BUY book (normal) AND the
 *             opposite-outcome SELL book (merge fill via CTF.mergePositions),
 *             picking the path with the highest net taker tick per step.
 *
 *         The legacy `placeMarketOrder` (single-path BUY) reverts with
 *         `NoLiquidityAvailable` whenever the same-outcome SELL book is empty,
 *         even if mint-fill could settle the trade. This was reported in
 *         production via the venue-starter UI. The new flow lets the user
 *         express intent ("buy this outcome at market") and the protocol
 *         resolves both the reference price and the cheapest crossing path
 *         on-chain.
 *
 *         The mark-price waterfall (PR 2) is also part of this upgrade. The
 *         old `OrderBookFacet.getMarkPrice` only looked at same-outcome direct
 *         top-of-book; the new implementation accounts for cross-outcome
 *         complement via mint/merge, scales the spread threshold by tick size,
 *         and returns `(0, false)` honestly when neither implied midpoint nor
 *         last-trade can produce a defensible reference. A new external view
 *         `getImpliedTopOfBook` exposes the implied bid/ask for SDK previews.
 *
 *         MatchingFacet bytecode is also replaced. The matching engine's
 *         observable behaviour is unchanged, but its internal call graph
 *         changed in PR 1 (each fill service's `tryFill` now delegates to
 *         a private `_executeFill` helper so the new market-take service can
 *         share single-fill primitives). Re-pointing the selector at the
 *         freshly compiled facet keeps every `matchOrders` call routing
 *         through the same compiled implementation as the new market-order
 *         path.
 *
 *         Diamond cut shape:
 *
 *         MarketOrdersFacet:
 *           - Add:     placeMarketBuy(uint256,uint256,uint256,uint256,uint8)
 *           - Replace: placeMarketSell(uint256,uint256,uint256,uint256,uint8)
 *                      (same selector, new bytecode; param 4 is now slippageBps
 *                      instead of minPriceTick — BREAKING for callers)
 *           - Remove:  placeMarketOrder(uint256,uint256,uint256,uint256,uint8)
 *
 *         OrderBookFacet:
 *           - Replace: getTopOfBook(uint256,uint256,uint8)
 *                      getTickLevel(uint256,uint256,uint8,uint256)
 *                      getMarkPrice(uint256,uint256)               (new bytecode)
 *                      canMatchOrders(uint256)
 *                      getFill(uint256)
 *                      getNextFillId()
 *           - Add:     getImpliedTopOfBook(uint256,uint256)
 *
 *         MatchingFacet:
 *           - Replace: matchOrders(uint256,uint256)                (new bytecode)
 *
 *         Storage migration: none. No new storage slots, no struct changes.
 *
 *         Downstream consumers (BREAKING):
 *           - SDK: regenerate MarketOrdersFacet ABI; replace any caller of
 *             placeMarketOrder/placeMarketSell with placeMarketBuy/
 *             placeMarketSell using slippageBps semantics.
 *           - Subgraph: existing MarketOrderExecuted / MarketSellExecuted
 *             events are gone; index MarketOrderBuy / MarketOrderSell from
 *             the new facet. Existing MintFill / MergeFill / TradeExecuted
 *             events are unchanged but may now also be emitted under
 *             placeMarketBuy / placeMarketSell transactions.
 *           - Venue-starter: switch the market mode UI to slippageBps + drop
 *             the maxPrice slider; gate on `getMarkPrice.isDefined`.
 *
 * ─── Required env ─────────────────────────────────────────────────────────
 *   DIAMOND_ADDRESS  — live OddMaki Diamond proxy on the target network.
 *   SAFE_MODE        — optional. When `true`, the script deploys the new
 *                      facets but does NOT call diamondCut. Instead it prints
 *                      the calldata for submission via Safe{Wallet}'s
 *                      Transaction Builder. Used for mainnet where the
 *                      Diamond owner is a Safe.
 *
 * ─── Run modes ────────────────────────────────────────────────────────────
 * Testnet (Base Sepolia) — EOA owner:
 *   source .env
 *   forge script script/upgrades/20260527_MarketOrders_MultiPathMintMerge.s.sol \
 *       --rpc-url $RPC_URL --account deployer --broadcast -vvvv
 *
 * Mainnet (Base) — Safe owner, print calldata:
 *   source .env.mainnet      # exports DIAMOND_ADDRESS and SAFE_MODE=true
 *   forge script script/upgrades/20260527_MarketOrders_MultiPathMintMerge.s.sol \
 *       --rpc-url $RPC_URL \
 *       --account deployer-mainnet \
 *       --sender <deployer-mainnet-address> \
 *       --broadcast \
 *       -vvvv
 *
 * Simulation only — no broadcast:
 *   forge script script/upgrades/20260527_MarketOrders_MultiPathMintMerge.s.sol \
 *       --rpc-url $RPC_URL --sender <owner-or-safe-addr> -vvvv
 *
 * ─── Pre-flight (recommended) ─────────────────────────────────────────────
 *   - `forge build && forge test` clean.
 *   - Confirm the live DIAMOND_ADDRESS still has the OLD MarketOrdersFacet by
 *     looking up the legacy selector:
 *       cast call $DIAMOND_ADDRESS "facetAddress(bytes4)(address)" \
 *           $(cast sig "placeMarketOrder(uint256,uint256,uint256,uint256,uint8)") \
 *           --rpc-url $RPC_URL
 *     Expect: the old MarketOrdersFacet address.
 *
 * ─── After broadcast ──────────────────────────────────────────────────────
 *   - Verify the new facets on the explorer:
 *       forge verify-contract <addr> src/facets/MarketOrdersFacet.sol:MarketOrdersFacet --chain <base|base-sepolia> --watch
 *       forge verify-contract <addr> src/facets/OrderBookFacet.sol:OrderBookFacet     --chain <base|base-sepolia> --watch
 *       forge verify-contract <addr> src/facets/MatchingFacet.sol:MatchingFacet       --chain <base|base-sepolia> --watch
 *   - Snapshot the deployment:
 *       node script/save-deployment.js <network> <version> "<notes>" \
 *           --upgrade 20260527_MarketOrders_MultiPathMintMerge.s.sol
 *   - Loupe checks — confirm selectors now point at the new facets:
 *       cast call $DIAMOND_ADDRESS "facetAddress(bytes4)(address)" \
 *           $(cast sig "placeMarketBuy(uint256,uint256,uint256,uint256,uint8)") --rpc-url $RPC_URL
 *       cast call $DIAMOND_ADDRESS "facetAddress(bytes4)(address)" \
 *           $(cast sig "getImpliedTopOfBook(uint256,uint256)") --rpc-url $RPC_URL
 *       cast call $DIAMOND_ADDRESS "facetAddress(bytes4)(address)" \
 *           $(cast sig "placeMarketOrder(uint256,uint256,uint256,uint256,uint8)") --rpc-url $RPC_URL
 *     Expect: first two return the new facet addresses; the third returns 0x0.
 *   - Smoke-test on testnet by reproducing the user-reported scenario:
 *     place a BUY on Up at 47, then a market BUY on Down with 5% slippage —
 *     should mint-fill against the Up bid.
 */
contract UpgradeMarketOrdersMultiPath is Script {
    /// @dev Hardcoded selector for the removed legacy entry point — the source
    ///      no longer exposes it, so we can't compute the selector via the
    ///      `Facet.fn.selector` reference.
    bytes4 internal constant PLACE_MARKET_ORDER_SELECTOR =
        bytes4(keccak256("placeMarketOrder(uint256,uint256,uint256,uint256,uint8)"));

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        bool safeMode = vm.envOr("SAFE_MODE", false);

        vm.startBroadcast();

        // 1. Deploy the new facet implementations. The new LibMarketTakeService,
        //    LibMarkPriceService, and the refactored fill services are
        //    internal-linked into their respective facets at compile time.
        MarketOrdersFacet newMarketOrdersFacet = new MarketOrdersFacet();
        OrderBookFacet newOrderBookFacet = new OrderBookFacet();
        MatchingFacet newMatchingFacet = new MatchingFacet();

        // 2. Build the cuts — 6 entries total.
        //    [0] MarketOrdersFacet: Remove  placeMarketOrder (legacy).
        //    [1] MarketOrdersFacet: Add     placeMarketBuy.
        //    [2] MarketOrdersFacet: Replace placeMarketSell (same selector, new bytecode).
        //    [3] OrderBookFacet:    Replace 6 existing selectors.
        //    [4] OrderBookFacet:    Add     getImpliedTopOfBook.
        //    [5] MatchingFacet:     Replace matchOrders.
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](6);

        // (a) Remove legacy placeMarketOrder from the live Diamond.
        bytes4[] memory removeSelectors = new bytes4[](1);
        removeSelectors[0] = PLACE_MARKET_ORDER_SELECTOR;
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(0),
            action: IDiamond.FacetCutAction.Remove,
            functionSelectors: removeSelectors
        });

        // (b) Add placeMarketBuy at the new facet.
        bytes4[] memory addBuy = new bytes4[](1);
        addBuy[0] = MarketOrdersFacet.placeMarketBuy.selector;
        cuts[1] = IDiamond.FacetCut({
            facetAddress: address(newMarketOrdersFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: addBuy
        });

        // (c) Replace placeMarketSell — same selector, new bytecode + new semantics
        //     (param 4 is now slippageBps instead of minPriceTick).
        bytes4[] memory replaceSell = new bytes4[](1);
        replaceSell[0] = MarketOrdersFacet.placeMarketSell.selector;
        cuts[2] = IDiamond.FacetCut({
            facetAddress: address(newMarketOrdersFacet),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: replaceSell
        });

        // (d) OrderBookFacet: replace the 6 existing selectors and add the new
        //     getImpliedTopOfBook. Combine into one Add + one Replace cut entry.
        bytes4[] memory orderBookReplace = new bytes4[](6);
        orderBookReplace[0] = OrderBookFacet.getTopOfBook.selector;
        orderBookReplace[1] = OrderBookFacet.getTickLevel.selector;
        orderBookReplace[2] = OrderBookFacet.getMarkPrice.selector;
        orderBookReplace[3] = OrderBookFacet.canMatchOrders.selector;
        orderBookReplace[4] = OrderBookFacet.getFill.selector;
        orderBookReplace[5] = OrderBookFacet.getNextFillId.selector;
        cuts[3] = IDiamond.FacetCut({
            facetAddress: address(newOrderBookFacet),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: orderBookReplace
        });

        bytes4[] memory orderBookAdd = new bytes4[](1);
        orderBookAdd[0] = OrderBookFacet.getImpliedTopOfBook.selector;
        cuts[4] = IDiamond.FacetCut({
            facetAddress: address(newOrderBookFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: orderBookAdd
        });

        // (e) MatchingFacet: replace matchOrders. Bytecode changed in PR 1
        //     because the fill services now route through extracted
        //     `_executeFill` helpers — observable behaviour identical, but
        //     the compiled facet must reflect the refactor.
        bytes4[] memory matchingReplace = new bytes4[](1);
        matchingReplace[0] = MatchingFacet.matchOrders.selector;
        cuts[5] = IDiamond.FacetCut({
            facetAddress: address(newMatchingFacet),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: matchingReplace
        });

        if (safeMode) {
            // 3a. SAFE MODE — do NOT call diamondCut. Print the calldata so
            //     the operator can submit it via the Safe UI.
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
            console.log("New MarketOrdersFacet deployed at:", address(newMarketOrdersFacet));
            console.log("New OrderBookFacet deployed at:   ", address(newOrderBookFacet));
            console.log("New MatchingFacet deployed at:    ", address(newMatchingFacet));
            return;
        }

        // 3b. EOA MODE — execute the cut directly. No initializer (no storage migration).
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        vm.stopBroadcast();

        console.log("Diamond cut executed against:    ", diamond);
        console.log("New MarketOrdersFacet address:   ", address(newMarketOrdersFacet));
        console.log("New OrderBookFacet address:      ", address(newOrderBookFacet));
        console.log("New MatchingFacet address:       ", address(newMatchingFacet));
    }
}

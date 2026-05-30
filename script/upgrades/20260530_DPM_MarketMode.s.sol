// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamond} from "../../src/interfaces/IDiamond.sol";

import {DpmMarketFacet} from "../../src/facets/DpmMarketFacet.sol";
import {DpmTradingFacet} from "../../src/facets/DpmTradingFacet.sol";
import {MarketsFacet} from "../../src/facets/MarketsFacet.sol";
import {MarketOrdersFacet} from "../../src/facets/MarketOrdersFacet.sol";
import {LimitOrdersFacet} from "../../src/facets/LimitOrdersFacet.sol";
import {BatchOrdersFacet} from "../../src/facets/BatchOrdersFacet.sol";
import {MatchingFacet} from "../../src/facets/MatchingFacet.sol";
import {PythResolutionFacet} from "../../src/facets/PythResolutionFacet.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";

/**
 * @title 20260530 — DPM market mode (Pennock 2004 §4): binary UMA + Pyth, categorical N-outcome
 * @notice Adds the self-funded Dynamic Pari-Mutuel trading mode alongside the CLOB. The operator
 *         never holds risk: pure redistribution (losers fund winners) plus an outcome-independent
 *         entry fee. New surface:
 *           - DpmMarketFacet  — createDpmMarket (binary UMA OR categorical N-outcome),
 *             createDpmPriceMarket (binary Pyth), addDpmOutcome (late outcome), and read views.
 *           - DpmTradingFacet — enterIntent / exitIntent / enter (slippage-guarded) / claim.
 *
 *         DPM pools hold NO CTF outcome tokens; they reuse only the CTF *condition* for resolution
 *         (UMA assert-truth or Pyth), and pay out from their own pool accounting. The load-bearing
 *         invariant is `Σ M_i == collateral in custody` at all times.
 *
 * ─── Diamond cut shape ────────────────────────────────────────────────────
 *   ADD     DpmMarketFacet   (11 selectors)
 *   ADD     DpmTradingFacet  (4 selectors)
 *   REPLACE MarketsFacet            — createMarket now takes the allowMultiOutcome flag (binary
 *                                     callers pass false); selectors unchanged.
 *   REPLACE MarketOrdersFacet       — cross-mode guard: reject DPM markets at CLOB entry points.
 *   REPLACE LimitOrdersFacet        — cross-mode guard.
 *   REPLACE BatchOrdersFacet        — cross-mode guard.
 *   REPLACE MatchingFacet           — cross-mode guard.
 *   REPLACE PythResolutionFacet     — PriceMarketCreatedPyth now emitted by LibPriceMarketService
 *                                     (shared by the CLOB + DPM price paths); selectors unchanged.
 *   REPLACE VaultFacet              — cross-mode guard on splitPosition/mergePositions (DPM markets
 *                                     hold no CTF outcome tokens); selectors unchanged.
 *   All REPLACE selectors are unchanged — only the bytecode behind them is new (internal libraries
 *   are inlined at compile time, so each changed library ships inside the facets that call it).
 *
 *   Storage migration: NONE. DPM uses a fresh namespace (`oddmaki.storage.dpm`); no existing struct
 *   layout changed. The whole cut is one atomic diamondCut so the cross-mode guard is live before any
 *   DPM market can be created.
 *
 * ─── Downstream impact ────────────────────────────────────────────────────
 *   - SDK: new DpmMarket/DpmTrading ABIs. `enter` takes `minSharesOut` (slippage) — pass a quote
 *     from `quoteEntryShares` minus tolerance. Categorical markets read `outcomeCount`/`outcomes`.
 *   - Subgraph: index DpmMarketCreated, DpmPoolSeeded, DpmEntered (carries post-trade M/N),
 *     DpmIntentEntered/Exited, DpmClaimed, DpmOutcomeAdded (carries the NEW conditionId — it changes),
 *     and PriceMarketCreatedPyth (now also fired by DPM price markets). MarketCreated already covers
 *     identity/collateral for DPM markets.
 *   - Venue-starter: new DPM trading UI; intent phase before openTime.
 *
 * ─── Required env ─────────────────────────────────────────────────────────
 *   DIAMOND_ADDRESS  — live OddMaki Diamond proxy on the target network.
 *   SAFE_MODE        — optional. When `true`, deploys the facets but prints the diamondCut calldata
 *                      for Safe{Wallet} submission instead of calling diamondCut.
 *
 * ─── Run modes ────────────────────────────────────────────────────────────
 * Testnet (Base Sepolia) — EOA owner:
 *   source .env
 *   forge script script/upgrades/20260530_DPM_MarketMode.s.sol \
 *       --rpc-url $RPC_URL --account deployer --broadcast -vvvv
 *
 * Mainnet (Base) — Safe owner, print calldata:
 *   SAFE_MODE=true source .env.mainnet
 *   forge script script/upgrades/20260530_DPM_MarketMode.s.sol --rpc-url $RPC_URL -vvvv
 *
 * ─── After broadcast ──────────────────────────────────────────────────────
 *   - Verify each new/replaced facet on the explorer (forge verify-contract ...).
 *   - Loupe check the DPM selectors resolve to the new facets:
 *       cast call $DIAMOND_ADDRESS "facetAddress(bytes4)(address)" \
 *           $(cast sig "createDpmMarket(uint256,bytes,string[],address,uint256,uint64,uint256,uint256,bytes32[])") --rpc-url $RPC_URL
 *   - Confirm a CLOB entry point still resolves (and now rejects DPM markets):
 *       cast call $DIAMOND_ADDRESS "facetAddress(bytes4)(address)" \
 *           $(cast sig "placeMarketBuy(uint256,uint256,uint256,uint256,uint8)") --rpc-url $RPC_URL
 *   - Snapshot: node script/save-deployment.js <network> <version> "DPM market mode" \
 *           --upgrade 20260530_DPM_MarketMode.s.sol
 */
contract UpgradeDpmMarketMode is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        bool safeMode = vm.envOr("SAFE_MODE", false);

        vm.startBroadcast();

        // 1. Deploy new + changed facets (changed internal libraries are inlined at compile time).
        DpmMarketFacet dpmMarket = new DpmMarketFacet();
        DpmTradingFacet dpmTrading = new DpmTradingFacet();
        MarketsFacet markets = new MarketsFacet();
        MarketOrdersFacet marketOrders = new MarketOrdersFacet();
        LimitOrdersFacet limitOrders = new LimitOrdersFacet();
        BatchOrdersFacet batchOrders = new BatchOrdersFacet();
        MatchingFacet matching = new MatchingFacet();
        PythResolutionFacet pyth = new PythResolutionFacet();
        VaultFacet vault = new VaultFacet();

        // 2. Build the cut: 2 Add + 7 Replace, applied atomically.
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](9);
        cuts[0] = _cut(address(dpmMarket), IDiamond.FacetCutAction.Add, _dpmMarketSelectors());
        cuts[1] = _cut(address(dpmTrading), IDiamond.FacetCutAction.Add, _dpmTradingSelectors());
        cuts[2] = _cut(address(markets), IDiamond.FacetCutAction.Replace, _marketsSelectors());
        cuts[3] = _cut(address(marketOrders), IDiamond.FacetCutAction.Replace, _marketOrdersSelectors());
        cuts[4] = _cut(address(limitOrders), IDiamond.FacetCutAction.Replace, _limitOrdersSelectors());
        cuts[5] = _cut(address(batchOrders), IDiamond.FacetCutAction.Replace, _batchOrdersSelectors());
        cuts[6] = _cut(address(matching), IDiamond.FacetCutAction.Replace, _matchingSelectors());
        cuts[7] = _cut(address(pyth), IDiamond.FacetCutAction.Replace, _pythSelectors());
        cuts[8] = _cut(address(vault), IDiamond.FacetCutAction.Replace, _vaultSelectors());

        if (safeMode) {
            vm.stopBroadcast();
            bytes memory cutCalldata =
                abi.encodeWithSelector(IDiamondCut.diamondCut.selector, cuts, address(0), hex"");
            console.log("");
            console.log("=== Safe Transaction Builder ===");
            console.log("To:    ", diamond);
            console.log("Value:  0");
            console.log("Data:");
            console.logBytes(cutCalldata);
            _logAddresses(dpmMarket, dpmTrading, markets, marketOrders, limitOrders, batchOrders, matching, pyth, vault);
            return;
        }

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        vm.stopBroadcast();

        console.log("Diamond cut executed against:", diamond);
        _logAddresses(dpmMarket, dpmTrading, markets, marketOrders, limitOrders, batchOrders, matching, pyth, vault);
    }

    // ---- cut helper ----

    function _cut(address facet, IDiamond.FacetCutAction action, bytes4[] memory selectors)
        private
        pure
        returns (IDiamond.FacetCut memory)
    {
        return IDiamond.FacetCut({facetAddress: facet, action: action, functionSelectors: selectors});
    }

    // ---- selector lists (must match the live diamond exactly for Replace) ----

    function _dpmMarketSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](11);
        s[0] = DpmMarketFacet.createDpmMarket.selector;
        s[1] = DpmMarketFacet.createDpmPriceMarket.selector;
        s[2] = DpmMarketFacet.addDpmOutcome.selector;
        s[3] = DpmMarketFacet.isDpmMarket.selector;
        s[4] = DpmMarketFacet.getDpmMarket.selector;
        s[5] = DpmMarketFacet.getMarketCollateral.selector;
        s[6] = DpmMarketFacet.getMarketShares.selector;
        s[7] = DpmMarketFacet.getIntentStake.selector;
        s[8] = DpmMarketFacet.getUserShares.selector;
        s[9] = DpmMarketFacet.getUserPaid.selector;
        s[10] = DpmMarketFacet.quoteEntryShares.selector;
    }

    function _dpmTradingSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = DpmTradingFacet.enterIntent.selector;
        s[1] = DpmTradingFacet.exitIntent.selector;
        s[2] = DpmTradingFacet.enter.selector;
        s[3] = DpmTradingFacet.claim.selector;
    }

    function _marketsSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = MarketsFacet.createMarket.selector;
        s[1] = MarketsFacet.getMarketRegistryData.selector;
        s[2] = MarketsFacet.getMarketTradingData.selector;
        s[3] = MarketsFacet.getMarketOracleData.selector;
        s[4] = MarketsFacet.getNextMarketId.selector;
        s[5] = MarketsFacet.addMarket.selector;
        s[6] = MarketsFacet.addPlaceholderMarkets.selector;
        s[7] = MarketsFacet.activatePlaceholder.selector;
        s[8] = MarketsFacet.pauseMarket.selector;
        s[9] = MarketsFacet.unpauseMarket.selector;
    }

    function _marketOrdersSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = MarketOrdersFacet.placeMarketBuy.selector;
        s[1] = MarketOrdersFacet.placeMarketSell.selector;
    }

    function _limitOrdersSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = LimitOrdersFacet.placeOrder.selector;
        s[1] = LimitOrdersFacet.cancelOrder.selector;
        s[2] = LimitOrdersFacet.getOrder.selector;
        s[3] = LimitOrdersFacet.expireOrders.selector;
        s[4] = LimitOrdersFacet.cancelOrdersOnResolvedMarket.selector;
    }

    function _batchOrdersSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = BatchOrdersFacet.batchPlaceOrders.selector;
        s[1] = BatchOrdersFacet.batchCancelOrders.selector;
        s[2] = BatchOrdersFacet.cancelAndReplace.selector;
    }

    function _matchingSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = MatchingFacet.matchOrders.selector;
    }

    function _pythSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = PythResolutionFacet.setPythContract.selector;
        s[1] = PythResolutionFacet.getPythContract.selector;
        s[2] = PythResolutionFacet.createPriceMarketPyth.selector;
        s[3] = PythResolutionFacet.resolvePriceMarketPyth.selector;
        s[4] = PythResolutionFacet.markPriceMarketInvalid.selector;
    }

    function _vaultSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = VaultFacet.getVault.selector;
        s[1] = VaultFacet.getCtfAddress.selector;
        s[2] = VaultFacet.setCtf.selector;
        s[3] = VaultFacet.splitPosition.selector;
        s[4] = VaultFacet.mergePositions.selector;
    }

    function _logAddresses(
        DpmMarketFacet a,
        DpmTradingFacet b,
        MarketsFacet c,
        MarketOrdersFacet d,
        LimitOrdersFacet e,
        BatchOrdersFacet f,
        MatchingFacet g,
        PythResolutionFacet h,
        VaultFacet i
    ) private pure {
        console.log("DpmMarketFacet (Add):      ", address(a));
        console.log("DpmTradingFacet (Add):     ", address(b));
        console.log("MarketsFacet (Replace):    ", address(c));
        console.log("MarketOrdersFacet (Replace):", address(d));
        console.log("LimitOrdersFacet (Replace):", address(e));
        console.log("BatchOrdersFacet (Replace):", address(f));
        console.log("MatchingFacet (Replace):   ", address(g));
        console.log("PythResolutionFacet (Replace):", address(h));
        console.log("VaultFacet (Replace):      ", address(i));
    }
}

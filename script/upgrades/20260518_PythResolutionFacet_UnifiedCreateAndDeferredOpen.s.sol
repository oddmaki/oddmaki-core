// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamond} from "../../src/interfaces/IDiamond.sol";
import {PythResolutionFacet} from "../../src/facets/PythResolutionFacet.sol";

/**
 * @title 20260518 — PythResolutionFacet: Unified createPriceMarketPyth + deferred open capture
 * @notice Replaces the existing PythResolutionFacet with a freshly deployed one and
 *         restructures its selectors:
 *
 *         Removed selectors:
 *           - createPriceMarketPyth(uint256,bytes32,int64,uint256,string[],uint256,
 *                                   address,bytes,uint64,bytes32[],uint256,bytes[])
 *             (old payable signature with pythUpdateData at creation)
 *           - setOpenMaxStaleness(uint256)
 *           - getOpenMaxStaleness()
 *
 *         Added selector:
 *           - createPriceMarketPyth(uint256,bytes32,int64,uint256,uint256,string[],
 *                                   uint256,address,bytes,uint64,bytes32[],uint256)
 *             (new non-payable signature with `openTime` parameter; no `pythUpdateData`)
 *
 *         Replaced (same selector, new bytecode):
 *           - setPythContract(address)
 *           - getPythContract()
 *           - resolvePriceMarketPyth(uint256,bytes[])
 *           - markPriceMarketInvalid(uint256)
 *
 *         Behaviour change:
 *         - Creation is now `nonpayable` and takes an `openTime` parameter.
 *           `openTime == 0` → immediate market (set to `block.timestamp`).
 *           `openTime > 0` → scheduled market; must be strictly in the future.
 *           Creation never touches Pyth — no VAA, no Pyth fee.
 *         - For deferred Up/Down markets (`strikePrice == 0` at creation),
 *           `resolvePriceMarketPyth` captures the open price from Hermes VAAs in
 *           `[openTime, openTime + window]` and the close price from
 *           `[closeTime, closeTime + window]` in a single resolution transaction.
 *           The resolver submits both windows' VAAs concatenated in one array;
 *           out-of-range entries per window are skipped via try/catch.
 *         - Strike markets (explicit `strikePrice > 0`) behave exactly as today.
 *
 *         Storage migration: none. `LibPriceMarketStorage.Storage.openMaxStaleness`
 *         (slot 2) is dropped from the library. No live code reads or writes it
 *         after this cut. No other namespace reads from that slot. Existing
 *         deployed storage values at slot 2 become dormant.
 *
 *         Existing markets: a market created before this upgrade has its
 *         `strikePrice` already populated (either explicit or the prior creation-
 *         time capture), so resolution of legacy markets takes the `strikePrice != 0`
 *         branch and skips open-price capture — same behaviour as today.
 *
 *         Downstream consumers (SDK, subgraph, dApps, bots) must update in lockstep
 *         with this cut. There is no compatibility shim.
 *
 * ─── Required env ─────────────────────────────────────────────────────────
 *   DIAMOND_ADDRESS  — live OddMaki Diamond proxy on the target network.
 *   SAFE_MODE        — optional. When `true`, the script deploys the new
 *                      PythResolutionFacet but does NOT call diamondCut.
 *                      Instead it prints the calldata for submission via
 *                      Safe{Wallet}'s Transaction Builder. Use this when
 *                      the Diamond owner is a Safe / multisig.
 *
 * ─── Run modes ────────────────────────────────────────────────────────────
 * EOA owner — full upgrade in one tx (testnet, or mainnet if owner is an EOA):
 *   forge script script/upgrades/20260518_PythResolutionFacet_UnifiedCreateAndDeferredOpen.s.sol \
 *       --rpc-url $RPC_URL --account deployer --broadcast -vvvv
 *
 * Safe owner — deploy the facet from any hot wallet, get calldata for Safe:
 *   forge script script/upgrades/20260518_PythResolutionFacet_UnifiedCreateAndDeferredOpen.s.sol \
 *       --rpc-url $RPC_URL \
 *       --account <accountName> \
 *       --sender <senderAddress> \
 *       --broadcast \
 *       -vvvv
 *
 *   The console output will print Safe Transaction Builder fields (To/Value/Data).
 *
 * Simulation only — no broadcast (works for either mode):
 *   forge script script/upgrades/20260518_PythResolutionFacet_UnifiedCreateAndDeferredOpen.s.sol \
 *       --rpc-url $RPC_URL --sender <owner-or-safe-addr> -vvvv
 *
 * ─── After broadcast ──────────────────────────────────────────────────────
 *   - Verify the new PythResolutionFacet on the explorer:
 *       forge verify-contract <new-facet-addr> src/facets/PythResolutionFacet.sol:PythResolutionFacet \
 *           --chain <base|base-sepolia> --watch
 *   - Snapshot the deployment:
 *       node script/save-deployment.js <network> v1.3.0 "<notes>" \
 *           --upgrade 20260518_PythResolutionFacet_UnifiedCreateAndDeferredOpen.s.sol
 *   - Smoke-test by creating an immediate market (openTime=0) and resolving it,
 *     and a scheduled market (openTime=now+1h) and resolving that too.
 */
contract UpgradePythResolutionFacet is Script {
    /// @dev The OLD createPriceMarketPyth selector (with `bytes[] pythUpdateData` and
    ///      no `openTime`). Computed inline because the old signature is no longer
    ///      present in the source. Verified via `cast sig`.
    bytes4 internal constant OLD_CREATE_SELECTOR = bytes4(
        keccak256(
            "createPriceMarketPyth(uint256,bytes32,int64,uint256,string[],uint256,address,bytes,uint64,bytes32[],uint256,bytes[])"
        )
    );

    /// @dev Selectors for the staleness admin pair, removed entirely.
    bytes4 internal constant SET_OPEN_MAX_STALENESS_SELECTOR = bytes4(keccak256("setOpenMaxStaleness(uint256)"));
    bytes4 internal constant GET_OPEN_MAX_STALENESS_SELECTOR = bytes4(keccak256("getOpenMaxStaleness()"));

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        bool safeMode = vm.envOr("SAFE_MODE", false);

        vm.startBroadcast();

        // 1. Deploy the new PythResolutionFacet implementation.
        PythResolutionFacet newFacet = new PythResolutionFacet();

        // 2. Build the cuts.
        //    a) Remove: old createPriceMarketPyth, setOpenMaxStaleness, getOpenMaxStaleness.
        //    b) Replace: 4 carried-over selectors point at the new bytecode.
        //    c) Add: new createPriceMarketPyth (different signature → different selector).
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](3);

        bytes4[] memory removeSelectors = new bytes4[](3);
        removeSelectors[0] = OLD_CREATE_SELECTOR;
        removeSelectors[1] = SET_OPEN_MAX_STALENESS_SELECTOR;
        removeSelectors[2] = GET_OPEN_MAX_STALENESS_SELECTOR;
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(0),
            action: IDiamond.FacetCutAction.Remove,
            functionSelectors: removeSelectors
        });

        bytes4[] memory replaceSelectors = new bytes4[](4);
        replaceSelectors[0] = PythResolutionFacet.setPythContract.selector;
        replaceSelectors[1] = PythResolutionFacet.getPythContract.selector;
        replaceSelectors[2] = PythResolutionFacet.resolvePriceMarketPyth.selector;
        replaceSelectors[3] = PythResolutionFacet.markPriceMarketInvalid.selector;
        cuts[1] = IDiamond.FacetCut({
            facetAddress: address(newFacet),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: replaceSelectors
        });

        bytes4[] memory addSelectors = new bytes4[](1);
        addSelectors[0] = PythResolutionFacet.createPriceMarketPyth.selector;
        cuts[2] = IDiamond.FacetCut({
            facetAddress: address(newFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: addSelectors
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
            console.log("New PythResolutionFacet deployed at:", address(newFacet));
            return;
        }

        // 3b. EOA MODE — execute the cut directly. No initializer (no storage migration).
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        vm.stopBroadcast();

        console.log("Diamond cut executed against:", diamond);
        console.log("PythResolutionFacet address: ", address(newFacet));
    }
}

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamond} from "../../src/interfaces/IDiamond.sol";
import {PythResolutionFacet} from "../../src/facets/PythResolutionFacet.sol";

/**
 * @title 20260507 — PythResolutionFacet: Pyth-only price markets + invalidation escape hatch
 * @notice Replaces the existing 6 PythResolutionFacet selectors with a freshly deployed
 *         PythResolutionFacet, and adds the new `markPriceMarketInvalid` selector.
 *
 *         Behaviour change:
 *         - `createPriceMarketPyth` now writes `oracle.reward = 0` for the newly created
 *           market. Price markets do not escrow a UMA reward at creation, so the prior
 *           value (copied from `venue.umaRewardAmount`) would have caused
 *           `LibResolutionService.payStandaloneReward` to revert if a UMA assertion ever
 *           settled on a price market — locking the market and the asserter's bond.
 *           Forcing reward = 0 makes the UMA fallback path a safe no-op (asserter recovers
 *           their bond from UMA, no reward paid out from a balance the Diamond never held).
 *         - New `markPriceMarketInvalid(marketId)` lets anyone invalidate a price market
 *           that never resolved via Pyth, after a 7-day grace period past closeTime. The
 *           market reports payouts = [1, 1] to the CTF, which redeems each YES and each
 *           NO position for half the underlying collateral — a pro-rata refund.
 *
 *         Storage migration: none. No new storage slots, no struct changes, no enum
 *         changes. The 7-day grace period is a constant in the new facet bytecode.
 *
 *         Legacy markets: existing price markets created before this upgrade still have
 *         a non-zero `oracle.reward` stored. The new `markPriceMarketInvalid` path does
 *         not touch `payStandaloneReward`, so they can be invalidated cleanly. A live
 *         UMA assertion on such a legacy market remains the only residual hazard — the
 *         new facet's invalidation refuses to race it. Operators should monitor and let
 *         any outstanding assertion settle (or be disputed) on its own.
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
 *   forge script script/upgrades/20260507_PythResolutionFacet_PythOnlyAndInvalidation.s.sol \
 *       --rpc-url $RPC_URL --account deployer --broadcast -vvvv
 *
 * Safe owner — deploy the facet from any hot wallet, get calldata for Safe:
 * 
 *   forge script script/upgrades/20260506_VenueFacet_RemoveCreationFeeFloor.s.sol \
 *       --rpc-url $RPC_URL \
 *       --account <accountName> \
 *       --sender <senderAddress> \
 *       --broadcast \
 *       -vvvv
 *
 *   The console output will print:
 *     === Safe Transaction Builder ===
 *     To:    <Diamond>
 *     Value: 0
 *     Data:  0x1f931c1c…
 *
 *   Open https://app.safe.global → connect your Safe → Apps → Transaction
 *   Builder. Paste those three fields into a new transaction. Sign with
 *   Trezor (Safe supports Trezor natively). With a 1-of-N threshold the
 *   single sig executes immediately.
 *
 * Simulation only — no broadcast (works for either mode):
 *   forge script script/upgrades/20260507_PythResolutionFacet_PythOnlyAndInvalidation.s.sol \
 *       --rpc-url $RPC_URL --sender <owner-or-safe-addr> -vvvv
 *
 * ─── After broadcast ──────────────────────────────────────────────────────
 *   - Verify the new PythResolutionFacet on the explorer:
 *       forge verify-contract <new-facet-addr> src/facets/PythResolutionFacet.sol:PythResolutionFacet \
 *           --chain <base|base-sepolia> --watch
 *   - Snapshot the deployment:
 *       node script/save-deployment.js <network> v1.2.0 "<notes>" \
 *           --upgrade 20260507_PythResolutionFacet_PythOnlyAndInvalidation.s.sol
 *   - Smoke-test by creating a price market and confirming the on-chain
 *     `MarketOracleData.reward` for that market is 0.
 */
contract UpgradePythResolutionFacet is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        bool safeMode = vm.envOr("SAFE_MODE", false);

        vm.startBroadcast();

        // 1. Deploy the new PythResolutionFacet implementation.
        //    This step is non-privileged and can be broadcast from any EOA.
        PythResolutionFacet newFacet = new PythResolutionFacet();

        // 2. Build the cuts.
        //    a) Replace all 6 pre-existing selectors so they point at the new bytecode
        //       (the reward-zeroing change is inlined into createPriceMarketPyth, and
        //       the doc comments on createPriceMarketPyth and resolvePriceMarketPyth
        //       reflect the new Pyth-only semantics). The list mirrors the
        //       `pythResolutionSelectors` + `setOpenMaxStaleness`/`getOpenMaxStaleness`
        //       block registered by DeployOddMaki.s.sol at facet 19.
        //    b) Add the single new selector `markPriceMarketInvalid`.
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](2);

        // Historical selectors. `setOpenMaxStaleness`, `getOpenMaxStaleness`, and the
        // old `createPriceMarketPyth` (with bytes[] pythUpdateData) were removed from
        // the source in the 2026-05-18 upgrade. Their selectors are inlined as hash
        // literals here so this script — already broadcast — still compiles for
        // historical replay/inspection.
        bytes4[] memory replaceSelectors = new bytes4[](6);
        replaceSelectors[0] = PythResolutionFacet.setPythContract.selector;
        replaceSelectors[1] = PythResolutionFacet.getPythContract.selector;
        replaceSelectors[2] = bytes4(
            keccak256(
                "createPriceMarketPyth(uint256,bytes32,int64,uint256,string[],uint256,address,bytes,uint64,bytes32[],uint256,bytes[])"
            )
        );
        replaceSelectors[3] = PythResolutionFacet.resolvePriceMarketPyth.selector;
        replaceSelectors[4] = bytes4(keccak256("setOpenMaxStaleness(uint256)"));
        replaceSelectors[5] = bytes4(keccak256("getOpenMaxStaleness()"));
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(newFacet),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: replaceSelectors
        });

        bytes4[] memory addSelectors = new bytes4[](1);
        addSelectors[0] = PythResolutionFacet.markPriceMarketInvalid.selector;
        cuts[1] = IDiamond.FacetCut({
            facetAddress: address(newFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: addSelectors
        });

        if (safeMode) {
            // 3a. SAFE MODE — do NOT call diamondCut. Print the calldata so
            //     the operator can submit it via the Safe UI (signed by the
            //     Safe's owners, not by msg.sender of this script).
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
            console.log("Paste the three fields above into the Safe's Transaction Builder app,");
            console.log("then sign with Trezor and execute.");
            return;
        }

        // 3b. EOA MODE — execute the cut directly. No initializer (no storage migration).
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        vm.stopBroadcast();

        console.log("Diamond cut executed against:", diamond);
        console.log("PythResolutionFacet address: ", address(newFacet));
    }
}

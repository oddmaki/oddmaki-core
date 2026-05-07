// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamond} from "../../src/interfaces/IDiamond.sol";
import {VenueFacet} from "../../src/facets/VenueFacet.sol";

/**
 * @title 20260506 — VenueFacet: remove market creation fee floor + add updater
 * @notice Replaces the existing 11 VenueFacet selectors with a freshly deployed VenueFacet
 *         that no longer enforces MIN_MARKET_CREATION_FEE in `validateCreateVenueParams`,
 *         and adds the new `updateVenueMarketCreationFee` selector.
 *
 * Storage migration: none. The VenueData struct is unchanged.
 *
 * ─── Required env ─────────────────────────────────────────────────────────
 *   DIAMOND_ADDRESS  — live OddMaki Diamond proxy on the target network.
 *   SAFE_MODE        — optional. When `true`, the script deploys the new
 *                      VenueFacet but does NOT call diamondCut. Instead it
 *                      prints the calldata for submission via Safe{Wallet}'s
 *                      Transaction Builder. Use this when the Diamond owner
 *                      is a Safe / multisig.
 *
 * ─── Run modes ────────────────────────────────────────────────────────────
 * EOA owner — full upgrade in one tx (testnet, or mainnet if owner is an EOA):
 *   forge script script/upgrades/20260506_VenueFacet_RemoveCreationFeeFloor.s.sol \
 *       --rpc-url $RPC_URL --private-key $OWNER_KEY --broadcast -vvvv
 *
 * Safe owner — deploy the facet from any hot wallet, get calldata for Safe:
 *   SAFE_MODE=true forge script script/upgrades/20260506_VenueFacet_RemoveCreationFeeFloor.s.sol \
 *       --rpc-url $BASE_RPC --private-key $DEPLOY_KEY --broadcast -vvvv
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
 *   forge script script/upgrades/20260506_VenueFacet_RemoveCreationFeeFloor.s.sol \
 *       --rpc-url $RPC_URL --sender <owner-or-safe-addr> -vvvv
 *
 * ─── After broadcast ──────────────────────────────────────────────────────
 *   - Verify the new VenueFacet on the explorer:
 *       forge verify-contract <new-facet-addr> src/facets/VenueFacet.sol:VenueFacet \
 *           --chain <base|base-sepolia> --watch
 *   - Snapshot the deployment:
 *       node script/save-deployment.js <network> v1.1.0 "<notes>" \
 *           --upgrade 20260506_VenueFacet_RemoveCreationFeeFloor.s.sol
 *   - Smoke-test by creating a venue with marketCreationFee = 0.
 */
contract UpgradeVenueFacet is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        bool safeMode = vm.envOr("SAFE_MODE", false);

        vm.startBroadcast();

        // 1. Deploy the new VenueFacet implementation.
        //    This step is non-privileged and can be broadcast from any EOA.
        VenueFacet newVenueFacet = new VenueFacet();

        // 2. Build the cuts.
        //    a) Replace all 11 pre-existing selectors so they point at the new bytecode
        //       (the validator change is inlined into every function in the facet).
        //    b) Add the single new selector `updateVenueMarketCreationFee`.
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](2);

        bytes4[] memory replaceSelectors = new bytes4[](11);
        replaceSelectors[0] = VenueFacet.createVenue.selector;
        replaceSelectors[1] = VenueFacet.updateVenue.selector;
        replaceSelectors[2] = VenueFacet.updateVenueFees.selector;
        replaceSelectors[3] = VenueFacet.updateVenueOracleParams.selector;
        replaceSelectors[4] = VenueFacet.pauseVenue.selector;
        replaceSelectors[5] = VenueFacet.unpauseVenue.selector;
        replaceSelectors[6] = VenueFacet.getVenue.selector;
        replaceSelectors[7] = VenueFacet.getNextVenueId.selector;
        replaceSelectors[8] = VenueFacet.getVenueFees.selector;
        replaceSelectors[9] = VenueFacet.canTrade.selector;
        replaceSelectors[10] = VenueFacet.canCreateMarket.selector;
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(newVenueFacet),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: replaceSelectors
        });

        bytes4[] memory addSelectors = new bytes4[](1);
        addSelectors[0] = VenueFacet.updateVenueMarketCreationFee.selector;
        cuts[1] = IDiamond.FacetCut({
            facetAddress: address(newVenueFacet),
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
            console.log("New VenueFacet deployed at:", address(newVenueFacet));
            console.log("Paste the three fields above into the Safe's Transaction Builder app,");
            console.log("then sign with Trezor and execute.");
            return;
        }

        // 3b. EOA MODE — execute the cut directly. No initializer (no storage migration).
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        vm.stopBroadcast();

        console.log("Diamond cut executed against:", diamond);
        console.log("VenueFacet address:           ", address(newVenueFacet));
    }
}

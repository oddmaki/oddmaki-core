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
 * Required env:
 *   DIAMOND_ADDRESS — the live OddMaki Diamond proxy address on the target network.
 *
 * Run (test simulation):
 *   forge script script/upgrades/20260506_VenueFacet_RemoveCreationFeeFloor.s.sol \
 *       --rpc-url $BASE_SEPOLIA_RPC -vvvv
 *
 * Run (broadcast on testnet):
 *   forge script script/upgrades/20260506_VenueFacet_RemoveCreationFeeFloor.s.sol \
 *       --rpc-url $BASE_SEPOLIA_RPC --broadcast --private-key $OWNER_KEY -vvvv
 *
 * Run (broadcast on mainnet):
 *   forge script script/upgrades/20260506_VenueFacet_RemoveCreationFeeFloor.s.sol \
 *       --rpc-url $BASE_RPC --broadcast --private-key $OWNER_KEY -vvvv
 *
 * After broadcast:
 *   - Verify the new VenueFacet on Basescan (forge verify-contract).
 *   - Update deployments/<network>/<new-version>.json with the new VenueFacet address.
 *   - Smoke-test by creating a venue with marketCreationFee = 0.
 */
contract UpgradeVenueFacet is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");

        vm.startBroadcast();

        // 1. Deploy the new VenueFacet implementation.
        VenueFacet newVenueFacet = new VenueFacet();
        console.log("New VenueFacet deployed at:", address(newVenueFacet));

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

        // 3. Execute the cut. No initializer — there is no storage migration.
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        vm.stopBroadcast();

        console.log("Diamond cut executed against:", diamond);
        console.log("VenueFacet address:           ", address(newVenueFacet));
    }
}

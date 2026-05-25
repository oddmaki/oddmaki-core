// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamond} from "../../src/interfaces/IDiamond.sol";
import {ProtocolFacet} from "../../src/facets/ProtocolFacet.sol";

/**
 * @title 20260523 — ProtocolFacet: remove rescue + moderation surface
 * @notice Removes eight owner-only privileged functions from ProtocolFacet to
 *         shrink the centralization surface area surfaced to auditors and
 *         Blockaid scanners:
 *
 *         Removed selectors (8):
 *           - withdrawETH(address)
 *           - withdrawERC20(address,address,uint256)
 *           - pauseProtocol()
 *           - unpauseProtocol()
 *           - suspendVenue(uint256)
 *           - unsuspendVenue(uint256)
 *           - getProtocolPaused()
 *           - getVenueSuspended(uint256)
 *
 *         Replaced (same selector, new bytecode):
 *           - setProtocolTreasury(address)        / getProtocolTreasury()
 *           - setProtocolFeeBps(uint256)          / getProtocolFeeBps()
 *           - setUmaOracle(address)               / getUmaOracle()
 *           - setUmaIdentifier(bytes32)           / getUmaIdentifier()
 *           - setCollateralWhitelisted(addr,bool) / isCollateralWhitelisted(addr)
 *
 *         Rationale:
 *         - `withdrawETH` and `withdrawERC20` allowed the owner to transfer any
 *           ERC-20 or ETH out of the Diamond. Because the Diamond also serves
 *           as the protocol vault (it holds user USDC collateral and CTF
 *           outcome tokens via direct deposits in LibVaultCollateralService),
 *           these functions were a literal drain switch on user funds.
 *         - `pauseProtocol` / `unpauseProtocol` and `suspendVenue` /
 *           `unsuspendVenue` gave the owner unilateral, uncapped, indefinite
 *           freeze authority over all trading and over individual venues. No
 *           guardian role, no max duration, no time delay.
 *         - The two corresponding view getters are dropped at the same time
 *           since the flags become permanently `false` and the SDK / subgraph
 *           are being updated in lockstep to drop their reads.
 *
 *         Storage migration: none.
 *           LibProtocolStorage.Storage.paused (bool) and
 *           LibProtocolStorage.Storage.venueSuspended (mapping) stay in the
 *           layout — deliberately, to keep diamond storage slot positions
 *           stable. With no setter remaining, both default to `false`
 *           permanently. LibProtocolValidator.requireNotPaused() and
 *           requireVenueNotSuspended() in src/validators/LibProtocolValidator.sol
 *           keep reading those flags as a defensive no-op (revert paths become
 *           unreachable but harmless).
 *
 *         LibProtocolAggregate.setProtocolPaused / setVenueSuspended remain in
 *         the aggregate library as internal-only and unreferenced. Solidity
 *         strips them from any facet bytecode that does not call them, so
 *         there is no bloat. They are left in place to avoid diff churn and
 *         to preserve the option of reintroducing pause/suspend behind a
 *         guardian role + timelock in a future upgrade.
 *
 *         No behaviour change for users: nothing they can do today changes.
 *         The only difference is that the owner can no longer drain the vault,
 *         freeze trading, or suspend a venue from a hot wallet.
 *
 * ─── Required env ─────────────────────────────────────────────────────────
 *   DIAMOND_ADDRESS  — live OddMaki Diamond proxy on the target network.
 *   SAFE_MODE        — optional. When `true`, the script deploys the new
 *                      ProtocolFacet but does NOT call diamondCut. Instead it
 *                      prints the calldata for submission via Safe{Wallet}'s
 *                      Transaction Builder. Use this when the Diamond owner
 *                      is a Safe / multisig.
 *
 * ─── Run modes ────────────────────────────────────────────────────────────
 * EOA owner — full upgrade in one tx (testnet, or mainnet if owner is an EOA):
 *   forge script script/upgrades/20260523_ProtocolFacet_RemoveRescueAndModeration.s.sol \
 *       --rpc-url $RPC_URL --account deployer --broadcast -vvvv
 *
 * Safe owner — deploy the facet from any hot wallet, get calldata for Safe:
 *   forge script script/upgrades/20260523_ProtocolFacet_RemoveRescueAndModeration.s.sol \
 *       --rpc-url $RPC_URL \
 *       --account <accountName> \
 *       --sender <senderAddress> \
 *       --broadcast \
 *       -vvvv
 *
 *   The console output will print Safe Transaction Builder fields (To/Value/Data).
 *
 * Simulation only — no broadcast (works for either mode):
 *   forge script script/upgrades/20260523_ProtocolFacet_RemoveRescueAndModeration.s.sol \
 *       --rpc-url $RPC_URL --sender <owner-or-safe-addr> -vvvv
 *
 * ─── After broadcast ──────────────────────────────────────────────────────
 *   - Verify the new ProtocolFacet on the explorer:
 *       forge verify-contract <new-facet-addr> src/facets/ProtocolFacet.sol:ProtocolFacet \
 *           --chain <base|base-sepolia> --watch
 *   - Snapshot the deployment:
 *       node script/save-deployment.js <network> v1.4.0 "<notes>" \
 *           --upgrade 20260523_ProtocolFacet_RemoveRescueAndModeration.s.sol
 *   - Confirm with the loupe that the 8 removed selectors revert with
 *     FunctionNotFound:
 *       cast call $DIAMOND "facetAddress(bytes4)(address)" 0xf4e0d9ac --rpc-url $RPC_URL # withdrawETH
 *     (expect: 0x0000000000000000000000000000000000000000)
 */
contract UpgradeProtocolFacetRemoveRescueAndModeration is Script {
    // Removed-selector signatures — computed inline because the source no
    // longer contains these functions. Verified via `cast sig`.
    bytes4 internal constant WITHDRAW_ETH_SELECTOR        = bytes4(keccak256("withdrawETH(address)"));
    bytes4 internal constant WITHDRAW_ERC20_SELECTOR      = bytes4(keccak256("withdrawERC20(address,address,uint256)"));
    bytes4 internal constant PAUSE_PROTOCOL_SELECTOR      = bytes4(keccak256("pauseProtocol()"));
    bytes4 internal constant UNPAUSE_PROTOCOL_SELECTOR    = bytes4(keccak256("unpauseProtocol()"));
    bytes4 internal constant SUSPEND_VENUE_SELECTOR       = bytes4(keccak256("suspendVenue(uint256)"));
    bytes4 internal constant UNSUSPEND_VENUE_SELECTOR     = bytes4(keccak256("unsuspendVenue(uint256)"));
    bytes4 internal constant GET_PROTOCOL_PAUSED_SELECTOR = bytes4(keccak256("getProtocolPaused()"));
    bytes4 internal constant GET_VENUE_SUSPENDED_SELECTOR = bytes4(keccak256("getVenueSuspended(uint256)"));

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        bool safeMode = vm.envOr("SAFE_MODE", false);

        vm.startBroadcast();

        // 1. Deploy the new (slimmed-down) ProtocolFacet.
        ProtocolFacet newFacet = new ProtocolFacet();

        // 2. Build the cuts.
        //    a) Remove: 8 dropped selectors.
        //    b) Replace: 10 surviving selectors point at the new bytecode.
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](2);

        bytes4[] memory removeSelectors = new bytes4[](8);
        removeSelectors[0] = WITHDRAW_ETH_SELECTOR;
        removeSelectors[1] = WITHDRAW_ERC20_SELECTOR;
        removeSelectors[2] = PAUSE_PROTOCOL_SELECTOR;
        removeSelectors[3] = UNPAUSE_PROTOCOL_SELECTOR;
        removeSelectors[4] = SUSPEND_VENUE_SELECTOR;
        removeSelectors[5] = UNSUSPEND_VENUE_SELECTOR;
        removeSelectors[6] = GET_PROTOCOL_PAUSED_SELECTOR;
        removeSelectors[7] = GET_VENUE_SUSPENDED_SELECTOR;
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(0),
            action: IDiamond.FacetCutAction.Remove,
            functionSelectors: removeSelectors
        });

        bytes4[] memory replaceSelectors = new bytes4[](10);
        replaceSelectors[0] = ProtocolFacet.setProtocolTreasury.selector;
        replaceSelectors[1] = ProtocolFacet.getProtocolTreasury.selector;
        replaceSelectors[2] = ProtocolFacet.setProtocolFeeBps.selector;
        replaceSelectors[3] = ProtocolFacet.getProtocolFeeBps.selector;
        replaceSelectors[4] = ProtocolFacet.setUmaOracle.selector;
        replaceSelectors[5] = ProtocolFacet.getUmaOracle.selector;
        replaceSelectors[6] = ProtocolFacet.setUmaIdentifier.selector;
        replaceSelectors[7] = ProtocolFacet.getUmaIdentifier.selector;
        replaceSelectors[8] = ProtocolFacet.setCollateralWhitelisted.selector;
        replaceSelectors[9] = ProtocolFacet.isCollateralWhitelisted.selector;
        cuts[1] = IDiamond.FacetCut({
            facetAddress: address(newFacet),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: replaceSelectors
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
            console.log("New ProtocolFacet deployed at:", address(newFacet));
            return;
        }

        // 3b. EOA MODE — execute the cut directly. No initializer (no storage migration).
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        vm.stopBroadcast();

        console.log("Diamond cut executed against:", diamond);
        console.log("ProtocolFacet new address:   ", address(newFacet));
    }
}

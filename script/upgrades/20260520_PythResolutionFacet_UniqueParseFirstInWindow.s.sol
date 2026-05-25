// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamond} from "../../src/interfaces/IDiamond.sol";
import {PythResolutionFacet} from "../../src/facets/PythResolutionFacet.sol";

/**
 * @title 20260520 — PythResolutionFacet: first-in-window VAA selection via parsePriceFeedUpdatesUnique
 * @notice Replaces the existing PythResolutionFacet with a freshly deployed one
 *         whose price selection is hardened against an outcome-manipulation vector
 *         in the prior implementation.
 *
 *         Behaviour change:
 *         - Prior `LibPriceMarketService.pickEarliestInWindow` picked the earliest
 *           publishTime among the *submitted* VAAs. The protocol had no on-chain
 *           way to verify the caller had included every valid Pyth VAA in the
 *           window, so a resolver could omit an earlier in-window VAA whose price
 *           favored the opposite outcome and submit only a later one.
 *         - The replacement `pickFirstInWindow` calls
 *           `IPythExtended.parsePriceFeedUpdatesUnique`, which enforces that the
 *           submitted VAA's signed `prevPublishTime` is strictly less than
 *           `minPublishTime`. Any later in-window VAA has a `prevPublishTime`
 *           that falls inside the window and is rejected by Pyth. The selected
 *           price is therefore deterministic per `(feed, window)` regardless of
 *           which VAAs the caller submits or in what order.
 *         - For deferred Up/Down markets, the open and close windows are each
 *           resolved the same way; the resolver may still submit both windows'
 *           VAAs in a single array.
 *
 *         Diamond cut shape: all 5 PythResolutionFacet selectors are Replace-ed
 *         with the new facet bytecode. No selectors are added or removed:
 *
 *         Replaced (same selector, new bytecode):
 *           - setPythContract(address)
 *           - getPythContract()
 *           - createPriceMarketPyth(uint256,bytes32,int64,uint256,uint256,string[],
 *                                   uint256,address,bytes,uint64,bytes32[],uint256)
 *           - resolvePriceMarketPyth(uint256,bytes[])
 *           - markPriceMarketInvalid(uint256)
 *
 *         `LibPriceMarketService` is internal-linked into the facet at compile
 *         time, so the only on-chain artefact is the new facet contract. The
 *         five surviving selectors get re-pointed at it.
 *
 *         Storage migration: none. No new storage slots, no struct changes.
 *
 *         Dependency assumption: the configured Pyth oracle MUST implement
 *         `parsePriceFeedUpdatesUnique` (pyth-sdk-solidity v3+ ABI). The
 *         deployed Pyth contracts on Base mainnet (0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a)
 *         and Base Sepolia (0xA2aa501b19aff244D90cc15a4Cf739D2725B5729) both
 *         support it. Validated via the fork test in
 *         `test/fork/PythUniqueValidation.fork.t.sol` against Base Sepolia.
 *
 *         Legacy markets: existing price markets created before this upgrade
 *         resolve through the same selector and inherit the new selection
 *         behaviour automatically. A market created with the old facet that has
 *         not yet resolved will, after this cut, require an HONEST submission
 *         (the first-in-window VAA included). If only later VAAs are available
 *         from Hermes for that window, resolution reverts with
 *         `NoClosePriceInWindow` / `NoOpenPriceInWindow` and the market routes
 *         through `markPriceMarketInvalid` after the 7-day grace.
 *
 *         No downstream consumer changes: the facet ABI is unchanged, only the
 *         selection invariant is tighter. SDK / subgraph / dApps need no edits.
 *
 * ─── Required env ─────────────────────────────────────────────────────────
 *   DIAMOND_ADDRESS  — live OddMaki Diamond proxy on the target network.
 *                      Already set in `.env` for testnet and `.env.mainnet`.
 *   SAFE_MODE        — optional. When `true`, the script deploys the new
 *                      PythResolutionFacet but does NOT call diamondCut.
 *                      Instead it prints the calldata for submission via
 *                      Safe{Wallet}'s Transaction Builder. Used for mainnet
 *                      where the Diamond owner is a Safe; already set in
 *                      `.env.mainnet`.
 *
 * ─── Run modes ────────────────────────────────────────────────────────────
 * Testnet (Base Sepolia) — EOA owner, broadcast directly with the `deployer` key:
 *   source .env
 *   forge script script/upgrades/20260520_PythResolutionFacet_UniqueParseFirstInWindow.s.sol \
 *       --rpc-url $RPC_URL --account deployer --broadcast -vvvv
 *
 * Mainnet (Base) — Safe owner, deploy the facet from `deployer-mainnet` and
 * print Safe Transaction Builder calldata for the diamondCut:
 *   source .env.mainnet      # exports DIAMOND_ADDRESS and SAFE_MODE=true
 *   forge script script/upgrades/20260520_PythResolutionFacet_UniqueParseFirstInWindow.s.sol \
 *       --rpc-url $RPC_URL \
 *       --account deployer-mainnet \
 *       --sender <deployer-mainnet-address> \
 *       --broadcast \
 *       -vvvv
 *
 *   Console output prints To / Value / Data fields for the Safe UI.
 *
 * Simulation only — no broadcast (works for either mode):
 *   forge script script/upgrades/20260520_PythResolutionFacet_UniqueParseFirstInWindow.s.sol \
 *       --rpc-url $RPC_URL --sender <owner-or-safe-addr> -vvvv
 *
 * ─── Pre-flight (recommended) ─────────────────────────────────────────────
 *   - Run the fork validation against the target chain's Pyth deployment to
 *     confirm `parsePriceFeedUpdatesUnique` is wired up the way the new facet
 *     expects:
 *       PYTH_FORK_TEST=1 BASE_SEPOLIA_RPC=$RPC_URL \
 *           forge test --ffi --mc PythUniqueValidationForkTest -vv
 *     (point `BASE_SEPOLIA_RPC` at the mainnet RPC when validating mainnet —
 *     the Pyth address constant in the test must be updated first if doing so).
 *   - `forge build` and `forge test` to confirm a clean local build.
 *
 * ─── After broadcast ──────────────────────────────────────────────────────
 *   - Verify the new PythResolutionFacet on the explorer:
 *       forge verify-contract <new-facet-addr> src/facets/PythResolutionFacet.sol:PythResolutionFacet \
 *           --chain <base|base-sepolia> --watch
 *   - Snapshot the deployment:
 *       node script/save-deployment.js <network> <version> "<notes>" \
 *           --upgrade 20260520_PythResolutionFacet_UniqueParseFirstInWindow.s.sol
 *   - Loupe check — confirm the 5 selectors now point at the new facet:
 *       cast call $DIAMOND_ADDRESS "facetAddress(bytes4)(address)" \
 *           $(cast sig "resolvePriceMarketPyth(uint256,bytes[])") --rpc-url $RPC_URL
 *     Expect: the address printed in this script's output.
 *   - Smoke-test on testnet by resolving a small strike market end-to-end.
 */
contract UpgradePythResolutionFacetUniqueParse is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        bool safeMode = vm.envOr("SAFE_MODE", false);

        vm.startBroadcast();

        // 1. Deploy the new PythResolutionFacet implementation. The new
        //    `LibPriceMarketService` is internal-linked at compile time, so this
        //    is the only on-chain artefact produced by the upgrade.
        PythResolutionFacet newFacet = new PythResolutionFacet();

        // 2. Build the cut. Single FacetCut entry: Replace all 5 surviving
        //    selectors so they point at the new bytecode.
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](1);

        bytes4[] memory replaceSelectors = new bytes4[](5);
        replaceSelectors[0] = PythResolutionFacet.setPythContract.selector;
        replaceSelectors[1] = PythResolutionFacet.getPythContract.selector;
        replaceSelectors[2] = PythResolutionFacet.createPriceMarketPyth.selector;
        replaceSelectors[3] = PythResolutionFacet.resolvePriceMarketPyth.selector;
        replaceSelectors[4] = PythResolutionFacet.markPriceMarketInvalid.selector;
        cuts[0] = IDiamond.FacetCut({
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

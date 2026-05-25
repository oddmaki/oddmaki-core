// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPythExtended} from "../../src/interfaces/IPythExtended.sol";
import {PythStructs} from "lib/pyth-sdk-solidity/PythStructs.sol";

/**
 * @title Pyth parsePriceFeedUpdatesUnique fork validation
 * @notice Validates that the live Pyth deployment on Base Sepolia exposes
 *         `parsePriceFeedUpdatesUnique` with the ABI declared in
 *         `IPythExtended` and that its behavior matches the assumption
 *         `LibPriceMarketService.pickFirstInWindow` is built on:
 *
 *           1. A legitimate first-in-window VAA is accepted.
 *           2. A later in-window VAA submitted alone is rejected because its
 *              signed `prevPublishTime` falls inside the queried window.
 *           3. A submission carrying both the later and the first VAA succeeds
 *              regardless of array order and returns the first-in-window data.
 *
 *         The test is gated by `PYTH_FORK_TEST=1` so it does not run as part of
 *         the default `forge test` suite. It also needs an RPC endpoint and
 *         FFI (the test pulls real VAAs from Hermes via `curl`+`jq`).
 *
 *         Run with:
 *           PYTH_FORK_TEST=1 BASE_SEPOLIA_RPC=https://... \
 *             forge test --ffi --mc PythUniqueValidationForkTest -vv
 */
contract PythUniqueValidationForkTest is Test {
    /// @dev Pyth pull-oracle deployment on Base Sepolia.
    address constant PYTH_BASE_SEPOLIA = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;
    /// @dev ETH/USD feed id (the same across all Pyth deployments).
    bytes32 constant ETH_USD_FEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    /// @dev How far behind block.timestamp to anchor the test window. Hermes
    ///      keeps recent VAAs available; 5 minutes is comfortably in range.
    uint64 constant ANCHOR_OFFSET = 300;
    /// @dev Gap between the first and the later VAA we submit.
    uint64 constant GAP_SECONDS = 30;
    /// @dev Resolution window we ask `parsePriceFeedUpdatesUnique` to enforce.
    uint64 constant WINDOW_SECONDS = 60;

    IPythExtended pyth;

    function setUp() public {
        if (!vm.envOr("PYTH_FORK_TEST", false)) {
            vm.skip(true);
            return;
        }
        string memory rpc = vm.envString("BASE_SEPOLIA_RPC");
        vm.createSelectFork(rpc);
        pyth = IPythExtended(PYTH_BASE_SEPOLIA);
    }

    // ---- 1. First-in-window VAA is accepted ----

    function test_acceptsFirstInWindowVaa() public {
        uint64 anchor = uint64(block.timestamp) - ANCHOR_OFFSET;
        (bytes memory vaaFirst, uint64 firstPub) = _fetchVaa(anchor);

        bytes[] memory data = new bytes[](1);
        data[0] = vaaFirst;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ETH_USD_FEED;

        uint256 fee = pyth.getUpdateFee(data);
        PythStructs.PriceFeed[] memory feeds = pyth.parsePriceFeedUpdatesUnique{value: fee}(
            data, ids, firstPub, firstPub + WINDOW_SECONDS
        );

        assertEq(feeds.length, 1);
        assertEq(feeds[0].id, ETH_USD_FEED);
        assertEq(uint64(feeds[0].price.publishTime), firstPub);
    }

    // ---- 2. Later VAA submitted alone is rejected (the cheat path) ----

    function test_rejectsLaterVaaSubmittedAlone() public {
        uint64 anchor = uint64(block.timestamp) - ANCHOR_OFFSET;
        (, uint64 firstPub) = _fetchVaa(anchor);
        (bytes memory vaaLater, uint64 laterPub) = _fetchVaa(firstPub + GAP_SECONDS);

        // Sanity: the later VAA must sit strictly after the first AND still
        // inside the window we will query. If Hermes returned the same
        // publishTime twice the test is meaningless — skip rather than pass.
        if (laterPub <= firstPub || laterPub > firstPub + WINDOW_SECONDS) {
            vm.skip(true);
            return;
        }

        bytes[] memory data = new bytes[](1);
        data[0] = vaaLater;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ETH_USD_FEED;

        uint256 fee = pyth.getUpdateFee(data);
        // The later VAA's signed `prevPublishTime` is inside [firstPub, firstPub + WINDOW],
        // so the unique-parse check must reject it. We don't assert a specific
        // error selector because Pyth's error surface has shifted across versions;
        // a plain revert is sufficient evidence the check fired.
        vm.expectRevert();
        pyth.parsePriceFeedUpdatesUnique{value: fee}(
            data, ids, firstPub, firstPub + WINDOW_SECONDS
        );
    }

    // ---- 3. Both VAAs submitted (adversarial order) → first wins ----

    function test_acceptsBothVaasInAdversarialOrder() public {
        uint64 anchor = uint64(block.timestamp) - ANCHOR_OFFSET;
        (bytes memory vaaFirst, uint64 firstPub) = _fetchVaa(anchor);
        (bytes memory vaaLater, uint64 laterPub) = _fetchVaa(firstPub + GAP_SECONDS);

        if (laterPub <= firstPub || laterPub > firstPub + WINDOW_SECONDS) {
            vm.skip(true);
            return;
        }

        // Later VAA first in the array, first VAA second. The unique-parse
        // call must still return the first-in-window VAA's data.
        bytes[] memory data = new bytes[](2);
        data[0] = vaaLater;
        data[1] = vaaFirst;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ETH_USD_FEED;

        uint256 fee = pyth.getUpdateFee(data);
        PythStructs.PriceFeed[] memory feeds = pyth.parsePriceFeedUpdatesUnique{value: fee}(
            data, ids, firstPub, firstPub + WINDOW_SECONDS
        );

        assertEq(feeds.length, 1);
        assertEq(uint64(feeds[0].price.publishTime), firstPub, "first-in-window VAA must drive selection");
    }

    // ---- Hermes fetcher (FFI) ----

    /// @dev Fetches the price update from Hermes whose publishTime is at-or-just-
    ///      after `ts`. Returns `(vaa, publishTime)`.
    function _fetchVaa(uint64 ts) internal returns (bytes memory vaa, uint64 publishTime) {
        string memory feedHex = _bytes32ToHex(ETH_USD_FEED);
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat(
            "curl -sS 'https://hermes.pyth.network/v2/updates/price/",
            vm.toString(uint256(ts)),
            "?ids%5B%5D=",
            feedHex,
            "&encoding=hex'",
            " | jq -r '\"0x\" + .binary.data[0] + \" \" + (.parsed[0].price.publish_time|tostring)'"
        );
        bytes memory raw = vm.ffi(cmd);
        string[] memory parts = vm.split(string(raw), " ");
        require(parts.length == 2, "hermes: bad response");
        vaa = vm.parseBytes(parts[0]);
        publishTime = uint64(vm.parseUint(parts[1]));
    }

    function _bytes32ToHex(bytes32 v) internal pure returns (string memory) {
        bytes memory chars = "0123456789abcdef";
        bytes memory out = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            uint8 b = uint8(v[i]);
            out[i * 2] = chars[b >> 4];
            out[i * 2 + 1] = chars[b & 0x0f];
        }
        return string(out);
    }
}

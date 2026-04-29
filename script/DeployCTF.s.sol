// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/// @title Deploy ConditionalTokens
/// @notice Deploy Gnosis ConditionalTokens using raw bytecode
/// @dev ConditionalTokens is Solidity 0.5.1, so we deploy via bytecode
contract DeployCTFScript is Script {
    function run() external returns (address) {
        vm.startBroadcast();

        // Read the bytecode string from the compiled artifact
        string memory artifactPath = "out/ConditionalTokens.sol/ConditionalTokens.json";
        // forge-lint: disable-next-line(unsafe-cheatcode) -- reading local artifact for CTF deployment
        string memory artifact = vm.readFile(artifactPath);

        // Parse as string first, then convert to bytes
        string memory bytecodeHex = abi.decode(vm.parseJson(artifact, ".bytecode.object"), (string));

        // Remove "0x" prefix if present and convert to bytes
        bytes memory bytecode;
        if (bytes(bytecodeHex).length > 2 && bytes(bytecodeHex)[0] == "0" && bytes(bytecodeHex)[1] == "x") {
            bytecode = vm.parseBytes(bytecodeHex);
        } else {
            bytecode = bytes(bytecodeHex);
        }

        require(bytecode.length > 0, "Bytecode is empty");

        // Deploy using create
        address ctf;
        assembly {
            ctf := create(0, add(bytecode, 0x20), mload(bytecode))
        }

        require(ctf != address(0), "ConditionalTokens deployment failed");

        console.log("ConditionalTokens deployed to:", ctf);

        vm.stopBroadcast();

        return ctf;
    }
}

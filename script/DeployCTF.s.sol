// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/// @title Deploy ConditionalTokens
/// @notice Deploy Gnosis ConditionalTokens using raw bytecode
/// @dev ConditionalTokens is Solidity 0.5.x, incompatible with the project's
///      0.8.28 + via_ir profile, so we deploy by reading its compiled bytecode.
///      The artifact at out/ConditionalTokens.sol/ConditionalTokens.json is NOT
///      produced by the regular `forge build` (nothing in src/ imports the
///      concrete contract — only IConditionalTokens.sol). Compile it explicitly
///      before running this script:
///
///          forge build lib/conditional-tokens-contracts/contracts/ConditionalTokens.sol
///
///      Forge auto-detects solc 0.5.x for that file (the project's via_ir/0.8.28
///      pins only apply to its own src/ pass) and emits the artifact at the
///      expected out/ path.
///
///      Then run the deploy (no `--verify` — see VERIFICATION below):
///
///          forge script script/DeployCTF.s.sol:DeployCTFScript \
///            --rpc-url $RPC_URL \
///            --account deployer-mainnet \
///            --sender $(cast wallet address --account deployer-mainnet) \
///            --broadcast
///
///      Record the returned address — pass it as CTF_ADDRESS to the Diamond deploy.
///
///      VERIFICATION:
///      `forge script ... --verify` will silently skip this contract because it's
///      deployed via raw `create` from bytecode, so forge can't tie the address to
///      a build artifact. `forge verify-contract --flatten` also fails — forge's
///      flattener can't parse Solidity 0.5.x. Verify manually on Basescan via the
///      Standard JSON Input flow:
///
///        1. Generate the standard JSON input from the artifact (rebuilds the
///           exact compiler input forge used, including the OZ remapping):
///
///             python3 - <<'PY'
///             import json
///             art = json.load(open('out/ConditionalTokens.sol/ConditionalTokens.json'))
///             sources = {p: {'content': open(p).read()} for p in art['metadata']['sources']}
///             json.dump({
///                 'language': 'Solidity',
///                 'sources': sources,
///                 'settings': {
///                     'optimizer': {'enabled': True, 'runs': 200},
///                     'evmVersion': art['metadata']['settings'].get('evmVersion', 'istanbul'),
///                     'remappings': ['openzeppelin-solidity/=lib/openzeppelin-solidity/'],
///                     'outputSelection': {'*': {'*': ['abi','evm.bytecode','evm.deployedBytecode','metadata']}},
///                 },
///             }, open('out/ConditionalTokens.standard-input.json', 'w'))
///             PY
///
///        2. On the deployed address page on Basescan, click Verify and Publish:
///             - Compiler Type: Solidity (Standard-Json-Input)
///             - Compiler Version: v0.5.17+commit.d19bba13
///             - License: LGPL-3.0
///             - Upload: out/ConditionalTokens.standard-input.json
///             - Constructor Arguments: (empty)
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

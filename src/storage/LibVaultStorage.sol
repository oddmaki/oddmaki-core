// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title LibVaultStorage
 * @notice Vault domain: CTF address, condition routing (needsWrapping).
 * Tokens are held by the Diamond (address(this) in delegatecall). Read-only accessors here.
 */
library LibVaultStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.vault");

    struct Storage {
        address ctf;
        mapping(bytes32 => bool) needsWrapping; // conditionId => needsWrapping
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function getCtf() internal view returns (address) {
        return getStorage().ctf;
    }

    function needsWrapping(bytes32 conditionId) internal view returns (bool) {
        return getStorage().needsWrapping[conditionId];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibVaultStorage} from "../storage/LibVaultStorage.sol";

/**
 * @title LibVaultAggregate
 * @notice Vault storage writes only: ctf, needsWrapping.
 * Token movements and CTF/adapter calls live in vault services (LibVaultCollateralService, etc.).
 */
library LibVaultAggregate {
    /// @notice One-time CTF initialization. Reverts if CTF is already set (H-06 fix).
    ///         Locks tokenisation to a single ERC-1155 so existing positions cannot be
    ///         repointed to an attacker-controlled contract post-deploy.
    function setCtf(address ctf) internal {
        require(ctf != address(0), "Invalid ctf");
        require(LibVaultStorage.getStorage().ctf == address(0), "ctf already set");
        LibVaultStorage.getStorage().ctf = ctf;
    }

    function setNeedsWrapping(bytes32 conditionId, bool needsWrapping) internal {
        LibVaultStorage.getStorage().needsWrapping[conditionId] = needsWrapping;
    }
}

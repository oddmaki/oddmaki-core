// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibVaultStorage} from "../storage/LibVaultStorage.sol";

/**
 * @title LibVaultAggregate
 * @notice Vault storage writes only: ctf, needsWrapping.
 * Token movements and CTF/adapter calls live in vault services (LibVaultCollateralService, etc.).
 */
library LibVaultAggregate {
    function setCtf(address ctf) internal {
        require(ctf != address(0), "Invalid ctf");
        LibVaultStorage.getStorage().ctf = ctf;
    }

    function setNeedsWrapping(bytes32 conditionId, bool needsWrapping) internal {
        LibVaultStorage.getStorage().needsWrapping[conditionId] = needsWrapping;
    }
}

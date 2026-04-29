// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibVaultStorage} from "../storage/LibVaultStorage.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";

/**
 * @title LibVaultOutcomeTokenService
 * @notice Outcome token (ERC1155) movements: deposit to Diamond, withdraw from Diamond, transfer from Diamond.
 * Reads ctf from LibVaultStorage; no vault storage mutation.
 */
library LibVaultOutcomeTokenService {
    function depositOutcomeTokens(uint256 positionId, address from, uint256 amount) internal {
        address ctf = LibVaultStorage.getCtf();
        require(ctf != address(0), "Vault: ctf not set");
        TransferHelper._transferFromErc1155(ctf, from, address(this), positionId, amount);
    }

    function withdrawOutcomeTokens(uint256 positionId, address to, uint256 amount) internal {
        address ctf = LibVaultStorage.getCtf();
        require(ctf != address(0), "Vault: ctf not set");
        TransferHelper._transferFromErc1155(ctf, address(this), to, positionId, amount);
    }

    function transferOutcomeTokens(uint256 positionId, address to, uint256 amount) internal {
        address ctf = LibVaultStorage.getCtf();
        require(ctf != address(0), "Vault: ctf not set");
        TransferHelper._transferFromErc1155(ctf, address(this), to, positionId, amount);
    }
}

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {TransferHelper} from "../libraries/TransferHelper.sol";

/**
 * @title LibVaultCollateralService
 * @notice Collateral (ERC20) movements: deposit to Diamond, withdraw from Diamond, transfer from Diamond.
 * No vault storage mutation; Diamond holds tokens at address(this).
 */
library LibVaultCollateralService {
    function depositCollateral(address token, address from, uint256 amount) internal {
        TransferHelper._transferFromErc20(token, from, address(this), amount);
    }

    function withdrawCollateral(address token, address to, uint256 amount) internal {
        TransferHelper._transferErc20(token, to, amount);
    }

    function transferCollateral(address token, address to, uint256 amount) internal {
        TransferHelper._transferErc20(token, to, amount);
    }
}

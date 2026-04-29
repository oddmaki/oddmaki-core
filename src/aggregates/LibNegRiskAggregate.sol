// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibNegRiskStorage} from "../storage/LibNegRiskStorage.sol";
import {WrappedCollateralToken} from "../tokens/WrappedCollateralToken.sol";

/**
 * @title LibNegRiskAggregate
 * @notice NegRisk domain writes: register wrapped collateral (deploy + store). Idempotent.
 */
library LibNegRiskAggregate {
    event WrappedCollateralRegistered(address indexed underlyingCollateral, address indexed wrappedCollateral);

    function registerWrappedCollateral(address underlying) internal returns (address wrapped) {
        if (underlying == address(0)) revert InvalidAddress();
        LibNegRiskStorage.Storage storage s = LibNegRiskStorage.getStorage();
        wrapped = s.wrappedCollaterals[underlying];
        if (wrapped != address(0)) return wrapped;

        WrappedCollateralToken wc = new WrappedCollateralToken(
            underlying,
            address(this),
            "Wrapped Collateral",
            "wCOL"
        );
        wrapped = address(wc);
        s.wrappedCollaterals[underlying] = wrapped;
        emit WrappedCollateralRegistered(underlying, wrapped);
        return wrapped;
    }

    error InvalidAddress();
}

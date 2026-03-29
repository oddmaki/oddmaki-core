// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibNegRiskAggregate} from "../aggregates/LibNegRiskAggregate.sol";
import {LibNegRiskStorage} from "../storage/LibNegRiskStorage.sol";

/**
 * @title LibNegRiskRegistrationService
 * @notice NegRisk registration only: ensure wrapped collateral exists, return its address.
 *        Vault registration uses this when needsWrapping; no split/merge/convert here.
 */
library LibNegRiskRegistrationService {
    function registerWrappedCollateral(address underlying) internal returns (address wrapped) {
        return LibNegRiskAggregate.registerWrappedCollateral(underlying);
    }

    function getWrappedCollateral(address underlying) internal view returns (address) {
        address wrapped = LibNegRiskStorage.getWrappedCollateral(underlying);
        require(wrapped != address(0), "NegRisk: wrapped not registered");
        return wrapped;
    }

    function hasWrappedCollateral(address underlying) internal view returns (bool) {
        return LibNegRiskStorage.hasWrappedCollateral(underlying);
    }
}

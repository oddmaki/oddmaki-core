// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {LibVaultStorage} from "../storage/LibVaultStorage.sol";
import {IConditionalTokens} from "../interfaces/IConditionalTokens.sol";

/**
 * @title LibDpmResolutionService
 * @notice Reads the resolved winner for a DPM market. DPM has no resolve function of its own — it
 *         reads the outcome the shared UMA / Pyth resolution paths wrote to the CTF payout numerators.
 *         Isolated from the claim saga so the oracle-read dependency lives in one place.
 */
library LibDpmResolutionService {
    /// @notice Classify a resolved market's CTF payout numerators.
    /// @return hasWinner true iff exactly one outcome has a non-zero numerator (a clean winner).
    /// @return winner    the winning outcome index when `hasWinner`; 0 otherwise. A zero or
    ///                   more-than-one non-zero count (e.g. [1,1]) is invalid / split.
    function winningOutcome(uint256 marketId, uint256 outcomeCount)
        internal
        view
        returns (bool hasWinner, uint256 winner)
    {
        bytes32 conditionId = LibMarketOracleStorage.getMarketOracleData(
            LibMarketRegistryStorage.getMarketRegistryData(marketId).questionId
        ).conditionId;
        IConditionalTokens ctf = IConditionalTokens(LibVaultStorage.getCtf());

        uint256 nonZero;
        for (uint256 i = 0; i < outcomeCount; i++) {
            if (ctf.payoutNumerators(conditionId, i) != 0) {
                nonZero++;
                winner = i;
            }
        }
        hasWinner = (nonZero == 1);
        if (!hasWinner) winner = 0;
    }
}

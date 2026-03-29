// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Side} from "./Types.sol";

/// @notice Input parameters for a single order within a batch operation.
struct BatchOrderParams {
    uint256 outcomeId; // 0 = YES, 1 = NO
    Side side; // BUY or SELL
    uint256 tick; // Price level in ticks (1 to 1e18/tickSize)
    uint256 qty; // Number of outcome tokens
    uint256 expiry; // Unix timestamp, 0 = no expiration
}

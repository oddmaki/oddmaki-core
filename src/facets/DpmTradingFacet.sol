// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibDpmService} from "../services/LibDpmService.sol";

/**
 * @title DpmTradingFacet
 * @author OddMaki Protocol
 * @notice Trading entry points for DPM (Dynamic Pari-Mutuel) markets — Pennock 2004 §4 ("DPM I"):
 *         intent enter/exit, dynamic enter, and claim. Creation and views live in DpmMarketFacet;
 *         the split keeps each facet well under the 24KB code-size limit with headroom for the
 *         N-outcome group variant still to come.
 *
 *         Thin wrappers: every lifecycle guard, pricing, fee, and accounting step lives in
 *         LibDpmService. The facet contributes the diamond `nonReentrant` boundary and indexing
 *         events. All four mutators move collateral and are `nonReentrant`; LibDpmService follows
 *         effects-before-interaction (state written before any external transfer).
 */
contract DpmTradingFacet is ReentrancyGuard {
    event DpmIntentEntered(uint256 indexed marketId, address indexed user, uint256 outcome, uint256 amount);
    event DpmIntentExited(uint256 indexed marketId, address indexed user, uint256 outcome, uint256 amount);
    event DpmEntered(uint256 indexed marketId, address indexed user, uint256 outcome, uint256 amount, uint256 shares);
    event DpmClaimed(uint256 indexed marketId, address indexed user, uint256 payout);

    /// @notice Deposit a 1:1 refundable intent stake before openTime (no fee, no pricing).
    function enterIntent(uint256 marketId, uint256 outcome, uint256 amount) external nonReentrant {
        LibDpmService.enterIntent(msg.sender, marketId, outcome, amount);
        emit DpmIntentEntered(marketId, msg.sender, outcome, amount);
    }

    /// @notice Withdraw a refundable intent stake before openTime (1:1).
    function exitIntent(uint256 marketId, uint256 outcome, uint256 amount) external nonReentrant {
        LibDpmService.exitIntent(msg.sender, marketId, outcome, amount);
        emit DpmIntentExited(marketId, msg.sender, outcome, amount);
    }

    /// @notice Enter the dynamic pool (openTime <= now < closeTime). Charges the entry fee and
    ///         buys shares at the Pennock price. Returns the shares minted.
    function enter(uint256 marketId, uint256 outcome, uint256 amount)
        external
        nonReentrant
        returns (uint256 shares)
    {
        shares = LibDpmService.enter(msg.sender, marketId, outcome, amount);
        emit DpmEntered(marketId, msg.sender, outcome, amount, shares);
    }

    /// @notice Claim a resolved market's payout (DPM I: refund of price paid + losers'-pool slice;
    ///         full refund on invalid / no-contest). Returns the collateral paid out.
    function claim(uint256 marketId) external nonReentrant returns (uint256 payout) {
        payout = LibDpmService.claim(msg.sender, marketId);
        emit DpmClaimed(marketId, msg.sender, payout);
    }
}

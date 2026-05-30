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
 *         Thin wrappers: every lifecycle guard, pricing, fee, accounting, and event emission lives
 *         in LibDpmService (events are service-owned so they carry post-state for the event-sourced
 *         indexer; they still appear in this facet's ABI because it emits them). All four mutators
 *         move collateral and are `nonReentrant`; LibDpmService follows effects-before-interaction.
 */
contract DpmTradingFacet is ReentrancyGuard {
    /// @notice Deposit a 1:1 refundable intent stake before openTime (no fee, no pricing).
    function enterIntent(uint256 marketId, uint256 outcome, uint256 amount) external nonReentrant {
        LibDpmService.enterIntent(msg.sender, marketId, outcome, amount);
    }

    /// @notice Withdraw a refundable intent stake before openTime (1:1).
    function exitIntent(uint256 marketId, uint256 outcome, uint256 amount) external nonReentrant {
        LibDpmService.exitIntent(msg.sender, marketId, outcome, amount);
    }

    /// @notice Enter the dynamic pool (openTime <= now < closeTime). Charges the entry fee and
    ///         buys shares at the Pennock price. Returns the shares minted.
    function enter(uint256 marketId, uint256 outcome, uint256 amount)
        external
        nonReentrant
        returns (uint256 shares)
    {
        return LibDpmService.enter(msg.sender, marketId, outcome, amount);
    }

    /// @notice Claim a resolved market's payout (DPM I: refund of price paid + losers'-pool slice;
    ///         full refund on invalid / no-contest). Returns the collateral paid out.
    function claim(uint256 marketId) external nonReentrant returns (uint256 payout) {
        return LibDpmService.claim(msg.sender, marketId);
    }
}

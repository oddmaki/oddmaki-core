// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IERC1155BatchReceiver {
    function onERC1155BatchReceived(address operator, address from, uint256[] calldata ids, uint256[] calldata values, bytes calldata data) external returns (bytes4);
}

/**
 * @title MockCTF
 * @notice Mock Conditional Tokens Framework for tests.
 *         Condition helpers mirror the real CTF formula.
 *         Adds minimal ERC1155-like balance tracking plus splitPosition / mergePositions.
 *         safeTransferFrom skips callbacks; safeBatchTransferFrom calls onERC1155BatchReceived
 *         on contract receivers (needed for reentrancy testing).
 */
contract MockCTF {
    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    mapping(bytes32 => uint256) public outcomeSlotCounts;
    mapping(address => mapping(uint256 => uint256)) private _balances;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(bytes32 => uint256[]) private _reportedPayouts;
    mapping(bytes32 => bool) public payoutsReported;
    // conditionId => outcome index => payout numerator (mirrors the real CTF's public mapping).
    mapping(bytes32 => mapping(uint256 => uint256)) private _payoutNumerators;

    // -------------------------------------------------------------------------
    // Condition management (mirrors real CTF)
    // -------------------------------------------------------------------------

    /// @notice Same formula as the real CTF: keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount)).
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    /// @notice Registers the condition (real CTF writes outcomeSlotCount to storage).
    function prepareCondition(address, bytes32 conditionId, uint256 outcomeSlotCount) external {
        outcomeSlotCounts[conditionId] = outcomeSlotCount;
    }

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256) {
        return outcomeSlotCounts[conditionId];
    }

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(parentCollectionId, conditionId, indexSet));
    }

    // -------------------------------------------------------------------------
    // ERC1155-like balance tracking (no receiver callbacks)
    // -------------------------------------------------------------------------

    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        return _balances[owner][id];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    /// @notice Transfers tokens. Skips onERC1155Received callback.
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata) external {
        require(from == msg.sender || _operatorApprovals[from][msg.sender], "MockCTF: not approved");
        require(_balances[from][id] >= amount, "MockCTF: insufficient balance");
        _balances[from][id] -= amount;
        _balances[to][id] += amount;
    }

    /// @notice Batch transfer with onERC1155BatchReceived callback on contract receivers.
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        require(from == msg.sender || _operatorApprovals[from][msg.sender], "MockCTF: not approved");
        require(ids.length == amounts.length, "MockCTF: length mismatch");
        for (uint256 i = 0; i < ids.length; i++) {
            require(_balances[from][ids[i]] >= amounts[i], "MockCTF: insufficient balance");
            _balances[from][ids[i]] -= amounts[i];
            _balances[to][ids[i]] += amounts[i];
        }
        // Callback on contract receivers (needed for reentrancy testing)
        uint256 codeSize;
        assembly { codeSize := extcodesize(to) }
        if (codeSize > 0) {
            bytes4 retval = IERC1155BatchReceiver(to).onERC1155BatchReceived(msg.sender, from, ids, amounts, data);
            require(retval == IERC1155BatchReceiver.onERC1155BatchReceived.selector, "MockCTF: rejected");
        }
    }

    /// @notice Test helper: directly mint position tokens to an address.
    function mintPositionTokens(address to, uint256 id, uint256 amount) external {
        _balances[to][id] += amount;
    }

    // -------------------------------------------------------------------------
    // Split / merge (mirrors real CTF mechanics)
    // -------------------------------------------------------------------------

    /// @notice Takes `amount` of collateral from msg.sender, mints `amount` of each outcome token to msg.sender.
    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        collateralToken.transferFrom(msg.sender, address(this), amount);
        for (uint256 i = 0; i < partition.length; i++) {
            _balances[msg.sender][_positionId(address(collateralToken), parentCollectionId, conditionId, partition[i])] += amount;
        }
    }

    /// @notice Burns `amount` of each outcome token from msg.sender and returns `amount` of collateral.
    function mergePositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        for (uint256 i = 0; i < partition.length; i++) {
            uint256 posId = _positionId(address(collateralToken), parentCollectionId, conditionId, partition[i]);
            require(_balances[msg.sender][posId] >= amount, "MockCTF: insufficient outcome tokens");
            _balances[msg.sender][posId] -= amount;
        }
        collateralToken.transfer(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Resolution (reportPayouts)
    // -------------------------------------------------------------------------

    /// @notice Mock reportPayouts - stores payouts for test verification.
    /// @dev Also populates the conditionId-keyed numerator mapping the real CTF exposes, so code
    ///      that reads payoutNumerators(conditionId, index) (e.g. DPM claim) works against the mock.
    ///      The caller (msg.sender) is the oracle, and outcomeSlotCount == payouts.length, matching
    ///      the conditionId computed at prepareCondition time.
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external {
        _reportedPayouts[questionId] = payouts;
        payoutsReported[questionId] = true;

        bytes32 conditionId = keccak256(abi.encodePacked(msg.sender, questionId, payouts.length));
        for (uint256 i = 0; i < payouts.length; i++) {
            _payoutNumerators[conditionId][i] = payouts[i];
        }
    }

    /// @notice Real-CTF-compatible read: payout numerator for an outcome of a resolved condition.
    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256) {
        return _payoutNumerators[conditionId][index];
    }

    /// @notice Helper to read reported payouts in tests.
    function getReportedPayouts(bytes32 questionId) external view returns (uint256[] memory) {
        return _reportedPayouts[questionId];
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    function _positionId(address collateralToken, bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        private
        pure
        returns (uint256)
    {
        bytes32 collectionId = keccak256(abi.encodePacked(parentCollectionId, conditionId, indexSet));
        return uint256(keccak256(abi.encodePacked(collateralToken, collectionId)));
    }
}

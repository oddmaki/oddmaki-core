// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {NegRiskFacet} from "../../src/facets/NegRiskFacet.sol";

/**
 * @title ReentrancyAttacker
 * @notice Test contract that attempts reentrancy during NegRiskFacet.convertPositions().
 *         When receiving ERC-1155 tokens via safeBatchTransferFrom callback, it re-enters
 *         a nonReentrant function on the Diamond to test the reentrancy guard.
 */
contract ReentrancyAttacker {
    address public immutable diamond;
    bool public reentrancyBlocked;
    bool private _shouldAttack;

    // Stored attack parameters for re-entry
    bytes32[] private _conditionIds;
    address private _collateralToken;
    uint256 private _indexSet;
    uint256 private _amount;

    constructor(address _diamond) {
        diamond = _diamond;
    }

    /// @notice Initiate the attack: calls convertPositions(), which triggers a callback.
    function attack(
        bytes32[] calldata conditionIds,
        address collateralToken,
        uint256 indexSet,
        uint256 amount
    ) external {
        _conditionIds = conditionIds;
        _collateralToken = collateralToken;
        _indexSet = indexSet;
        _amount = amount;
        _shouldAttack = true;

        NegRiskFacet(diamond).convertPositions(conditionIds, collateralToken, indexSet, amount);
    }

    /// @notice ERC-1155 batch callback. On first invocation, attempts re-entry.
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external returns (bytes4) {
        if (_shouldAttack) {
            _shouldAttack = false; // Prevent infinite recursion

            // Try to re-enter convertPositions on the Diamond
            try NegRiskFacet(diamond).convertPositions(
                _conditionIds, _collateralToken, _indexSet, _amount
            ) {
                // Re-entry succeeded — reentrancy NOT blocked
                reentrancyBlocked = false;
            } catch (bytes memory reason) {
                // Check if the revert is from ReentrancyGuard (OZ v4.9)
                bytes memory expected = abi.encodeWithSignature(
                    "Error(string)", "ReentrancyGuard: reentrant call"
                );
                reentrancyBlocked = keccak256(reason) == keccak256(expected);
            }
        }
        return this.onERC1155BatchReceived.selector;
    }

    /// @notice ERC-1155 single-token callback (no-op).
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }
}

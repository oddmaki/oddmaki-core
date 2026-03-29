// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "../interfaces/IAccessControl.sol";

/**
 * @title NFTGatedAccessControl
 * @notice Access control based on NFT ownership.
 *         Supports both ERC-721 (balanceOf > 0) and ERC-1155 (balanceOf for tokenId > 0).
 *         Immutable after deployment — the NFT contract governs access.
 */
contract NFTGatedAccessControl is IAccessControl {
    address public immutable nftContract;
    bool public immutable isERC1155;
    uint256 public immutable tokenId;

    error ZeroAddress();

    constructor(address _nftContract, bool _isERC1155, uint256 _tokenId) {
        if (_nftContract == address(0)) revert ZeroAddress();
        nftContract = _nftContract;
        isERC1155 = _isERC1155;
        tokenId = _tokenId;
    }

    function isAllowed(address user) external view override returns (bool) {
        if (isERC1155) {
            // ERC-1155: balanceOf(address, uint256)
            (bool success, bytes memory data) =
                nftContract.staticcall(abi.encodeWithSignature("balanceOf(address,uint256)", user, tokenId));
            if (!success || data.length < 32) return false;
            return abi.decode(data, (uint256)) > 0;
        } else {
            // ERC-721: balanceOf(address)
            (bool success, bytes memory data) =
                nftContract.staticcall(abi.encodeWithSignature("balanceOf(address)", user));
            if (!success || data.length < 32) return false;
            return abi.decode(data, (uint256)) > 0;
        }
    }
}

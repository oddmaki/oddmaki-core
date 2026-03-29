// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibAccessControlAggregate} from "../aggregates/LibAccessControlAggregate.sol";
import {LibAccessControlValidator} from "../validators/LibAccessControlValidator.sol";
import {LibAccessControlStorage} from "../storage/LibAccessControlStorage.sol";
import {WhitelistAccessControl} from "../access-control/WhitelistAccessControl.sol";
import {NFTGatedAccessControl} from "../access-control/NFTGatedAccessControl.sol";
import {TokenGatedAccessControl} from "../access-control/TokenGatedAccessControl.sol";

/**
 * @title AccessControlFacet
 * @author OddMaki Protocol
 * @notice Access control management: deploy pre-built AC contracts,
 *         configure per-market trading restrictions, and check access.
 */
contract AccessControlFacet is ReentrancyGuard {
    // ---- Events ----
    event AccessControlDeployed(address indexed deployer, address indexed acContract, string acType);
    event MarketTradingAccessControlSet(uint256 indexed marketId, address indexed acContract);
    event MarketTradingAccessControlRemoved(uint256 indexed marketId);

    // ---- Factory (deploy standalone AC contracts) ----

    /// @notice Deploy a WhitelistAccessControl contract. Caller becomes the owner.
    /// @return acContract the deployed contract address.
    function deployWhitelistAC() external nonReentrant returns (address acContract) {
        WhitelistAccessControl ac = new WhitelistAccessControl(msg.sender);
        acContract = address(ac);
        emit AccessControlDeployed(msg.sender, acContract, "Whitelist");
    }

    /// @notice Deploy an NFTGatedAccessControl contract.
    /// @param nftContract The NFT contract address (ERC-721 or ERC-1155).
    /// @param isERC1155   True if the NFT contract is ERC-1155, false for ERC-721.
    /// @param tokenId     The token ID to check (only used for ERC-1155).
    function deployNFTGatedAC(address nftContract, bool isERC1155, uint256 tokenId)
        external
        nonReentrant
        returns (address acContract)
    {
        NFTGatedAccessControl ac = new NFTGatedAccessControl(nftContract, isERC1155, tokenId);
        acContract = address(ac);
        emit AccessControlDeployed(msg.sender, acContract, "NFTGated");
    }

    /// @notice Deploy a TokenGatedAccessControl contract.
    /// @param token      The ERC-20 token contract address.
    /// @param minBalance The minimum token balance required for access.
    function deployTokenGatedAC(address token, uint256 minBalance)
        external
        nonReentrant
        returns (address acContract)
    {
        TokenGatedAccessControl ac = new TokenGatedAccessControl(token, minBalance);
        acContract = address(ac);
        emit AccessControlDeployed(msg.sender, acContract, "TokenGated");
    }

    // ---- Configuration (market-level AC overrides) ----

    /// @notice Set a trading access control contract for a specific market. Venue operator only.
    /// @param marketId   the market to configure.
    /// @param acContract the access control contract address.
    function setMarketTradingAccessControl(uint256 marketId, address acContract) external nonReentrant {
        LibAccessControlAggregate.setMarketTradingAC(marketId, acContract, msg.sender);
        emit MarketTradingAccessControlSet(marketId, acContract);
    }

    /// @notice Remove the trading access control override for a specific market. Venue operator only.
    /// @param marketId the market to remove the override from.
    function removeMarketTradingAccessControl(uint256 marketId) external nonReentrant {
        LibAccessControlAggregate.removeMarketTradingAC(marketId, msg.sender);
        emit MarketTradingAccessControlRemoved(marketId);
    }

    // ---- Queries ----

    /// @notice Check if a user can trade on a specific market (checks market-level then venue-level fallback).
    /// @param user     the address to check.
    /// @param marketId the market to check against.
    function canTradeOnMarket(address user, uint256 marketId) external view returns (bool) {
        return LibAccessControlValidator.canTrade(user, marketId);
    }

    /// @notice Get the market-level trading AC contract address (address(0) if not set).
    /// @param marketId the market to query.
    function getMarketTradingAccessControl(uint256 marketId) external view returns (address) {
        return LibAccessControlStorage.getMarketTradingAC(marketId);
    }
}

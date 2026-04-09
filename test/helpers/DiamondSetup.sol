// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki, DiamondArgs} from "../../src/OddMaki.sol";
import {IDiamond} from "../../src/interfaces/IDiamond.sol";
import {DiamondCutFacet} from "../../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/facets/OwnershipFacet.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
import {MarketsFacet} from "../../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../../src/facets/LimitOrdersFacet.sol";
import {NegRiskFacet} from "../../src/facets/NegRiskFacet.sol";
import {MatchingFacet} from "../../src/facets/MatchingFacet.sol";
import {VenueFacet} from "../../src/facets/VenueFacet.sol";
import {OrderBookFacet} from "../../src/facets/OrderBookFacet.sol";
import {ProtocolFacet} from "../../src/facets/ProtocolFacet.sol";
import {MarketGroupFacet} from "../../src/facets/MarketGroupFacet.sol";
import {MarketOrdersFacet} from "../../src/facets/MarketOrdersFacet.sol";
import {ResolutionFacet} from "../../src/facets/ResolutionFacet.sol";
import {ERC1155ReceiverFacet} from "../../src/facets/ERC1155ReceiverFacet.sol";
import {AccessControlFacet} from "../../src/facets/AccessControlFacet.sol";
import {TagsFacet} from "../../src/facets/TagsFacet.sol";
import {MetadataFacet} from "../../src/facets/MetadataFacet.sol";
import {PriceMarketFacet} from "../../src/facets/PriceMarketFacet.sol";
import {PythResolutionFacet} from "../../src/facets/PythResolutionFacet.sol";
import {BatchOrdersFacet} from "../../src/facets/BatchOrdersFacet.sol";

/**
 * @title DiamondSetup
 * @notice Deploy Diamond with core + all business facets. Selectors are defined here (same pattern as script/DeployOddMaki.s.sol).
 *        When adding a new facet: deploy it and add a cut with its selectors in _buildCuts().
 */
contract DiamondSetup is Test {
    // Facet instances stored at contract level to avoid stack-too-deep with via_ir
    DiamondCutFacet internal _cutFacet;
    DiamondLoupeFacet internal _loupeFacet;
    OwnershipFacet internal _ownershipFacet;
    VaultFacet internal _vaultFacet;
    MarketsFacet internal _marketsFacet;
    LimitOrdersFacet internal _limitOrdersFacet;
    NegRiskFacet internal _negRiskFacet;
    MatchingFacet internal _matchingFacet;
    VenueFacet internal _venueFacet;
    OrderBookFacet internal _orderBookFacet;
    ProtocolFacet internal _protocolFacet;
    MarketGroupFacet internal _marketGroupFacet;
    MarketOrdersFacet internal _marketOrdersFacet;
    ResolutionFacet internal _resolutionFacet;
    ERC1155ReceiverFacet internal _erc1155ReceiverFacet;
    AccessControlFacet internal _accessControlFacet;
    TagsFacet internal _tagsFacet;
    MetadataFacet internal _metadataFacet;
    PriceMarketFacet internal _priceMarketFacet;
    PythResolutionFacet internal _pythResolutionFacet;
    BatchOrdersFacet internal _batchOrdersFacet;

    /// @notice Deploy Diamond with same facets as production (core + all business facets).
    function deployDiamond(address owner) internal returns (OddMaki diamond) {
        _cutFacet = new DiamondCutFacet();
        _loupeFacet = new DiamondLoupeFacet();
        _ownershipFacet = new OwnershipFacet();
        _vaultFacet = new VaultFacet();
        _marketsFacet = new MarketsFacet();
        _limitOrdersFacet = new LimitOrdersFacet();
        _negRiskFacet = new NegRiskFacet();
        _matchingFacet = new MatchingFacet();
        _venueFacet = new VenueFacet();
        _orderBookFacet = new OrderBookFacet();
        _protocolFacet = new ProtocolFacet();
        _marketGroupFacet = new MarketGroupFacet();
        _marketOrdersFacet = new MarketOrdersFacet();
        _resolutionFacet = new ResolutionFacet();
        _erc1155ReceiverFacet = new ERC1155ReceiverFacet();
        _accessControlFacet = new AccessControlFacet();
        _tagsFacet = new TagsFacet();
        _metadataFacet = new MetadataFacet();
        _priceMarketFacet = new PriceMarketFacet();
        _pythResolutionFacet = new PythResolutionFacet();
        _batchOrdersFacet = new BatchOrdersFacet();

        IDiamond.FacetCut[] memory cuts = _buildCuts();

        DiamondArgs memory args = DiamondArgs({owner: owner, init: address(0), initCalldata: ""});
        diamond = new OddMaki(cuts, args);
    }

    function _buildCuts() internal view returns (IDiamond.FacetCut[] memory cuts) {
        cuts = new IDiamond.FacetCut[](21);

        bytes4[] memory cutSelectors = new bytes4[](1);
        cutSelectors[0] = DiamondCutFacet.diamondCut.selector;
        cuts[0] = _cut(address(_cutFacet), cutSelectors);

        bytes4[] memory loupeSelectors = new bytes4[](5);
        loupeSelectors[0] = DiamondLoupeFacet.facets.selector;
        loupeSelectors[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        loupeSelectors[2] = DiamondLoupeFacet.facetAddresses.selector;
        loupeSelectors[3] = DiamondLoupeFacet.facetAddress.selector;
        loupeSelectors[4] = DiamondLoupeFacet.supportsInterface.selector;
        cuts[1] = _cut(address(_loupeFacet), loupeSelectors);

        bytes4[] memory ownershipSelectors = new bytes4[](2);
        ownershipSelectors[0] = OwnershipFacet.transferOwnership.selector;
        ownershipSelectors[1] = OwnershipFacet.owner.selector;
        cuts[2] = _cut(address(_ownershipFacet), ownershipSelectors);

        bytes4[] memory vaultSelectors = new bytes4[](5);
        vaultSelectors[0] = VaultFacet.getVault.selector;
        vaultSelectors[1] = VaultFacet.getCtfAddress.selector;
        vaultSelectors[2] = VaultFacet.setCtf.selector;
        vaultSelectors[3] = VaultFacet.splitPosition.selector;
        vaultSelectors[4] = VaultFacet.mergePositions.selector;
        cuts[3] = _cut(address(_vaultFacet), vaultSelectors);

        bytes4[] memory marketsSelectors = new bytes4[](10);
        marketsSelectors[0] = MarketsFacet.createMarket.selector;
        marketsSelectors[1] = MarketsFacet.getMarketRegistryData.selector;
        marketsSelectors[2] = MarketsFacet.getMarketTradingData.selector;
        marketsSelectors[3] = MarketsFacet.getMarketOracleData.selector;
        marketsSelectors[4] = MarketsFacet.getNextMarketId.selector;
        marketsSelectors[5] = MarketsFacet.addMarket.selector;
        marketsSelectors[6] = MarketsFacet.addPlaceholderMarkets.selector;
        marketsSelectors[7] = MarketsFacet.activatePlaceholder.selector;
        marketsSelectors[8] = MarketsFacet.pauseMarket.selector;
        marketsSelectors[9] = MarketsFacet.unpauseMarket.selector;
        cuts[4] = _cut(address(_marketsFacet), marketsSelectors);

        bytes4[] memory limitOrdersSelectors = new bytes4[](5);
        limitOrdersSelectors[0] = LimitOrdersFacet.placeOrder.selector;
        limitOrdersSelectors[1] = LimitOrdersFacet.cancelOrder.selector;
        limitOrdersSelectors[2] = LimitOrdersFacet.getOrder.selector;
        limitOrdersSelectors[3] = LimitOrdersFacet.expireOrders.selector;
        limitOrdersSelectors[4] = LimitOrdersFacet.cancelOrdersOnResolvedMarket.selector;
        cuts[5] = _cut(address(_limitOrdersFacet), limitOrdersSelectors);

        bytes4[] memory negRiskSelectors = new bytes4[](2);
        negRiskSelectors[0] = NegRiskFacet.getConversionPositionIds.selector;
        negRiskSelectors[1] = NegRiskFacet.convertPositions.selector;
        cuts[6] = _cut(address(_negRiskFacet), negRiskSelectors);

        bytes4[] memory matchingSelectors = new bytes4[](1);
        matchingSelectors[0] = MatchingFacet.matchOrders.selector;
        cuts[7] = _cut(address(_matchingFacet), matchingSelectors);

        bytes4[] memory venueSelectors = new bytes4[](11);
        venueSelectors[0] = VenueFacet.createVenue.selector;
        venueSelectors[1] = VenueFacet.updateVenue.selector;
        venueSelectors[2] = VenueFacet.updateVenueFees.selector;
        venueSelectors[3] = VenueFacet.updateVenueOracleParams.selector;
        venueSelectors[4] = VenueFacet.pauseVenue.selector;
        venueSelectors[5] = VenueFacet.unpauseVenue.selector;
        venueSelectors[6] = VenueFacet.getVenue.selector;
        venueSelectors[7] = VenueFacet.getNextVenueId.selector;
        venueSelectors[8] = VenueFacet.getVenueFees.selector;
        venueSelectors[9] = VenueFacet.canTrade.selector;
        venueSelectors[10] = VenueFacet.canCreateMarket.selector;
        cuts[8] = _cut(address(_venueFacet), venueSelectors);

        bytes4[] memory orderBookSelectors = new bytes4[](6);
        orderBookSelectors[0] = OrderBookFacet.getTopOfBook.selector;
        orderBookSelectors[1] = OrderBookFacet.getTickLevel.selector;
        orderBookSelectors[2] = OrderBookFacet.getMarkPrice.selector;
        orderBookSelectors[3] = OrderBookFacet.getFill.selector;
        orderBookSelectors[4] = OrderBookFacet.getNextFillId.selector;
        orderBookSelectors[5] = OrderBookFacet.canMatchOrders.selector;
        cuts[9] = _cut(address(_orderBookFacet), orderBookSelectors);

        bytes4[] memory protocolSelectors = new bytes4[](18);
        protocolSelectors[0] = ProtocolFacet.setProtocolTreasury.selector;
        protocolSelectors[1] = ProtocolFacet.getProtocolTreasury.selector;
        protocolSelectors[2] = ProtocolFacet.setUmaOracle.selector;
        protocolSelectors[3] = ProtocolFacet.getUmaOracle.selector;
        protocolSelectors[4] = ProtocolFacet.setUmaIdentifier.selector;
        protocolSelectors[5] = ProtocolFacet.getUmaIdentifier.selector;
        protocolSelectors[6] = ProtocolFacet.withdrawETH.selector;
        protocolSelectors[7] = ProtocolFacet.setCollateralWhitelisted.selector;
        protocolSelectors[8] = ProtocolFacet.isCollateralWhitelisted.selector;
        protocolSelectors[9] = ProtocolFacet.pauseProtocol.selector;
        protocolSelectors[10] = ProtocolFacet.unpauseProtocol.selector;
        protocolSelectors[11] = ProtocolFacet.getProtocolPaused.selector;
        protocolSelectors[12] = ProtocolFacet.suspendVenue.selector;
        protocolSelectors[13] = ProtocolFacet.unsuspendVenue.selector;
        protocolSelectors[14] = ProtocolFacet.getVenueSuspended.selector;
        protocolSelectors[15] = ProtocolFacet.withdrawERC20.selector;
        protocolSelectors[16] = ProtocolFacet.setProtocolFeeBps.selector;
        protocolSelectors[17] = ProtocolFacet.getProtocolFeeBps.selector;
        cuts[10] = _cut(address(_protocolFacet), protocolSelectors);

        bytes4[] memory marketGroupSelectors = new bytes4[](6);
        marketGroupSelectors[0] = MarketGroupFacet.createMarketGroup.selector;
        marketGroupSelectors[1] = MarketGroupFacet.activateMarketGroup.selector;
        marketGroupSelectors[2] = MarketGroupFacet.getMarketGroup.selector;
        marketGroupSelectors[3] = MarketGroupFacet.getGroupMarketIds.selector;
        marketGroupSelectors[4] = MarketGroupFacet.getMarketGroupItem.selector;
        marketGroupSelectors[5] = MarketGroupFacet.getNextGroupId.selector;
        cuts[11] = _cut(address(_marketGroupFacet), marketGroupSelectors);

        bytes4[] memory marketOrdersSelectors = new bytes4[](2);
        marketOrdersSelectors[0] = MarketOrdersFacet.placeMarketOrder.selector;
        marketOrdersSelectors[1] = MarketOrdersFacet.placeMarketSell.selector;
        cuts[12] = _cut(address(_marketOrdersFacet), marketOrdersSelectors);

        bytes4[] memory resolutionSelectors = new bytes4[](6);
        resolutionSelectors[0] = ResolutionFacet.assertMarketOutcome.selector;
        resolutionSelectors[1] = ResolutionFacet.settleAssertion.selector;
        resolutionSelectors[2] = ResolutionFacet.reportResolution.selector;
        resolutionSelectors[3] = ResolutionFacet.assertionResolvedCallback.selector;
        resolutionSelectors[4] = ResolutionFacet.assertionDisputedCallback.selector;
        resolutionSelectors[5] = ResolutionFacet.getAssertionData.selector;
        cuts[13] = _cut(address(_resolutionFacet), resolutionSelectors);

        bytes4[] memory erc1155ReceiverSelectors = new bytes4[](2);
        erc1155ReceiverSelectors[0] = ERC1155ReceiverFacet.onERC1155Received.selector;
        erc1155ReceiverSelectors[1] = ERC1155ReceiverFacet.onERC1155BatchReceived.selector;
        cuts[14] = _cut(address(_erc1155ReceiverFacet), erc1155ReceiverSelectors);

        // 15: AccessControlFacet
        bytes4[] memory accessControlSelectors = new bytes4[](7);
        accessControlSelectors[0] = AccessControlFacet.deployWhitelistAC.selector;
        accessControlSelectors[1] = AccessControlFacet.deployNFTGatedAC.selector;
        accessControlSelectors[2] = AccessControlFacet.deployTokenGatedAC.selector;
        accessControlSelectors[3] = AccessControlFacet.setMarketTradingAccessControl.selector;
        accessControlSelectors[4] = AccessControlFacet.removeMarketTradingAccessControl.selector;
        accessControlSelectors[5] = AccessControlFacet.canTradeOnMarket.selector;
        accessControlSelectors[6] = AccessControlFacet.getMarketTradingAccessControl.selector;
        cuts[15] = _cut(address(_accessControlFacet), accessControlSelectors);

        // 16: TagsFacet
        bytes4[] memory tagsSelectors = new bytes4[](2);
        tagsSelectors[0] = TagsFacet.updateMarketTags.selector;
        tagsSelectors[1] = TagsFacet.updateMarketGroupTags.selector;
        cuts[16] = _cut(address(_tagsFacet), tagsSelectors);

        // 17: MetadataFacet
        bytes4[] memory metadataSelectors = new bytes4[](2);
        metadataSelectors[0] = MetadataFacet.updateMarketMetadata.selector;
        metadataSelectors[1] = MetadataFacet.updateMarketGroupMetadata.selector;
        cuts[17] = _cut(address(_metadataFacet), metadataSelectors);

        // 18: PriceMarketFacet (provider-agnostic reads)
        bytes4[] memory priceMarketSelectors = new bytes4[](3);
        priceMarketSelectors[0] = PriceMarketFacet.getPriceMarket.selector;
        priceMarketSelectors[1] = PriceMarketFacet.isPriceMarket.selector;
        priceMarketSelectors[2] = PriceMarketFacet.canResolvePriceMarket.selector;
        cuts[18] = _cut(address(_priceMarketFacet), priceMarketSelectors);

        // 19: PythResolutionFacet (Pyth-specific admin + creation + resolution)
        bytes4[] memory pythResolutionSelectors = new bytes4[](4);
        pythResolutionSelectors[0] = PythResolutionFacet.setPythContract.selector;
        pythResolutionSelectors[1] = PythResolutionFacet.getPythContract.selector;
        pythResolutionSelectors[2] = PythResolutionFacet.createPriceMarketPyth.selector;
        pythResolutionSelectors[3] = PythResolutionFacet.resolvePriceMarketPyth.selector;
        cuts[19] = _cut(address(_pythResolutionFacet), pythResolutionSelectors);

        // 20: BatchOrdersFacet
        bytes4[] memory batchOrdersSelectors = new bytes4[](3);
        batchOrdersSelectors[0] = BatchOrdersFacet.batchPlaceOrders.selector;
        batchOrdersSelectors[1] = BatchOrdersFacet.batchCancelOrders.selector;
        batchOrdersSelectors[2] = BatchOrdersFacet.cancelAndReplace.selector;
        cuts[20] = _cut(address(_batchOrdersFacet), batchOrdersSelectors);
    }

    function _cut(address facetAddress, bytes4[] memory selectors) internal pure returns (IDiamond.FacetCut memory) {
        return IDiamond.FacetCut({
            facetAddress: facetAddress, action: IDiamond.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    /// @notice Create a default public venue for test setup. Returns venueId (1 on first call).
    function createDefaultVenue(address diamond) internal returns (uint256 venueId) {
        venueId = VenueFacet(diamond)
            .createVenue(
                "Test Venue", // name
                "", // metadata
                address(0), // tradingAccessControl (public)
                address(0), // creationAccessControl (public)
                address(this), // feeRecipient
                100, // venueFeeBps (1%)
                0, // creatorFeeBps
                1e16, // defaultTickSize (1%)
                5e6, // marketCreationFee (5 USDC minimum)
                0, // umaRewardAmount
                1e6 // umaMinBond (1 USDC)
            );
    }
}

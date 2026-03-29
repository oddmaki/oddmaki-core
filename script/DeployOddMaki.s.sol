// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {OddMaki, DiamondArgs} from "../src/OddMaki.sol";
import {IDiamond} from "../src/interfaces/IDiamond.sol";

// Core facets
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";

// Business facets
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {NegRiskFacet} from "../src/facets/NegRiskFacet.sol";
import {MatchingFacet} from "../src/facets/MatchingFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {OrderBookFacet} from "../src/facets/OrderBookFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {MarketGroupFacet} from "../src/facets/MarketGroupFacet.sol";
import {MarketOrdersFacet} from "../src/facets/MarketOrdersFacet.sol";
import {ResolutionFacet} from "../src/facets/ResolutionFacet.sol";
import {ERC1155ReceiverFacet} from "../src/facets/ERC1155ReceiverFacet.sol";
import {AccessControlFacet} from "../src/facets/AccessControlFacet.sol";
import {TagsFacet} from "../src/facets/TagsFacet.sol";
import {MetadataFacet} from "../src/facets/MetadataFacet.sol";
import {PriceMarketFacet} from "../src/facets/PriceMarketFacet.sol";
import {PythResolutionFacet} from "../src/facets/PythResolutionFacet.sol";
import {BatchOrdersFacet} from "../src/facets/BatchOrdersFacet.sol";

// Mocks (local dev only)
import {MockCTF} from "../test/helpers/MockCTF.sol";
import {MockERC20} from "../test/helpers/MockERC20.sol";
import {MockUmaOracle} from "../test/helpers/MockUmaOracle.sol";

/**
 * @title Deploy OddMaki (Diamond)
 * @notice Deploys the EIP-2535 Diamond proxy with all 17 facets and configures protocol settings.
 *
 * ENV VARS:
 *   CTF_ADDRESS          - Conditional Tokens Framework address (required for production; mock deployed on Anvil)
 *   UMA_ORACLE_ADDRESS   - UMA Optimistic Oracle V3 address (required for production; mock deployed on Anvil)
 *   PROTOCOL_TREASURY    - Protocol fee recipient (required for production; defaults to deployer on Anvil)
 *   OWNER                - Diamond owner, e.g. multisig (defaults to deployer)
 *   DEPLOY_MOCK_USDC     - Set to "true" to deploy a MockUSDC token (auto on Anvil, opt-in for testnets)
 *   DEPLOYER_ADDRESS     - Deployer address for --account mode (msg.sender in forge scripts != broadcaster).
 *                          Set this to your keystore account address when using --account.
 *   PRIVATE_KEY          - Deployer private key. Only needed for local Anvil dev (defaults to Anvil account 0).
 *
 * USAGE:
 *   Local (Anvil):
 *     forge script script/DeployOddMaki.s.sol:DeployOddMakiScript \
 *       --broadcast --rpc-url http://localhost:8545
 *
 *   Base Sepolia / Production (set DEPLOYER_ADDRESS, CTF_ADDRESS, UMA_ORACLE_ADDRESS, PROTOCOL_TREASURY in .env):
 *     forge script script/DeployOddMaki.s.sol:DeployOddMakiScript \
 *       --rpc-url $RPC_URL --account deployer --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract DeployOddMakiScript is Script {
    // Deployed protocol
    OddMaki public protocol;

    // Core facets
    DiamondCutFacet public cutFacet;
    DiamondLoupeFacet public loupeFacet;
    OwnershipFacet public ownershipFacet;

    // Business facets
    VaultFacet public vaultFacet;
    MarketsFacet public marketsFacet;
    LimitOrdersFacet public limitOrdersFacet;
    NegRiskFacet public negRiskFacet;
    MatchingFacet public matchingFacet;
    VenueFacet public venueFacet;
    OrderBookFacet public orderBookFacet;
    ProtocolFacet public protocolFacet;
    MarketGroupFacet public marketGroupFacet;
    MarketOrdersFacet public marketOrdersFacet;
    ResolutionFacet public resolutionFacet;
    ERC1155ReceiverFacet public erc1155ReceiverFacet;
    AccessControlFacet public accessControlFacet;
    TagsFacet public tagsFacet;
    MetadataFacet public metadataFacet;
    PriceMarketFacet public priceMarketFacet;
    PythResolutionFacet public pythResolutionFacet;
    BatchOrdersFacet public batchOrdersFacet;

    // Mocks (local dev only)
    MockCTF public mockCtf;
    MockERC20 public mockUsdc;
    MockUmaOracle public mockUmaOracle;

    // Configuration
    address public deployer;
    address public owner;
    address public protocolTreasury;
    address public ctfAddress;
    address public umaOracleAddress;
    bool public deployMockUsdc;
    address public pythAddress;

    function setUp() public virtual {
        // For --account mode: set DEPLOYER_ADDRESS in .env to the keystore account address.
        // This is needed because msg.sender in forge scripts is NOT the --account broadcaster.
        // For local Anvil dev: falls back to deriving from PRIVATE_KEY (Anvil account 0 default).
        deployer = vm.envOr("DEPLOYER_ADDRESS", address(0));
        if (deployer == address(0)) {
            uint256 privateKey =
                vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
            deployer = vm.addr(privateKey);
        }
        owner = vm.envOr("OWNER", deployer);
        protocolTreasury = vm.envOr("PROTOCOL_TREASURY", deployer);
        ctfAddress = vm.envOr("CTF_ADDRESS", address(0));
        umaOracleAddress = vm.envOr("UMA_ORACLE_ADDRESS", address(0));
        deployMockUsdc = vm.envOr("DEPLOY_MOCK_USDC", false);
        pythAddress = vm.envOr("PYTH_ADDRESS", address(0));
    }

    function run() public virtual {
        bool isLocal = block.chainid == 31337;

        // vm.startBroadcast() without args: uses --account for production, PRIVATE_KEY for local.
        // Same pattern as legacy Deploy.s.sol.
        vm.startBroadcast();

        console.log("=== OddMaki (Diamond) Deployment ===");
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", deployer);
        console.log("Owner:    ", owner);
        console.log("Treasury: ", protocolTreasury);
        console.log("");

        // 1. Deploy external dependencies (mocks for local, env vars for production)
        _deployExternalDeps(isLocal);

        // 2. Deploy all facets and build Diamond (deployer as initial owner for config)
        _deployDiamond();

        // 3. Configure protocol settings via facet calls (requires owner = deployer)
        _configureProtocol();

        // 4. Deploy test tokens (local auto, testnet opt-in via DEPLOY_MOCK_USDC=true)
        //    Must run before ownership transfer so deployer can whitelist collateral.
        if (isLocal || deployMockUsdc) _deployTestTokens();

        // 5. Transfer ownership to final OWNER if different from deployer
        if (owner != deployer) {
            OwnershipFacet(address(protocol)).transferOwnership(owner);
            console.log("Ownership transferred to:", owner);
            console.log("");
        }

        _printDeploymentSummary(isLocal);

        vm.stopBroadcast();
    }

    // -------------------------------------------------------------------------
    // External dependencies
    // -------------------------------------------------------------------------

    function _deployExternalDeps(bool isLocal) internal {
        // CTF
        if (ctfAddress != address(0)) {
            console.log("Using existing CTF at:", ctfAddress);
        } else {
            require(isLocal, "CTF_ADDRESS env var required for non-local deployments");
            console.log("Deploying MockCTF for local dev...");
            mockCtf = new MockCTF();
            ctfAddress = address(mockCtf);
            console.log("  MockCTF:", ctfAddress);
        }

        // UMA Oracle
        if (umaOracleAddress != address(0)) {
            console.log("Using existing UMA Oracle at:", umaOracleAddress);
        } else {
            require(isLocal, "UMA_ORACLE_ADDRESS env var required for non-local deployments");
            console.log("Deploying MockUmaOracle for local dev...");
            mockUmaOracle = new MockUmaOracle();
            umaOracleAddress = address(mockUmaOracle);
            console.log("  MockUmaOracle:", umaOracleAddress);
        }
        console.log("");
    }

    // -------------------------------------------------------------------------
    // Diamond deployment
    // -------------------------------------------------------------------------

    function _deployDiamond() internal {
        console.log("Deploying facets...");

        // Core
        cutFacet = new DiamondCutFacet();
        loupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();

        // Business
        vaultFacet = new VaultFacet();
        marketsFacet = new MarketsFacet();
        limitOrdersFacet = new LimitOrdersFacet();
        negRiskFacet = new NegRiskFacet();
        matchingFacet = new MatchingFacet();
        venueFacet = new VenueFacet();
        orderBookFacet = new OrderBookFacet();
        protocolFacet = new ProtocolFacet();
        marketGroupFacet = new MarketGroupFacet();
        marketOrdersFacet = new MarketOrdersFacet();
        resolutionFacet = new ResolutionFacet();
        erc1155ReceiverFacet = new ERC1155ReceiverFacet();
        accessControlFacet = new AccessControlFacet();
        tagsFacet = new TagsFacet();
        metadataFacet = new MetadataFacet();
        priceMarketFacet = new PriceMarketFacet();
        pythResolutionFacet = new PythResolutionFacet();
        batchOrdersFacet = new BatchOrdersFacet();

        console.log("Building diamond cuts (21 facets)...");
        IDiamond.FacetCut[] memory cuts = _buildCuts();

        // Deploy with deployer as initial owner so configuration calls succeed.
        // Ownership is transferred to the final OWNER after configuration.
        console.log("Deploying OddMaki Diamond...");
        DiamondArgs memory args = DiamondArgs({owner: deployer, init: address(0), initCalldata: ""});
        protocol = new OddMaki(cuts, args);
        console.log("  OddMaki:", address(protocol));
        console.log("");
    }

    // -------------------------------------------------------------------------
    // Protocol configuration (post-deployment)
    // -------------------------------------------------------------------------

    function _configureProtocol() internal {
        console.log("Configuring protocol...");

        VaultFacet(address(protocol)).setCtf(ctfAddress);
        console.log("  CTF set to:", ctfAddress);

        ProtocolFacet(address(protocol)).setProtocolTreasury(protocolTreasury);
        console.log("  Protocol treasury set to:", protocolTreasury);

        ProtocolFacet(address(protocol)).setUmaOracle(umaOracleAddress);
        console.log("  UMA Oracle set to:", umaOracleAddress);

        // ASSERT_TRUTH for Base Sepolia, ASSERT_TRUTH2 for Base mainnet
        // Can be updated later via ProtocolFacet.setUmaIdentifier()
        bytes32 umaIdentifier = "ASSERT_TRUTH";
        ProtocolFacet(address(protocol)).setUmaIdentifier(umaIdentifier);
        console.log("  UMA identifier set to: ASSERT_TRUTH");

        // Pyth Oracle (optional — skip if not set)
        if (pythAddress != address(0)) {
            PythResolutionFacet(address(protocol)).setPythContract(pythAddress);
            console.log("  Pyth Oracle set to:", pythAddress);
        }

        console.log("");
    }

    // -------------------------------------------------------------------------
    // Test tokens (local auto, testnet opt-in)
    // -------------------------------------------------------------------------

    function _deployTestTokens() internal {
        console.log("Deploying MockUSDC...");
        mockUsdc = new MockERC20("USD Coin", "USDC", 6);
        console.log("  MockUSDC:", address(mockUsdc));

        ProtocolFacet(address(protocol)).setCollateralWhitelisted(address(mockUsdc), true);
        console.log("  MockUSDC whitelisted as collateral");

        console.log("");
    }

    // -------------------------------------------------------------------------
    // Facet cuts — mirrors test/helpers/DiamondSetup.sol
    // -------------------------------------------------------------------------

    function _buildCuts() internal view returns (IDiamond.FacetCut[] memory cuts) {
        cuts = new IDiamond.FacetCut[](21);

        // 0: DiamondCutFacet
        bytes4[] memory cutSelectors = new bytes4[](1);
        cutSelectors[0] = DiamondCutFacet.diamondCut.selector;
        cuts[0] = _cut(address(cutFacet), cutSelectors);

        // 1: DiamondLoupeFacet
        bytes4[] memory loupeSelectors = new bytes4[](5);
        loupeSelectors[0] = DiamondLoupeFacet.facets.selector;
        loupeSelectors[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        loupeSelectors[2] = DiamondLoupeFacet.facetAddresses.selector;
        loupeSelectors[3] = DiamondLoupeFacet.facetAddress.selector;
        loupeSelectors[4] = DiamondLoupeFacet.supportsInterface.selector;
        cuts[1] = _cut(address(loupeFacet), loupeSelectors);

        // 2: OwnershipFacet
        bytes4[] memory ownershipSelectors = new bytes4[](2);
        ownershipSelectors[0] = OwnershipFacet.transferOwnership.selector;
        ownershipSelectors[1] = OwnershipFacet.owner.selector;
        cuts[2] = _cut(address(ownershipFacet), ownershipSelectors);

        // 3: VaultFacet
        bytes4[] memory vaultSelectors = new bytes4[](5);
        vaultSelectors[0] = VaultFacet.getVault.selector;
        vaultSelectors[1] = VaultFacet.getCtfAddress.selector;
        vaultSelectors[2] = VaultFacet.setCtf.selector;
        vaultSelectors[3] = VaultFacet.splitPosition.selector;
        vaultSelectors[4] = VaultFacet.mergePositions.selector;
        cuts[3] = _cut(address(vaultFacet), vaultSelectors);

        // 4: MarketsFacet
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
        cuts[4] = _cut(address(marketsFacet), marketsSelectors);

        // 5: LimitOrdersFacet
        bytes4[] memory limitOrdersSelectors = new bytes4[](5);
        limitOrdersSelectors[0] = LimitOrdersFacet.placeOrder.selector;
        limitOrdersSelectors[1] = LimitOrdersFacet.cancelOrder.selector;
        limitOrdersSelectors[2] = LimitOrdersFacet.getOrder.selector;
        limitOrdersSelectors[3] = LimitOrdersFacet.expireOrders.selector;
        limitOrdersSelectors[4] = LimitOrdersFacet.cancelOrdersOnResolvedMarket.selector;
        cuts[5] = _cut(address(limitOrdersFacet), limitOrdersSelectors);

        // 6: NegRiskFacet
        bytes4[] memory negRiskSelectors = new bytes4[](2);
        negRiskSelectors[0] = NegRiskFacet.getConversionPositionIds.selector;
        negRiskSelectors[1] = NegRiskFacet.convertPositions.selector;
        cuts[6] = _cut(address(negRiskFacet), negRiskSelectors);

        // 7: MatchingFacet
        bytes4[] memory matchingSelectors = new bytes4[](1);
        matchingSelectors[0] = MatchingFacet.matchOrders.selector;
        cuts[7] = _cut(address(matchingFacet), matchingSelectors);

        // 8: VenueFacet
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
        cuts[8] = _cut(address(venueFacet), venueSelectors);

        // 9: OrderBookFacet
        bytes4[] memory orderBookSelectors = new bytes4[](6);
        orderBookSelectors[0] = OrderBookFacet.getTopOfBook.selector;
        orderBookSelectors[1] = OrderBookFacet.getTickLevel.selector;
        orderBookSelectors[2] = OrderBookFacet.getMarkPrice.selector;
        orderBookSelectors[3] = OrderBookFacet.getFill.selector;
        orderBookSelectors[4] = OrderBookFacet.getNextFillId.selector;
        orderBookSelectors[5] = OrderBookFacet.canMatchOrders.selector;
        cuts[9] = _cut(address(orderBookFacet), orderBookSelectors);

        // 10: ProtocolFacet
        bytes4[] memory protocolSelectors = new bytes4[](16);
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
        cuts[10] = _cut(address(protocolFacet), protocolSelectors);

        // 11: MarketGroupFacet
        bytes4[] memory marketGroupSelectors = new bytes4[](6);
        marketGroupSelectors[0] = MarketGroupFacet.createMarketGroup.selector;
        marketGroupSelectors[1] = MarketGroupFacet.activateMarketGroup.selector;
        marketGroupSelectors[2] = MarketGroupFacet.getMarketGroup.selector;
        marketGroupSelectors[3] = MarketGroupFacet.getGroupMarketIds.selector;
        marketGroupSelectors[4] = MarketGroupFacet.getMarketGroupItem.selector;
        marketGroupSelectors[5] = MarketGroupFacet.getNextGroupId.selector;
        cuts[11] = _cut(address(marketGroupFacet), marketGroupSelectors);

        // 12: MarketOrdersFacet
        bytes4[] memory marketOrdersSelectors = new bytes4[](1);
        marketOrdersSelectors[0] = MarketOrdersFacet.placeMarketOrder.selector;
        cuts[12] = _cut(address(marketOrdersFacet), marketOrdersSelectors);

        // 13: ResolutionFacet
        bytes4[] memory resolutionSelectors = new bytes4[](6);
        resolutionSelectors[0] = ResolutionFacet.assertMarketOutcome.selector;
        resolutionSelectors[1] = ResolutionFacet.settleAssertion.selector;
        resolutionSelectors[2] = ResolutionFacet.reportResolution.selector;
        resolutionSelectors[3] = ResolutionFacet.assertionResolvedCallback.selector;
        resolutionSelectors[4] = ResolutionFacet.assertionDisputedCallback.selector;
        resolutionSelectors[5] = ResolutionFacet.getAssertionData.selector;
        cuts[13] = _cut(address(resolutionFacet), resolutionSelectors);

        // 14: ERC1155ReceiverFacet
        bytes4[] memory erc1155ReceiverSelectors = new bytes4[](2);
        erc1155ReceiverSelectors[0] = ERC1155ReceiverFacet.onERC1155Received.selector;
        erc1155ReceiverSelectors[1] = ERC1155ReceiverFacet.onERC1155BatchReceived.selector;
        cuts[14] = _cut(address(erc1155ReceiverFacet), erc1155ReceiverSelectors);

        // 15: AccessControlFacet
        bytes4[] memory accessControlSelectors = new bytes4[](7);
        accessControlSelectors[0] = AccessControlFacet.deployWhitelistAC.selector;
        accessControlSelectors[1] = AccessControlFacet.deployNFTGatedAC.selector;
        accessControlSelectors[2] = AccessControlFacet.deployTokenGatedAC.selector;
        accessControlSelectors[3] = AccessControlFacet.setMarketTradingAccessControl.selector;
        accessControlSelectors[4] = AccessControlFacet.removeMarketTradingAccessControl.selector;
        accessControlSelectors[5] = AccessControlFacet.canTradeOnMarket.selector;
        accessControlSelectors[6] = AccessControlFacet.getMarketTradingAccessControl.selector;
        cuts[15] = _cut(address(accessControlFacet), accessControlSelectors);

        // 16: TagsFacet
        bytes4[] memory tagsSelectors = new bytes4[](2);
        tagsSelectors[0] = TagsFacet.updateMarketTags.selector;
        tagsSelectors[1] = TagsFacet.updateMarketGroupTags.selector;
        cuts[16] = _cut(address(tagsFacet), tagsSelectors);

        // 17: MetadataFacet
        bytes4[] memory metadataSelectors = new bytes4[](2);
        metadataSelectors[0] = MetadataFacet.updateMarketMetadata.selector;
        metadataSelectors[1] = MetadataFacet.updateMarketGroupMetadata.selector;
        cuts[17] = _cut(address(metadataFacet), metadataSelectors);

        // 18: PriceMarketFacet (provider-agnostic reads)
        bytes4[] memory priceMarketSelectors = new bytes4[](3);
        priceMarketSelectors[0] = PriceMarketFacet.getPriceMarket.selector;
        priceMarketSelectors[1] = PriceMarketFacet.isPriceMarket.selector;
        priceMarketSelectors[2] = PriceMarketFacet.canResolvePriceMarket.selector;
        cuts[18] = _cut(address(priceMarketFacet), priceMarketSelectors);

        // 19: PythResolutionFacet (Pyth-specific admin + creation + resolution)
        bytes4[] memory pythResolutionSelectors = new bytes4[](4);
        pythResolutionSelectors[0] = PythResolutionFacet.setPythContract.selector;
        pythResolutionSelectors[1] = PythResolutionFacet.getPythContract.selector;
        pythResolutionSelectors[2] = PythResolutionFacet.createPriceMarketPyth.selector;
        pythResolutionSelectors[3] = PythResolutionFacet.resolvePriceMarketPyth.selector;
        cuts[19] = _cut(address(pythResolutionFacet), pythResolutionSelectors);

        // 20: BatchOrdersFacet
        bytes4[] memory batchOrdersSelectors = new bytes4[](3);
        batchOrdersSelectors[0] = BatchOrdersFacet.batchPlaceOrders.selector;
        batchOrdersSelectors[1] = BatchOrdersFacet.batchCancelOrders.selector;
        batchOrdersSelectors[2] = BatchOrdersFacet.cancelAndReplace.selector;
        cuts[20] = _cut(address(batchOrdersFacet), batchOrdersSelectors);
    }

    function _cut(address facetAddress, bytes4[] memory selectors) internal pure returns (IDiamond.FacetCut memory) {
        return IDiamond.FacetCut({facetAddress: facetAddress, action: IDiamond.FacetCutAction.Add, functionSelectors: selectors});
    }

    // -------------------------------------------------------------------------
    // Summary
    // -------------------------------------------------------------------------

    function _printDeploymentSummary(bool isLocal) internal view {
        console.log("=== Deployment Complete ===");
        console.log("");
        console.log("Diamond:");
        console.log("  OddMaki:", address(protocol));
        console.log("  Owner:          ", owner);
        console.log("");
        console.log("Core Facets:");
        console.log("  DiamondCutFacet:   ", address(cutFacet));
        console.log("  DiamondLoupeFacet: ", address(loupeFacet));
        console.log("  OwnershipFacet:    ", address(ownershipFacet));
        console.log("");
        console.log("Business Facets:");
        console.log("  VaultFacet:        ", address(vaultFacet));
        console.log("  MarketsFacet:      ", address(marketsFacet));
        console.log("  LimitOrdersFacet:  ", address(limitOrdersFacet));
        console.log("  NegRiskFacet:      ", address(negRiskFacet));
        console.log("  MatchingFacet:     ", address(matchingFacet));
        console.log("  VenueFacet:        ", address(venueFacet));
        console.log("  OrderBookFacet:    ", address(orderBookFacet));
        console.log("  ProtocolFacet:     ", address(protocolFacet));
        console.log("  MarketGroupFacet:  ", address(marketGroupFacet));
        console.log("  MarketOrdersFacet: ", address(marketOrdersFacet));
        console.log("  ResolutionFacet:   ", address(resolutionFacet));
        console.log("  ERC1155ReceiverFacet:", address(erc1155ReceiverFacet));
        console.log("  AccessControlFacet:", address(accessControlFacet));
        console.log("  TagsFacet:         ", address(tagsFacet));
        console.log("  MetadataFacet:     ", address(metadataFacet));
        console.log("  PriceMarketFacet:  ", address(priceMarketFacet));
        console.log("  PythResolutionFacet:", address(pythResolutionFacet));
        console.log("  BatchOrdersFacet:  ", address(batchOrdersFacet));
        console.log("");
        console.log("Configuration:");
        console.log("  CTF:              ", ctfAddress);
        console.log("  UMA Oracle:       ", umaOracleAddress);
        console.log("  Protocol Treasury:", protocolTreasury);
        console.log("  UMA Identifier:    ASSERT_TRUTH");
        console.log("");

        if (isLocal) {
            console.log("Mocks (local dev):");
            console.log("  MockCTF:       ", address(mockCtf));
            console.log("  MockUmaOracle: ", address(mockUmaOracle));
        }
        if (address(mockUsdc) != address(0)) {
            console.log("  MockUSDC:      ", address(mockUsdc));
        }
        if (isLocal || address(mockUsdc) != address(0)) {
            console.log("");
        }
    }
}

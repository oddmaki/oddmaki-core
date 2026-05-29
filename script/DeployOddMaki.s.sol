// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
import {DpmFacet} from "../src/facets/DpmFacet.sol";
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
 *   USDC_ADDRESS         - Real USDC (or other 6-decimal collateral) to whitelist. Required for mainnet.
 *                          Ignored when DEPLOY_MOCK_USDC=true / local (mock is used instead).
 *   DEPLOYER_ADDRESS     - Deployer address for --account mode (msg.sender in forge scripts != broadcaster).
 *                          Set this to your keystore account address when using --account.
 *   PRIVATE_KEY          - Deployer private key. Only needed for local Anvil dev (defaults to Anvil account 0).
 *
 * USAGE:
 *   Local (Anvil):
 *     forge script script/DeployOddMaki.s.sol:DeployOddMakiScript \
 *       --broadcast --rpc-url http://localhost:8545
 *
 *   Base Sepolia / Production (set DEPLOYER_ADDRESS, CTF_ADDRESS, UMA_ORACLE_ADDRESS,
 *   PROTOCOL_TREASURY in .env). Two steps — deploy first, verify separately:
 *
 *     # 1. Deploy (do NOT use --verify here; see "Why two steps" below)
 *     forge script script/DeployOddMaki.s.sol:DeployOddMakiScript \
 *       --rpc-url $RPC_URL --account deployer --broadcast
 *
 *     # 2. Generate per-contract Standard JSON Input files
 *     ./script/generate-standard-json.sh           # Base Sepolia (84532)
 *     ./script/generate-standard-json.sh 8453      # Base mainnet
 *
 *     # 3. For each contract in ./verify-json/, manually upload via the BaseScan UI:
 *     #    https://[sepolia.]basescan.org/verifyContract?a=<address>
 *     #    Compiler Type:    Solidity (Standard-Json-Input)
 *     #    Compiler Version: v0.8.28+commit.7893614a
 *     #    License Type:     Business Source License 1.1   (MIT for Mocks)
 *
 *     # OPTIONAL: Sourcify batch verification — works for some contracts; partial
 *     # Basescan integration. Useful for testnets, does NOT replace step 3 for mainnet.
 *     ./script/verify-deployment.sh                # Base Sepolia (84532)
 *     ./script/verify-deployment.sh 8453           # Base mainnet
 *
 *   Why two steps (do NOT use --verify in the deploy command):
 *     Etherscan V2's multi-chain API verifier has a confirmed bug recompiling via_ir
 *     builds. forge submits correct Standard JSON (verified via --show-standard-json-input)
 *     and on-chain bytecode matches the local artifact byte-for-byte, but Etherscan's
 *     recompile diverges and reports "bytecode does NOT match". We tested every variable:
 *     license source (BUSL-1.1 vs MIT), Foundry version (1.4.4 vs 1.6.0), bytecode_hash
 *     (ipfs vs none), compiler commit hash, --via-ir flag, evm_version (cancun vs shanghai)
 *     — all fail via the API. The Basescan UI's Standard-Json-Input flow uses a different
 *     code path on Etherscan's side and works reliably, hence the manual step.
 *
 *     Mainnet contracts only need to be verified once, ever. ~30 min of clicks.
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
    DpmFacet public dpmFacet;
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
    address public usdcAddress;

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
        usdcAddress = vm.envOr("USDC_ADDRESS", address(0));
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
        if (isLocal || deployMockUsdc) {
            _deployTestTokens();
        } else {
            // Real-collateral path: whitelist USDC_ADDRESS from env (required for mainnet).
            _whitelistCollateral();
        }

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
        dpmFacet = new DpmFacet();

        console.log("Building diamond cuts (22 facets)...");
        IDiamond.FacetCut[] memory cuts = _buildCuts();

        // Deploy with deployer as initial owner so configuration calls succeed.
        // Ownership is transferred to the final OWNER after configuration.
        console.log("Deploying OddMaki Diamond...");
        DiamondArgs memory args = DiamondArgs({owner: deployer, init: address(0), initCalldata: ""});
        protocol = new OddMaki(cuts, args);
        console.log("  OddMaki:", address(protocol));

        // PythResolutionFacet tail selectors added via a follow-up cut — see `_buildCuts` notes.
        IDiamond.FacetCut[] memory tailCuts = new IDiamond.FacetCut[](1);
        tailCuts[0] = _cut(address(pythResolutionFacet), _pythTailSelectors());
        DiamondCutFacet(address(protocol)).diamondCut(tailCuts, address(0), "");
        console.log("  + Pyth tail selectors cut (markPriceMarketInvalid)");
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

        ProtocolFacet(address(protocol)).setProtocolFeeBps(50);
        console.log("  Protocol fee set to: 50 bps");

        ProtocolFacet(address(protocol)).setUmaOracle(umaOracleAddress);
        console.log("  UMA Oracle set to:", umaOracleAddress);

        // ASSERT_TRUTH for Base Sepolia, ASSERT_TRUTH2 for Base mainnet
        // Can be updated later via ProtocolFacet.setUmaIdentifier()
        bool isMainnet = block.chainid == 8453;
        bytes32 umaIdentifier = isMainnet ? bytes32("ASSERT_TRUTH2") : bytes32("ASSERT_TRUTH");
        ProtocolFacet(address(protocol)).setUmaIdentifier(umaIdentifier);
        console.log("  UMA identifier set to:", isMainnet ? "ASSERT_TRUTH2" : "ASSERT_TRUTH");

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
    // Real collateral whitelist (non-mock path)
    // -------------------------------------------------------------------------

    function _whitelistCollateral() internal {
        if (usdcAddress == address(0)) {
            console.log("WARNING: USDC_ADDRESS not set - no collateral whitelisted.");
            console.log("  Whitelist manually via ProtocolFacet.setCollateralWhitelisted() after deploy.");
            console.log("");
            return;
        }

        // Sanity-check the token before whitelisting: decimals must be 6 (USDC convention
        // and the scale assumed by SDK/subgraph). symbol() is logged for eyeball verification
        // during dry-runs — a typo in USDC_ADDRESS produces an obviously-wrong symbol.
        IERC20Metadata token = IERC20Metadata(usdcAddress);
        uint8 decimals = token.decimals();
        string memory symbol = token.symbol();

        require(decimals == 6, "USDC_ADDRESS: expected 6 decimals");

        console.log("Whitelisting collateral...");
        console.log("  Address: ", usdcAddress);
        console.log("  Symbol:  ", symbol);
        console.log("  Decimals:", decimals);

        ProtocolFacet(address(protocol)).setCollateralWhitelisted(usdcAddress, true);
        console.log("  Whitelisted");
        console.log("");
    }

    // -------------------------------------------------------------------------
    // Facet cuts — mirrors test/helpers/DiamondSetup.sol
    // -------------------------------------------------------------------------

    function _buildCuts() internal view returns (IDiamond.FacetCut[] memory cuts) {
        cuts = new IDiamond.FacetCut[](22);

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
        bytes4[] memory venueSelectors = new bytes4[](12);
        venueSelectors[0] = VenueFacet.createVenue.selector;
        venueSelectors[1] = VenueFacet.updateVenue.selector;
        venueSelectors[2] = VenueFacet.updateVenueFees.selector;
        venueSelectors[3] = VenueFacet.updateVenueOracleParams.selector;
        venueSelectors[4] = VenueFacet.updateVenueMarketCreationFee.selector;
        venueSelectors[5] = VenueFacet.pauseVenue.selector;
        venueSelectors[6] = VenueFacet.unpauseVenue.selector;
        venueSelectors[7] = VenueFacet.getVenue.selector;
        venueSelectors[8] = VenueFacet.getNextVenueId.selector;
        venueSelectors[9] = VenueFacet.getVenueFees.selector;
        venueSelectors[10] = VenueFacet.canTrade.selector;
        venueSelectors[11] = VenueFacet.canCreateMarket.selector;
        cuts[8] = _cut(address(venueFacet), venueSelectors);

        // 9: OrderBookFacet
        bytes4[] memory orderBookSelectors = new bytes4[](7);
        orderBookSelectors[0] = OrderBookFacet.getTopOfBook.selector;
        orderBookSelectors[1] = OrderBookFacet.getTickLevel.selector;
        orderBookSelectors[2] = OrderBookFacet.getMarkPrice.selector;
        orderBookSelectors[3] = OrderBookFacet.getFill.selector;
        orderBookSelectors[4] = OrderBookFacet.getNextFillId.selector;
        orderBookSelectors[5] = OrderBookFacet.canMatchOrders.selector;
        orderBookSelectors[6] = OrderBookFacet.getImpliedTopOfBook.selector;
        cuts[9] = _cut(address(orderBookFacet), orderBookSelectors);

        // 10: ProtocolFacet
        bytes4[] memory protocolSelectors = new bytes4[](10);
        protocolSelectors[0] = ProtocolFacet.setProtocolTreasury.selector;
        protocolSelectors[1] = ProtocolFacet.getProtocolTreasury.selector;
        protocolSelectors[2] = ProtocolFacet.setProtocolFeeBps.selector;
        protocolSelectors[3] = ProtocolFacet.getProtocolFeeBps.selector;
        protocolSelectors[4] = ProtocolFacet.setUmaOracle.selector;
        protocolSelectors[5] = ProtocolFacet.getUmaOracle.selector;
        protocolSelectors[6] = ProtocolFacet.setUmaIdentifier.selector;
        protocolSelectors[7] = ProtocolFacet.getUmaIdentifier.selector;
        protocolSelectors[8] = ProtocolFacet.setCollateralWhitelisted.selector;
        protocolSelectors[9] = ProtocolFacet.isCollateralWhitelisted.selector;
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
        bytes4[] memory marketOrdersSelectors = new bytes4[](2);
        marketOrdersSelectors[0] = MarketOrdersFacet.placeMarketBuy.selector;
        marketOrdersSelectors[1] = MarketOrdersFacet.placeMarketSell.selector;
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

        // 19: PythResolutionFacet (Pyth-specific admin + creation + resolution).
        // `markPriceMarketInvalid` is added via a follow-up diamondCut after construction
        // (see `_deployDiamond`) — bundling all 5 selectors here tips the Yul IR optimizer
        // over its stack-depth limit when the full project is compiled in one run.
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

        // 21: DpmFacet (dynamic pari-mutuel markets)
        cuts[21] = _cut(address(dpmFacet), _dpmSelectors());
    }

    function _dpmSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](13);
        selectors[0] = DpmFacet.createDpmMarket.selector;
        selectors[1] = DpmFacet.enterIntent.selector;
        selectors[2] = DpmFacet.exitIntent.selector;
        selectors[3] = DpmFacet.enter.selector;
        selectors[4] = DpmFacet.claim.selector;
        selectors[5] = DpmFacet.isDpmMarket.selector;
        selectors[6] = DpmFacet.getDpmMarket.selector;
        selectors[7] = DpmFacet.getMarketCollateral.selector;
        selectors[8] = DpmFacet.getMarketShares.selector;
        selectors[9] = DpmFacet.getIntentStake.selector;
        selectors[10] = DpmFacet.getUserShares.selector;
        selectors[11] = DpmFacet.getUserPaid.selector;
        selectors[12] = DpmFacet.quoteEntryShares.selector;
    }

    function _cut(address facetAddress, bytes4[] memory selectors) internal pure returns (IDiamond.FacetCut memory) {
        return IDiamond.FacetCut({facetAddress: facetAddress, action: IDiamond.FacetCutAction.Add, functionSelectors: selectors});
    }

    /// @dev `markPriceMarketInvalid` is added in a separate diamondCut call after Diamond
    ///      construction. Bundling all 5 PythResolutionFacet selectors into the constructor
    ///      cuts tips the Yul IR optimizer into stack-too-deep under via_ir.
    function _pythTailSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = PythResolutionFacet.markPriceMarketInvalid.selector;
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
        console.log(
            "  UMA Identifier:   ",
            block.chainid == 8453 ? "ASSERT_TRUTH2" : "ASSERT_TRUTH"
        );
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

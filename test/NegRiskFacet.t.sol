// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {MarketGroupFacet} from "../src/facets/MarketGroupFacet.sol";
import {NegRiskFacet} from "../src/facets/NegRiskFacet.sol";
import {MarketOracleData} from "../src/interfaces/Types.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {ReentrancyAttacker} from "./helpers/ReentrancyAttacker.sol";

/**
 * @title NegRiskFacet integration tests
 * @notice Tests reentrancy protection on convertPositions (audit finding C-2).
 */
contract NegRiskFacetTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public venueId;
    uint256 public groupId;

    uint256 constant TICK_SIZE = 1e16;
    uint256 constant NUM_MARKETS = 3;

    bytes32[] public conditionIds;
    uint256[] public marketIds;

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        venueId = createDefaultVenue(address(diamond));

        // Create market group with 3 markets
        groupId = MarketGroupFacet(address(diamond)).createMarketGroup(
            venueId, "Who wins?", "Exactly one resolves YES",
            address(collateral), TICK_SIZE, 0, 0, new bytes32[](0)
        );

        for (uint256 i = 0; i < NUM_MARKETS; i++) {
            uint256 mid = MarketsFacet(address(diamond)).addMarket(groupId, "Candidate", "Will candidate win?");
            marketIds.push(mid);
        }

        // Activate the group (locks totalMarkets, activates markets, registers wrapped collateral)
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        // Collect conditionIds from each market
        for (uint256 i = 0; i < NUM_MARKETS; i++) {
            MarketOracleData memory od = MarketsFacet(address(diamond)).getMarketOracleData(marketIds[i]);
            conditionIds.push(od.conditionId);
        }
    }

    // --- Helpers ---

    /// @dev Read the wrapped collateral address from Diamond storage via vm.load.
    function _getWrappedCollateral() internal view returns (address) {
        bytes32 storagePos = keccak256("oddmaki.storage.negrisk");
        bytes32 slot = keccak256(abi.encode(address(collateral), storagePos));
        return address(uint160(uint256(vm.load(address(diamond), slot))));
    }

    // =========================================================================
    // C-2 Audit Fix: Reentrancy guard on convertPositions
    // =========================================================================

    function test_convertPositions_blocksReentrantCall() public {
        // indexSet = 0b011 = 3 → markets 0 and 1 are NO positions to convert, market 2 is complementary YES
        uint256 indexSet = 3;
        uint256 amount = 100e6; // USDC-scale (6 decimals)

        // Deploy attacker
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(diamond));

        // Get position IDs so we can seed the attacker with NO tokens
        (uint256[] memory noPositionIds,) =
            NegRiskFacet(address(diamond)).getConversionPositionIds(conditionIds, address(collateral), indexSet);

        // Seed attacker with NO tokens via MockCTF
        for (uint256 i = 0; i < noPositionIds.length; i++) {
            ctf.mintPositionTokens(address(attacker), noPositionIds[i], amount);
        }

        // Approve Diamond to pull attacker's CTF tokens
        vm.prank(address(attacker));
        ctf.setApprovalForAll(address(diamond), true);

        // Seed the WrappedCollateralToken with underlying collateral for release()
        address wrapped = _getWrappedCollateral();
        require(wrapped != address(0), "wrapped collateral not registered");
        collateral.mint(wrapped, 1000e6);

        // Execute the attack
        attacker.attack(conditionIds, address(collateral), indexSet, amount);

        // Assert: reentrancy was blocked by the nonReentrant modifier
        assertTrue(attacker.reentrancyBlocked(), "reentrancy should be blocked by nonReentrant");
    }
}

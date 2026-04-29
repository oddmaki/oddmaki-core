// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
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
import {WrappedCollateralToken} from "../src/tokens/WrappedCollateralToken.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

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

    // =========================================================================
    // C-02 Audit Fix: convertPositions must reject attacker-controlled CTF conditions
    // =========================================================================
    //
    // Exploit: Gnosis CTF.prepareCondition is permissionless. Without validation, an
    // attacker can prepare a condition with themselves as oracle, mint fake YES/NO
    // tokens against the group's WCT, and call convertPositions to drain the
    // wrapped-collateral reserve. This test verifies the conversion path rejects
    // any conditionId that was not registered as a neg-risk market by the Diamond.

    function test_convertPositions_rejectsAttackerControlledConditionIds() public {
        address wrapped = _getWrappedCollateral();
        require(wrapped != address(0), "wrapped collateral not registered");

        // Simulate legitimate prior usage: real users have wrapped $10k into the WCT reserve.
        collateral.mint(wrapped, 10_000e6);

        address attacker = makeAddr("attacker");

        // Attacker prepares 3 CTF conditions with themselves as oracle.
        // conditionIds[0] → yields complementary YES (mint path); [1], [2] → NOs to burn.
        uint256 numFakes = 3;
        bytes32[] memory fakeConditionIds = new bytes32[](numFakes);
        for (uint256 i = 0; i < numFakes; i++) {
            bytes32 qid = keccak256(abi.encode("attacker question", i));
            fakeConditionIds[i] = ctf.getConditionId(attacker, qid, 2);
            vm.prank(attacker);
            ctf.prepareCondition(attacker, qid, 2);
        }

        uint256 amount = 100e6;
        // indexSet 0b110: bits 1,2 set → 2 NO inputs; bit 0 unset → 1 YES output.
        // Engages the release path (noCount=2 > 1) while still exercising mint + split.
        uint256 indexSet = 6;

        // Attacker wraps USDC → WCT; splits WCT into fake NO tokens they need to supply.
        uint256 wrapAmount = 2 * amount; // need NOs for 2 fake conditions
        collateral.mint(attacker, wrapAmount);
        vm.startPrank(attacker);
        collateral.approve(wrapped, wrapAmount);
        WrappedCollateralToken(wrapped).wrap(attacker, wrapAmount);

        WrappedCollateralToken(wrapped).approve(address(ctf), wrapAmount);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        for (uint256 i = 1; i < numFakes; i++) {
            ctf.splitPosition(IERC20(wrapped), bytes32(0), fakeConditionIds[i], partition, amount);
        }

        ctf.setApprovalForAll(address(diamond), true);

        uint256 reserveAfterWrap = collateral.balanceOf(wrapped); // baseline after wrap, pre-attack
        uint256 attackerUsdcAfterWrap = collateral.balanceOf(attacker);

        // After fix: must revert — fake conditionIds are not registered as neg-risk conditions.
        // Before fix: call succeeds and release() pays (2-1)*amount USDC to attacker.
        vm.expectRevert();
        NegRiskFacet(address(diamond)).convertPositions(fakeConditionIds, address(collateral), indexSet, amount);
        vm.stopPrank();

        // Reserve must be unchanged, attacker must not have received any collateral.
        assertEq(
            collateral.balanceOf(wrapped),
            reserveAfterWrap,
            "WCT reserve drained by attacker-controlled conditionIds"
        );
        assertEq(
            collateral.balanceOf(attacker),
            attackerUsdcAfterWrap,
            "attacker received USDC from release() via fake conditions"
        );
    }

    // =========================================================================
    // C-03 Audit Fix: convertPositions must reject duplicate conditionIds
    // =========================================================================
    //
    // Exploit: convertPositions accepts a caller-supplied conditionIds[] array
    // and releases (noCount - 1) * amount WCT without enforcing uniqueness. If
    // the same conditionId appears twice among the NO inputs, the release math
    // sees noCount=2 and pays out 1*amount collateral while only one unique NO
    // position was genuinely burned against backing — looping this drains the
    // WCT reserve. Verify the service rejects duplicates defensively.

    function test_convertPositions_rejectsDuplicateConditionIds() public {
        address wrapped = _getWrappedCollateral();
        require(wrapped != address(0), "wrapped collateral not registered");

        // Seed WCT reserve so release() would succeed if duplicate detection were missing.
        collateral.mint(wrapped, 10_000e6);

        address attacker = makeAddr("attacker");
        uint256 amount = 100e6;

        // [A, A, C]: conditionIds[0] duplicated as a NO input; conditionIds[2] is the YES output.
        bytes32[] memory dupConditionIds = new bytes32[](3);
        dupConditionIds[0] = conditionIds[0];
        dupConditionIds[1] = conditionIds[0]; // DUPLICATE
        dupConditionIds[2] = conditionIds[2];

        // indexSet = 0b011: bits 0,1 mark the duplicated A's as NO inputs; bit 2 marks C as YES output.
        uint256 indexSet = 3;

        // Mint 2*amount NO[A] to the attacker so the facet-level batch transfer would succeed
        // pre-fix. The duplicate check must revert before any collateral is released.
        bytes32[] memory singleA = new bytes32[](1);
        singleA[0] = conditionIds[0];
        (uint256[] memory posNoA,) =
            NegRiskFacet(address(diamond)).getConversionPositionIds(singleA, address(collateral), 1);
        ctf.mintPositionTokens(attacker, posNoA[0], 2 * amount);

        vm.startPrank(attacker);
        ctf.setApprovalForAll(address(diamond), true);

        uint256 reserveBefore = collateral.balanceOf(wrapped);
        uint256 attackerUsdcBefore = collateral.balanceOf(attacker);

        // After fix: revert on duplicate conditionId. Before fix: release(1*amount) succeeds.
        vm.expectRevert();
        NegRiskFacet(address(diamond)).convertPositions(dupConditionIds, address(collateral), indexSet, amount);
        vm.stopPrank();

        assertEq(
            collateral.balanceOf(wrapped),
            reserveBefore,
            "WCT reserve drained via duplicate-conditionId path"
        );
        assertEq(
            collateral.balanceOf(attacker),
            attackerUsdcBefore,
            "attacker received USDC via duplicate-conditionId release"
        );
    }

    /// @notice The view path used for approvals/UX must surface the duplicate rejection too,
    ///         so callers cannot silently pre-compute position IDs for an invalid batch.
    function test_getConversionPositionIds_rejectsDuplicateConditionIds() public {
        bytes32[] memory dupConditionIds = new bytes32[](3);
        dupConditionIds[0] = conditionIds[0];
        dupConditionIds[1] = conditionIds[1];
        dupConditionIds[2] = conditionIds[1]; // DUPLICATE in the YES-output slice

        uint256 indexSet = 1; // only bit 0 set -> conditionIds[0] is NO input

        vm.expectRevert();
        NegRiskFacet(address(diamond)).getConversionPositionIds(dupConditionIds, address(collateral), indexSet);
    }
}

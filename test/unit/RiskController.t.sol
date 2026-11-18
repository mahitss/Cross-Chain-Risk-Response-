// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {RiskController} from "../../src/origin/RiskController.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract RiskControllerTest is Test {
    RiskController controller;
    address owner = address(0xAA);
    address vault = address(0xBB);
    address user = address(0xCC);
    bytes32 positionId = keccak256("position-1");

    function setUp() public {
        vm.prank(owner);
        controller = new RiskController(owner, 8000); // 80% LTV threshold

        vm.prank(owner);
        controller.setAuthorizedVault(vault, true);
    }

    function testInitialThreshold() public view {
        assertEq(controller.riskThresholdBps(), 8000);
    }

    function testAssessRiskHealthy() public {
        // Collateral $10,000, Debt $5,000 -> LTV = 50% (5000 bps)
        vm.prank(vault);
        (bool isBreached, uint256 ltvBps, uint256 nonce) = controller.assessRisk(positionId, user, 10_000e8, 5_000e8);

        assertFalse(isBreached);
        assertEq(ltvBps, 5000);
        assertEq(nonce, 0);
    }

    function testAssessRiskBreachedIncrementsNonce() public {
        // Collateral $10,000, Debt $8,500 -> LTV = 85% (8500 bps) >= 80%
        vm.prank(vault);
        vm.expectEmit(true, true, true, true);
        emit IRiskController.RiskBreach(positionId, user, 1, 8500, 8000, block.timestamp);

        (bool isBreached, uint256 ltvBps, uint256 nonce) = controller.assessRisk(positionId, user, 10_000e8, 8_500e8);

        assertTrue(isBreached);
        assertEq(ltvBps, 8500);
        assertEq(nonce, 1);
        assertEq(controller.positionNonce(positionId), 1);

        // Subsequent breach on same position increments nonce monotonically to 2
        vm.prank(vault);
        (,, uint256 nonce2) = controller.assessRisk(positionId, user, 10_000e8, 9_000e8);
        assertEq(nonce2, 2);
        assertEq(controller.positionNonce(positionId), 2);
    }

    function testAssessRiskZeroCollateralWithDebt() public {
        vm.prank(vault);
        (bool isBreached, uint256 ltvBps, uint256 nonce) = controller.assessRisk(positionId, user, 0, 1000e8);

        assertTrue(isBreached);
        assertEq(ltvBps, 10_000); // 100%
        assertEq(nonce, 1);
    }

    function testAssessRiskZeroCollateralZeroDebt() public {
        vm.prank(vault);
        (bool isBreached, uint256 ltvBps, uint256 nonce) = controller.assessRisk(positionId, user, 0, 0);

        assertFalse(isBreached);
        assertEq(ltvBps, 0);
        assertEq(nonce, 0);
    }

    function testRevertWhenUnauthorizedVault() public {
        address intruder = address(0xDD);
        vm.prank(intruder);
        vm.expectRevert(abi.encodeWithSelector(RiskController.UnauthorizedVault.selector, intruder));
        controller.assessRisk(positionId, user, 10_000e8, 9_000e8);
    }

    function testSetRiskThreshold() public {
        vm.prank(owner);
        controller.setRiskThreshold(7500);
        assertEq(controller.riskThresholdBps(), 7500);
    }

    function testRevertWhenInvalidThreshold() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RiskController.InvalidThreshold.selector, 0));
        controller.setRiskThreshold(0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RiskController.InvalidThreshold.selector, 10001));
        controller.setRiskThreshold(10001);
    }

    function testConstructorThresholdBoundaries() public {
        vm.expectRevert(abi.encodeWithSelector(RiskController.InvalidThreshold.selector, 0));
        new RiskController(owner, 0);

        vm.expectRevert(abi.encodeWithSelector(RiskController.InvalidThreshold.selector, 10_001));
        new RiskController(owner, 10_001);

        RiskController cMin = new RiskController(owner, 1);
        assertEq(cMin.riskThresholdBps(), 1);

        RiskController cMax = new RiskController(owner, 10_000);
        assertEq(cMax.riskThresholdBps(), 10_000);
    }

    /* -------------------------------------------------------------------------- */
    /*               M003.1 CANONICAL RISK ENGINE & RECOVERY TESTS               */
    /* -------------------------------------------------------------------------- */

    function testRoundingBoundaryConditions() public view {
        // Collateral $10,000 (10_000e8)
        uint256 col = 10_000e8;

        // Debt $7,999 (7_999e8) -> 7,999 * 10,000 / 10,000 = 7,999 bps < 8,000 bps (Healthy)
        uint256 ltvBelow = controller.calculateLtvBps(col, 7_999e8);
        assertEq(ltvBelow, 7999);

        // Debt $8,000 (8_000e8) -> exactly 8,000 bps == threshold (Breached)
        uint256 ltvExact = controller.calculateLtvBps(col, 8_000e8);
        assertEq(ltvExact, 8000);

        // Debt $8,001 (8_001e8) -> 8,001 bps > threshold (Breached)
        uint256 ltvAbove = controller.calculateLtvBps(col, 8_001e8);
        assertEq(ltvAbove, 8001);
    }

    function testThresholdEqualityBreaches() public {
        // Threshold equality: LTV == riskThresholdBps MUST be treated as a breach
        vm.prank(vault);
        (bool isBreached, uint256 ltvBps, uint256 nonce) = controller.assessRisk(positionId, user, 10_000e8, 8_000e8);

        assertTrue(isBreached, "Threshold equality must trigger breach");
        assertEq(ltvBps, 8000);
        assertEq(nonce, 1);
        assertTrue(controller.isPositionBreached(positionId));
    }

    function testDustCollateralAndDebtCalculations() public view {
        // Dust debt ($0.00000001) against large collateral ($10,000)
        uint256 ltvDustDebt = controller.calculateLtvBps(10_000e8, 1);
        assertEq(ltvDustDebt, 0, "Dust debt should truncate to 0 bps");

        // Dust collateral ($0.00000001) against debt ($100) -> astronomical LTV > 10,000 bps
        uint256 ltvDustCol = controller.calculateLtvBps(1, 100e8);
        assertTrue(ltvDustCol >= 10_000, "Dust collateral must exceed max scale");

        // Zero collateral, positive dust debt
        uint256 ltvZeroCol = controller.calculateLtvBps(0, 1);
        assertEq(ltvZeroCol, 10_000, "Zero collateral with dust debt must return 10,000 bps");

        // Positive collateral, zero debt
        uint256 ltvZeroDebt = controller.calculateLtvBps(10_000e8, 0);
        assertEq(ltvZeroDebt, 0, "Zero debt must return 0 bps");
    }

    function testArithmeticOverflowBoundaryHandling() public view {
        // Massive debt that would cause debtValueUsd * 10,000 to overflow uint256
        uint256 overflowDebt = type(uint256).max / 100;
        uint256 ltvMassive = controller.calculateLtvBps(10_000e8, overflowDebt);
        assertEq(ltvMassive, type(uint256).max, "Massive debt must return max uint256 without reverting");

        uint256 maxDebt = type(uint256).max;
        uint256 ltvMax = controller.calculateLtvBps(10_000e8, maxDebt);
        assertEq(ltvMax, type(uint256).max, "Max debt must return max uint256 without reverting");
    }

    function testRepeatedHealthyAssessmentsDoNotIncrementNonce() public {
        vm.startPrank(vault);
        for (uint256 i = 0; i < 5; i++) {
            (bool isBreached, uint256 ltv, uint256 nonce) = controller.assessRisk(positionId, user, 10_000e8, 5_000e8);
            assertFalse(isBreached);
            assertEq(ltv, 5000);
            assertEq(nonce, 0);
            assertEq(controller.positionNonce(positionId), 0);
        }
        vm.stopPrank();
    }

    function testRepeatedBreachAssessmentsIncrementNonceMonotonically() public {
        vm.startPrank(vault);
        for (uint256 i = 1; i <= 5; i++) {
            (bool isBreached, uint256 ltv, uint256 nonce) = controller.assessRisk(positionId, user, 10_000e8, 8_500e8);
            assertTrue(isBreached);
            assertEq(ltv, 8500);
            assertEq(nonce, i);
            assertEq(controller.positionNonce(positionId), i);
        }
        vm.stopPrank();
    }

    function testRecoveryLifecycleFromBreachedToHealthyEmitsRiskResolved() public {
        vm.startPrank(vault);

        // Step 1: Position is breached (LTV = 8500 bps)
        (bool breached, uint256 ltv1, uint256 nonce1) = controller.assessRisk(positionId, user, 10_000e8, 8_500e8);
        assertTrue(breached);
        assertEq(ltv1, 8500);
        assertEq(nonce1, 1);
        assertTrue(controller.isPositionBreached(positionId));

        // Step 2: User remedies position (collateral increases to $20,000 -> LTV drops to 4250 bps)
        vm.expectEmit(true, true, true, true);
        emit IRiskController.RiskResolved(positionId, user, 2, 4250, 8000, block.timestamp);

        (bool recovered, uint256 ltv2, uint256 nonce2) = controller.assessRisk(positionId, user, 20_000e8, 8_500e8);
        assertFalse(recovered, "Position must now be healthy");
        assertEq(ltv2, 4250);
        assertEq(nonce2, 2, "Recovery must increment monotonic nonce");
        assertFalse(controller.isPositionBreached(positionId));

        // Step 3: Subsequent healthy evaluation does NOT emit RiskResolved again
        (bool stillHealthy, uint256 ltv3, uint256 nonce3) = controller.assessRisk(positionId, user, 20_000e8, 8_500e8);
        assertFalse(stillHealthy);
        assertEq(ltv3, 4250);
        assertEq(nonce3, 2, "Nonce must remain at 2 when healthy state is unchanged");
        vm.stopPrank();
    }

    function testFuzzCalculateLtvNeverReverts(uint256 col, uint256 debt) public view {
        // calculateLtvBps must execute without arithmetic overflow / revert under all inputs
        uint256 ltv = controller.calculateLtvBps(col, debt);
        if (debt == 0) {
            assertEq(ltv, 0);
        } else if (col == 0) {
            assertEq(ltv, 10_000);
        }
    }
}

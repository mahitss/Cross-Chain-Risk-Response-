// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {RiskController} from "../../src/origin/RiskController.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";
import {CrossGuardIdentity} from "../../src/libraries/CrossGuardIdentity.sol";

contract RiskControllerTest is Test {
    RiskController controller;
    address owner = address(0xAA);
    address vault = address(0xBB);
    address user = address(0xCC);
    bytes32 constant SALT = keccak256("position-salt-1");
    bytes32 positionId;

    function setUp() public {
        vm.prank(owner);
        controller = new RiskController(owner, 8000); // 80% LTV threshold

        vm.prank(owner);
        controller.setAuthorizedVault(vault, true);

        positionId = controller.computePositionId(vault, user, SALT);
        vm.prank(vault);
        controller.registerPositionIdentity(positionId, user, SALT);
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
        emit IRiskController.RiskBreach(
            positionId, user, 1, CrossGuardIdentity.IDENTITY_VERSION, vault, SALT, 8500, 8000, block.timestamp
        );

        (bool isBreached, uint256 ltvBps, uint256 nonce) = controller.assessRisk(positionId, user, 10_000e8, 8_500e8);

        assertTrue(isBreached);
        assertEq(ltvBps, 8500);
        assertEq(nonce, 1);
        assertEq(controller.positionNonce(positionId), 1);

        // Subsequent breach on same position does not increment nonce (Idempotency)
        vm.prank(vault);
        (,, uint256 nonce2) = controller.assessRisk(positionId, user, 10_000e8, 9_000e8);
        assertEq(nonce2, 1);
        assertEq(controller.positionNonce(positionId), 1);
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

        // Owner is also rejected unless explicitly authorized as a vault
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RiskController.UnauthorizedVault.selector, owner));
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

    function testRoundingBoundaryConditions() public view {
        uint256 col = 10_000e8;

        uint256 ltvBelow = controller.calculateLtvBps(col, 7_999e8);
        assertEq(ltvBelow, 7999);

        uint256 ltvExact = controller.calculateLtvBps(col, 8_000e8);
        assertEq(ltvExact, 8000);

        uint256 ltvAbove = controller.calculateLtvBps(col, 8_001e8);
        assertEq(ltvAbove, 8001);
    }

    function testThresholdEqualityBreaches() public {
        vm.prank(vault);
        (bool isBreached, uint256 ltvBps, uint256 nonce) = controller.assessRisk(positionId, user, 10_000e8, 8_000e8);

        assertTrue(isBreached, "Threshold equality must trigger breach");
        assertEq(ltvBps, 8000);
        assertEq(nonce, 1);
        assertTrue(controller.isPositionBreached(positionId));
    }

    function testDustCollateralAndDebtCalculations() public view {
        uint256 ltvDustDebt = controller.calculateLtvBps(10_000e8, 1);
        assertEq(ltvDustDebt, 0, "Dust debt should truncate to 0 bps");

        uint256 ltvDustCol = controller.calculateLtvBps(1, 100e8);
        assertTrue(ltvDustCol >= 10_000, "Dust collateral must exceed max scale");

        uint256 ltvZeroCol = controller.calculateLtvBps(0, 1);
        assertEq(ltvZeroCol, 10_000, "Zero collateral with dust debt must return 10,000 bps");

        uint256 ltvZeroDebt = controller.calculateLtvBps(10_000e8, 0);
        assertEq(ltvZeroDebt, 0, "Zero debt must return 0 bps");
    }

    function testArithmeticOverflowBoundaryHandling() public view {
        uint256 overflowDebt = type(uint256).max / 100;
        uint256 ltvMassive = controller.calculateLtvBps(10_000e8, overflowDebt);
        assertEq(ltvMassive, overflowDebt / 1e8, "Massive debt with representable quotient must be exact");

        uint256 largeDebt = (type(uint256).max / 10_000) * 2;
        uint256 largeCol = (type(uint256).max / 10_000) * 4;
        uint256 ltvProportional = controller.calculateLtvBps(largeCol, largeDebt);
        assertEq(ltvProportional, 5000, "Proportional large values must compute exact 50% (5000 bps) without overflow");

        uint256 maxDebt = type(uint256).max;
        uint256 ltvUnrepresentable = controller.calculateLtvBps(100, maxDebt);
        assertEq(
            ltvUnrepresentable,
            type(uint256).max,
            "Unrepresentable quotient must deterministically cap at type(uint256).max"
        );
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

    function testRepeatedBreachAssessmentsDoNotIncrementNonceOrEmitEvents() public {
        vm.startPrank(vault);
        vm.expectEmit(true, true, true, true);
        emit IRiskController.RiskBreach(
            positionId, user, 1, CrossGuardIdentity.IDENTITY_VERSION, vault, SALT, 8500, 8000, block.timestamp
        );
        (bool isBreached, uint256 ltv, uint256 nonce) = controller.assessRisk(positionId, user, 10_000e8, 8_500e8);
        assertTrue(isBreached);
        assertEq(ltv, 8500);
        assertEq(nonce, 1);
        assertEq(controller.positionNonce(positionId), 1);

        vm.recordLogs();
        for (uint256 i = 0; i < 5; i++) {
            (bool stillBreached,, uint256 repeatNonce) =
                controller.assessRisk(positionId, user, 10_000e8, 8_500e8 + i * 100e8);
            assertTrue(stillBreached);
            assertEq(repeatNonce, 1);
            assertEq(controller.positionNonce(positionId), 1);
        }
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 0, "No RiskBreach events should be emitted during repeated breached assessments");
        vm.stopPrank();
    }

    function testLaterNewBreachIncrementsNonceAgain() public {
        vm.startPrank(vault);
        controller.assessRisk(positionId, user, 10_000e8, 8_500e8);
        assertEq(controller.positionNonce(positionId), 1);
        assertTrue(controller.isPositionBreached(positionId));

        controller.assessRisk(positionId, user, 20_000e8, 8_500e8);
        assertEq(controller.positionNonce(positionId), 2);
        assertFalse(controller.isPositionBreached(positionId));

        controller.assessRisk(positionId, user, 20_000e8, 8_500e8);
        assertEq(controller.positionNonce(positionId), 2);

        vm.expectEmit(true, true, true, true);
        emit IRiskController.RiskBreach(
            positionId, user, 3, CrossGuardIdentity.IDENTITY_VERSION, vault, SALT, 8500, 8000, block.timestamp
        );
        (bool breachedAgain,, uint256 nonce3) = controller.assessRisk(positionId, user, 10_000e8, 8_500e8);
        assertTrue(breachedAgain);
        assertEq(nonce3, 3);
        assertEq(controller.positionNonce(positionId), 3);
        assertTrue(controller.isPositionBreached(positionId));
        vm.stopPrank();
    }

    function testSeparatePositionsMaintainSeparateNonceSequences() public {
        bytes32 saltB = keccak256("salt-B");
        address userB = address(0xEE);
        bytes32 posA = positionId;
        bytes32 posB = controller.computePositionId(vault, userB, saltB);

        vm.startPrank(vault);
        controller.registerPositionIdentity(posB, userB, saltB);

        (,, uint256 nonceA1) = controller.assessRisk(posA, user, 10_000e8, 8_500e8);
        assertEq(nonceA1, 1);
        assertEq(controller.positionNonce(posA), 1);
        assertEq(controller.positionNonce(posB), 0);

        (,, uint256 nonceA1_rep) = controller.assessRisk(posA, user, 10_000e8, 9_000e8);
        assertEq(nonceA1_rep, 1);

        (,, uint256 nonceB1) = controller.assessRisk(posB, userB, 10_000e8, 8_500e8);
        assertEq(nonceB1, 1);
        assertEq(controller.positionNonce(posB), 1);
        assertEq(controller.positionNonce(posA), 1);

        (,, uint256 nonceA2) = controller.assessRisk(posA, user, 20_000e8, 8_500e8);
        assertEq(nonceA2, 2);
        assertEq(controller.positionNonce(posA), 2);
        assertEq(controller.positionNonce(posB), 1);
        vm.stopPrank();
    }

    function testRiskThresholdUpdateRespectedAtNextEvaluation() public {
        vm.prank(vault);
        (bool breached1,, uint256 nonce1) = controller.assessRisk(positionId, user, 10_000e8, 7_500e8);
        assertFalse(breached1);
        assertEq(nonce1, 0);

        vm.prank(owner);
        controller.setRiskThreshold(7000);

        vm.prank(vault);
        vm.expectEmit(true, true, true, true);
        emit IRiskController.RiskBreach(
            positionId, user, 1, CrossGuardIdentity.IDENTITY_VERSION, vault, SALT, 7500, 7000, block.timestamp
        );
        (bool breached2,, uint256 nonce2) = controller.assessRisk(positionId, user, 10_000e8, 7_500e8);
        assertTrue(breached2);
        assertEq(nonce2, 1);
        assertEq(controller.positionNonce(positionId), 1);
    }

    function testRecoveryLifecycleFromBreachedToHealthyEmitsRiskResolved() public {
        vm.startPrank(vault);

        (bool breached, uint256 ltv1, uint256 nonce1) = controller.assessRisk(positionId, user, 10_000e8, 8_500e8);
        assertTrue(breached);
        assertEq(ltv1, 8500);
        assertEq(nonce1, 1);
        assertTrue(controller.isPositionBreached(positionId));

        vm.expectEmit(true, true, true, true);
        emit IRiskController.RiskResolved(
            positionId, user, 2, CrossGuardIdentity.IDENTITY_VERSION, vault, SALT, 4250, 8000, block.timestamp
        );

        (bool recovered, uint256 ltv2, uint256 nonce2) = controller.assessRisk(positionId, user, 20_000e8, 8_500e8);
        assertFalse(recovered, "Position must now be healthy");
        assertEq(ltv2, 4250);
        assertEq(nonce2, 2, "Recovery must increment monotonic nonce");
        assertFalse(controller.isPositionBreached(positionId));

        (bool stillHealthy, uint256 ltv3, uint256 nonce3) = controller.assessRisk(positionId, user, 20_000e8, 8_500e8);
        assertFalse(stillHealthy);
        assertEq(ltv3, 4250);
        assertEq(nonce3, 2, "Nonce must remain at 2 when healthy state is unchanged");
        vm.stopPrank();
    }

    function testFuzzCalculateLtvNeverReverts(uint256 col, uint256 debt) public view {
        uint256 ltv = controller.calculateLtvBps(col, debt);
        if (debt == 0) {
            assertEq(ltv, 0);
        } else if (col == 0) {
            assertEq(ltv, 10_000);
        }
    }

    function testRevertAssessRiskZeroPositionId() public {
        vm.prank(vault);
        vm.expectRevert(RiskController.InvalidPositionId.selector);
        controller.assessRisk(bytes32(0), user, 10_000e8, 5000e8);
    }
}

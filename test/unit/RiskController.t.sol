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
        (bool isBreached, uint256 ltvBps) = controller.assessRisk(positionId, user, 10_000e8, 5_000e8);

        assertFalse(isBreached);
        assertEq(ltvBps, 5000);
    }

    function testAssessRiskBreached() public {
        // Collateral $10,000, Debt $8,500 -> LTV = 85% (8500 bps) >= 80%
        vm.prank(vault);
        vm.expectEmit(true, true, false, true);
        emit IRiskController.RiskBreach(positionId, user, 8500, 8000, block.timestamp);

        (bool isBreached, uint256 ltvBps) = controller.assessRisk(positionId, user, 10_000e8, 8_500e8);

        assertTrue(isBreached);
        assertEq(ltvBps, 8500);
    }

    function testAssessRiskZeroCollateralWithDebt() public {
        vm.prank(vault);
        (bool isBreached, uint256 ltvBps) = controller.assessRisk(positionId, user, 0, 1000e8);

        assertTrue(isBreached);
        assertEq(ltvBps, 10_000); // 100%
    }

    function testAssessRiskZeroCollateralZeroDebt() public {
        vm.prank(vault);
        (bool isBreached, uint256 ltvBps) = controller.assessRisk(positionId, user, 0, 0);

        assertFalse(isBreached);
        assertEq(ltvBps, 0);
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
}

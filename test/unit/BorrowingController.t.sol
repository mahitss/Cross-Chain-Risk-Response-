// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {BorrowingController} from "../../src/destination/BorrowingController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract BorrowingControllerTest is Test {
    BorrowingController controller;
    address owner = address(0xAA);
    address callbackAdapter = address(0xBB);
    address borrower = address(0xCC);
    bytes32 positionId = keccak256("position-1");

    function setUp() public {
        vm.startPrank(owner);
        controller = new BorrowingController(owner);
        controller.setCallbackAdapter(callbackAdapter);
        vm.stopPrank();
    }

    function testBorrowWhenUnpaused() public {
        vm.prank(borrower);
        controller.borrow(positionId, 1000e18);

        assertEq(controller.positionBorrowDebt(positionId), 1000e18);
        assertFalse(controller.isBorrowingPaused(positionId));
    }

    function testPauseBorrowingByCallbackAdapter() public {
        uint256 timestamp = block.timestamp;
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 8500, timestamp);

        assertTrue(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastRiskBreachTimestamp(positionId), timestamp);
    }

    function testRevertBorrowWhenPaused() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 8500, block.timestamp);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.BorrowingIsPaused.selector, positionId));
        controller.borrow(positionId, 500e18);
    }

    function testIdempotentPause() public {
        uint256 t1 = 1000;
        uint256 t2 = 1050;

        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 8500, t1);
        assertTrue(controller.isBorrowingPaused(positionId));

        // Subsequent breach at newer timestamp updates successfully
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 9000, t2);
        assertTrue(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastRiskBreachTimestamp(positionId), t2);
    }

    function testRevertWhenStaleTimestamp() public {
        uint256 t1 = 1000;
        uint256 tOld = 900;

        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 8500, t1);

        vm.prank(callbackAdapter);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.StaleRiskBreach.selector, tOld, t1));
        controller.pauseBorrowing(positionId, 8500, tOld);
    }

    function testRevertWhenUnauthorizedCallerPauses() public {
        address stranger = address(0xEE);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedCallback.selector, stranger));
        controller.pauseBorrowing(positionId, 8500, block.timestamp);
    }

    function testResumeBorrowingByOwner() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 8500, block.timestamp);
        assertTrue(controller.isBorrowingPaused(positionId));

        // Owner unpauses
        vm.prank(owner);
        controller.resumeBorrowing(positionId);
        assertFalse(controller.isBorrowingPaused(positionId));

        // Borrower can borrow again
        vm.prank(borrower);
        controller.borrow(positionId, 500e18);
        assertEq(controller.positionBorrowDebt(positionId), 500e18);
    }
}

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
    address impostor = address(0xDD);
    bytes32 positionId = keccak256("position-1");

    function setUp() public {
        vm.startPrank(owner);
        controller = new BorrowingController(owner);
        controller.setCallbackAdapter(callbackAdapter);
        vm.stopPrank();

        // Borrower registers position
        vm.prank(borrower);
        controller.registerPosition(positionId);
    }

    function testBorrowWhenUnpausedAndOwner() public {
        vm.prank(borrower);
        controller.borrow(positionId, 1000e18);

        assertEq(controller.positionBorrowDebt(positionId), 1000e18);
        assertFalse(controller.isBorrowingPaused(positionId));
    }

    function testRevertWhenBorrowingOnUnregisteredPosition() public {
        bytes32 unknownPos = keccak256("unknown-position");
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnregisteredPosition.selector, unknownPos));
        controller.borrow(unknownPos, 500e18);
    }

    function testRevertWhenUnauthorizedBorrower() public {
        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedBorrower.selector, impostor, borrower));
        controller.borrow(positionId, 500e18);
    }

    function testRevertWhenRegisteringAlreadyRegisteredPosition() public {
        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.PositionAlreadyRegistered.selector, positionId));
        controller.registerPosition(positionId);
    }

    function testRegisterPositionForAdmin() public {
        bytes32 pos2 = keccak256("pos-2");
        vm.prank(owner);
        controller.registerPositionFor(pos2, borrower);

        assertEq(controller.positionOwners(pos2), borrower);
    }

    function testPauseBorrowingByCallbackAdapterWithNonce() public {
        uint256 timestamp = 1000;
        uint256 nonce = 1;

        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, nonce, 8500, timestamp);

        assertTrue(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastProcessedNonce(positionId), nonce);
        assertEq(controller.lastRiskBreachTimestamp(positionId), timestamp);
    }

    function testRevertWhenDuplicateNonce() public {
        vm.startPrank(callbackAdapter);
        controller.pauseBorrowing(positionId, 1, 8500, 1000);

        // Attempting to submit same nonce 1 again reverts
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 1, 1));
        controller.pauseBorrowing(positionId, 1, 8500, 1050);
        vm.stopPrank();
    }

    function testRevertWhenOutdatedNonce() public {
        vm.startPrank(callbackAdapter);
        controller.pauseBorrowing(positionId, 5, 8500, 1000);

        // Attempting to submit older nonce (e.g. 3) reverts
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 3, 5));
        controller.pauseBorrowing(positionId, 3, 8500, 1050);
        vm.stopPrank();
    }

    function testSameTimestampWithNewerNonceSucceeds() public {
        uint256 sameTimestamp = 2000;

        vm.startPrank(callbackAdapter);
        controller.pauseBorrowing(positionId, 1, 8500, sameTimestamp);
        assertEq(controller.lastProcessedNonce(positionId), 1);

        // Within same timestamp block, next sequential nonce 2 succeeds
        controller.pauseBorrowing(positionId, 2, 9000, sameTimestamp);
        assertEq(controller.lastProcessedNonce(positionId), 2);
        vm.stopPrank();
    }

    function testRevertWhenNonCallbackCallsPauseBorrowing() public {
        // Even contract owner cannot call pauseBorrowing (strictly callback adapter only)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedCallback.selector, owner));
        controller.pauseBorrowing(positionId, 1, 8500, block.timestamp);

        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedCallback.selector, impostor));
        controller.pauseBorrowing(positionId, 1, 8500, block.timestamp);
    }

    function testEmergencyPauseAndResumeByOwner() public {
        // Emergency circuit breaker can be triggered by owner
        vm.prank(owner);
        controller.emergencyPauseBorrowing(positionId);
        assertTrue(controller.isBorrowingPaused(positionId));

        // Borrow reverts when paused
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.BorrowingIsPaused.selector, positionId));
        controller.borrow(positionId, 100e18);

        // Owner resumes borrowing
        vm.prank(owner);
        controller.resumeBorrowing(positionId);
        assertFalse(controller.isBorrowingPaused(positionId));

        // Borrower can borrow again
        vm.prank(borrower);
        controller.borrow(positionId, 100e18);
        assertEq(controller.positionBorrowDebt(positionId), 100e18);
    }
}

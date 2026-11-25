// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {BorrowingController} from "../../src/destination/BorrowingController.sol";
import {IBorrowingController} from "../../src/interfaces/IBorrowingController.sol";
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

    /* -------------------------------------------------------------------------- */
    /*               M003.1 RECOVERY STATE MACHINE & ACCESS CONTROL TESTS         */
    /* -------------------------------------------------------------------------- */

    function testOrdinaryOwnerResumeCannotBypassActiveRiskBreach() public {
        // Position paused by cross-chain callback due to risk breach
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 1, 8500, 1000);
        assertTrue(controller.isBorrowingPaused(positionId));
        assertTrue(controller.pausedByRiskBreach(positionId));

        // Ordinary owner resume must REVERT
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.CannotBypassActiveRiskBreach.selector, positionId));
        controller.resumeBorrowing(positionId);

        // Position remains safely paused
        assertTrue(controller.isBorrowingPaused(positionId));
    }

    function testValidRecoveryViaCallbackAdapter() public {
        // 1. Position paused by breach
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 1, 8500, 1000);

        // 2. Cross-chain recovery callback arrives with newer nonce
        vm.prank(callbackAdapter);
        vm.expectEmit(true, true, true, true);
        emit IBorrowingController.RiskBreachResolved(positionId, 2, 4500, 2000);

        controller.resolveBorrowing(positionId, 2, 4500, 2000);

        assertFalse(controller.isBorrowingPaused(positionId));
        assertFalse(controller.pausedByRiskBreach(positionId));
        assertEq(controller.lastProcessedNonce(positionId), 2);

        // Borrower can safely borrow again
        vm.prank(borrower);
        controller.borrow(positionId, 500e18);
        assertEq(controller.positionBorrowDebt(positionId), 500e18);
    }

    function testRevertResolveBorrowingUnauthorizedCaller() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 1, 8500, 1000);

        // Stranger attempts recovery
        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedCallback.selector, impostor));
        controller.resolveBorrowing(positionId, 2, 4500, 2000);

        // Owner attempts recovery via adapter method directly
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedCallback.selector, owner));
        controller.resolveBorrowing(positionId, 2, 4500, 2000);
    }

    function testRevertResolveBorrowingReplayedNonce() public {
        vm.startPrank(callbackAdapter);
        controller.pauseBorrowing(positionId, 5, 8500, 1000);

        // Replay same nonce 5
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 5, 5));
        controller.resolveBorrowing(positionId, 5, 4500, 2000);

        // Replay older nonce 3
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 3, 5));
        controller.resolveBorrowing(positionId, 3, 4500, 2000);
        vm.stopPrank();
    }

    function testResolveBorrowingWhenNotPausedSucceedsAndSetsNonce() public {
        // Safe out-of-order resolution arrival when not paused succeeds and updates nonce
        vm.prank(callbackAdapter);
        controller.resolveBorrowing(positionId, 1, 4500, 2000);
        assertEq(controller.lastProcessedNonce(positionId), 1);
        assertFalse(controller.isBorrowingPaused(positionId));
        assertFalse(controller.pausedByRiskBreach(positionId));
    }

    function testEmergencyResumeWithAuditReason() public {
        // Paused by breach
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 1, 8500, 1000);

        // Owner emergency override with documented justification
        string memory reason = "Attested off-chain remediation: 10 ETH deposited on Base Sepolia";
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IBorrowingController.EmergencyBorrowingResumed(positionId, owner, reason, block.timestamp);

        controller.emergencyResumeBorrowing(positionId, reason);

        assertFalse(controller.isBorrowingPaused(positionId));
        assertFalse(controller.pausedByRiskBreach(positionId));

        // Borrower can borrow again
        vm.prank(borrower);
        controller.borrow(positionId, 200e18);
        assertEq(controller.positionBorrowDebt(positionId), 200e18);
    }

    function testRevertEmergencyResumeEmptyReasonOrNotPaused() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 1, 8500, 1000);

        // Empty reason reverts
        vm.prank(owner);
        vm.expectRevert(BorrowingController.EmptyEmergencyReason.selector);
        controller.emergencyResumeBorrowing(positionId, "");

        // When position is resumed, emergency resume reverts PositionNotPaused
        vm.prank(owner);
        controller.emergencyResumeBorrowing(positionId, "Valid justification");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.PositionNotPaused.selector, positionId));
        controller.emergencyResumeBorrowing(positionId, "Another justification");
    }

    function testRevertEmergencyResumeUnauthorizedCaller() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 1, 8500, 1000);

        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, impostor));
        controller.emergencyResumeBorrowing(positionId, "Unauthorized call");
    }

    function testRevertWhenZeroPositionIdUsed() public {
        // User registration reverts with InvalidPositionId
        vm.prank(borrower);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.registerPosition(bytes32(0));

        // Admin registration reverts with InvalidPositionId
        vm.prank(owner);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.registerPositionFor(bytes32(0), borrower);

        // Borrow reverts with InvalidPositionId
        vm.prank(borrower);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.borrow(bytes32(0), 100e18);

        // Callback pause reverts with InvalidPositionId
        vm.prank(callbackAdapter);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.pauseBorrowing(bytes32(0), 1, 8500, 1000);

        // Callback resolve reverts with InvalidPositionId
        vm.prank(callbackAdapter);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.resolveBorrowing(bytes32(0), 1, 5000, 1000);

        // Emergency pause reverts with InvalidPositionId
        vm.prank(owner);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.emergencyPauseBorrowing(bytes32(0));

        // Resume borrowing reverts with InvalidPositionId
        vm.prank(owner);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.resumeBorrowing(bytes32(0));

        // Emergency resume reverts with InvalidPositionId
        vm.prank(owner);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.emergencyResumeBorrowing(bytes32(0), "Valid justification");
    }
}

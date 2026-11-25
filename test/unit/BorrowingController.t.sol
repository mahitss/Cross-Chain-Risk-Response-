// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {BorrowingController} from "../../src/destination/BorrowingController.sol";
import {IBorrowingController} from "../../src/interfaces/IBorrowingController.sol";
import {CrossGuardIdentity} from "../../src/libraries/CrossGuardIdentity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract BorrowingControllerTest is Test {
    BorrowingController controller;
    address owner = address(0xAA);
    address callbackAdapter = address(0xBB);
    uint256 constant ORIGIN_CHAIN_ID = 84532;
    address constant ORIGIN_RISK_CTRL = address(0x1111);
    address constant ORIGIN_VAULT = address(0x2222);

    uint256 borrowerPk = 0xB0B1;
    address borrower;
    address borrowerDest = address(0xC0C0);
    address impostor = address(0xDD);

    bytes32 constant SALT_1 = keccak256("position-salt-1");
    bytes32 constant SALT_2 = keccak256("position-salt-2");
    bytes32 positionId;

    function setUp() public {
        borrower = vm.addr(borrowerPk);

        vm.startPrank(owner);
        controller = new BorrowingController(owner, ORIGIN_CHAIN_ID, ORIGIN_RISK_CTRL, ORIGIN_VAULT);
        controller.setCallbackAdapter(callbackAdapter);
        vm.stopPrank();

        // Origin user claims their canonical same-wallet position
        vm.prank(borrower);
        positionId = controller.registerPosition(SALT_1);
    }

    function _msg(bytes32 posId, address originUser, bytes32 salt, uint256 nonce, uint256 ltv, uint256 ts)
        internal
        pure
        returns (CrossGuardIdentity.RiskCallbackMessage memory)
    {
        return CrossGuardIdentity.RiskCallbackMessage({
            identityVersion: CrossGuardIdentity.IDENTITY_VERSION,
            originChainId: ORIGIN_CHAIN_ID,
            originRiskController: ORIGIN_RISK_CTRL,
            originVault: ORIGIN_VAULT,
            originUser: originUser,
            positionId: posId,
            salt: salt,
            nonce: nonce,
            riskLevel: ltv,
            timestamp: ts
        });
    }

    function testBorrowWhenUnpausedAndOwner() public {
        vm.prank(borrower);
        controller.borrow(positionId, 1000e18);

        assertEq(controller.positionBorrowDebt(positionId), 1000e18);
        assertFalse(controller.isBorrowingPaused(positionId));
        assertEq(controller.originUsers(positionId), borrower);
        assertEq(controller.originIdentityHashes(positionId), positionId);
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
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.PositionAlreadyRegistered.selector, positionId));
        controller.registerPosition(SALT_1);

        // Impostor calling same salt generates their own distinct canonical positionId, never colliding with borrower
        vm.prank(impostor);
        bytes32 impostorPos = controller.registerPosition(SALT_1);
        assertTrue(impostorPos != positionId);
        assertEq(controller.positionOwners(positionId), borrower);
        assertEq(controller.positionOwners(impostorPos), impostor);
    }

    function testRegisterPositionWithAuthorizedDelegation() public {
        CrossGuardIdentity.OriginIdentity memory id = CrossGuardIdentity.OriginIdentity({
            originChainId: ORIGIN_CHAIN_ID,
            originRiskController: ORIGIN_RISK_CTRL,
            originVault: ORIGIN_VAULT,
            originUser: borrower,
            salt: SALT_2
        });
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = controller.computeAuthorizePositionDigest(id, borrowerDest, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(borrowerPk, digest);

        // Any relayer can submit the signed authorization, binding destinationOwner = borrowerDest
        vm.prank(impostor);
        bytes32 pos2 =
            controller.registerPositionWithAuthorization(id, borrowerDest, deadline, abi.encodePacked(r, s, v));

        assertEq(controller.positionOwners(pos2), borrowerDest);
        assertEq(controller.originUsers(pos2), borrower);
        assertEq(controller.sigNonces(borrower), 1);

        // borrowerDest can borrow; impostor cannot
        vm.prank(borrowerDest);
        controller.borrow(pos2, 250e18);
        assertEq(controller.positionBorrowDebt(pos2), 250e18);
    }

    function testPauseBorrowingByCallbackAdapterWithNonce() public {
        uint256 timestamp = 1000;
        uint256 nonce = 1;

        vm.prank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, nonce, 8500, timestamp));

        assertTrue(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastProcessedNonce(positionId), nonce);
        assertEq(controller.lastRiskBreachTimestamp(positionId), timestamp);
    }

    function testRevertWhenDuplicateNonce() public {
        vm.startPrank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, 1, 8500, 1000));

        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 1, 1));
        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, 1, 8500, 1050));
        vm.stopPrank();
    }

    function testRevertWhenOutdatedNonce() public {
        vm.startPrank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, 5, 8500, 1000));

        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 3, 5));
        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, 3, 8500, 1050));
        vm.stopPrank();
    }

    function testSameTimestampWithNewerNonceSucceeds() public {
        uint256 sameTimestamp = 2000;

        vm.startPrank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, 1, 8500, sameTimestamp));
        assertEq(controller.lastProcessedNonce(positionId), 1);

        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, 2, 9000, sameTimestamp));
        assertEq(controller.lastProcessedNonce(positionId), 2);
        vm.stopPrank();
    }

    function testRevertWhenNonCallbackCallsPauseBorrowing() public {
        CrossGuardIdentity.RiskCallbackMessage memory msgData =
            _msg(positionId, borrower, SALT_1, 1, 8500, block.timestamp);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedCallback.selector, owner));
        controller.pauseBorrowing(msgData);

        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedCallback.selector, impostor));
        controller.pauseBorrowing(msgData);
    }

    function testEmergencyPauseAndResumeByOwner() public {
        vm.prank(owner);
        controller.emergencyPauseBorrowing(positionId);
        assertTrue(controller.isBorrowingPaused(positionId));

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.BorrowingIsPaused.selector, positionId));
        controller.borrow(positionId, 100e18);

        vm.prank(owner);
        controller.resumeBorrowing(positionId);
        assertFalse(controller.isBorrowingPaused(positionId));

        vm.prank(borrower);
        controller.borrow(positionId, 100e18);
        assertEq(controller.positionBorrowDebt(positionId), 100e18);
    }

    function testOrdinaryOwnerResumeCannotBypassActiveRiskBreach() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, 1, 8500, 1000));
        assertTrue(controller.isBorrowingPaused(positionId));
        assertTrue(controller.pausedByRiskBreach(positionId));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.CannotBypassActiveRiskBreach.selector, positionId));
        controller.resumeBorrowing(positionId);

        assertTrue(controller.isBorrowingPaused(positionId));
    }

    function testValidRecoveryViaCallbackAdapter() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, 1, 8500, 1000));

        vm.prank(callbackAdapter);
        vm.expectEmit(true, true, true, true);
        emit IBorrowingController.RiskBreachResolved(positionId, 2, 4500, 2000);

        controller.resolveBorrowing(_msg(positionId, borrower, SALT_1, 2, 4500, 2000));

        assertFalse(controller.isBorrowingPaused(positionId));
        assertFalse(controller.pausedByRiskBreach(positionId));
        assertEq(controller.lastProcessedNonce(positionId), 2);

        vm.prank(borrower);
        controller.borrow(positionId, 500e18);
        assertEq(controller.positionBorrowDebt(positionId), 500e18);
    }

    function testRevertResolveBorrowingUnauthorizedCaller() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, 1, 8500, 1000));

        CrossGuardIdentity.RiskCallbackMessage memory msg2 = _msg(positionId, borrower, SALT_1, 2, 4500, 2000);
        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedCallback.selector, impostor));
        controller.resolveBorrowing(msg2);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedCallback.selector, owner));
        controller.resolveBorrowing(msg2);
    }

    function testRevertResolveBorrowingReplayedNonce() public {
        vm.startPrank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, 5, 8500, 1000));

        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 5, 5));
        controller.resolveBorrowing(_msg(positionId, borrower, SALT_1, 5, 4500, 2000));

        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 3, 5));
        controller.resolveBorrowing(_msg(positionId, borrower, SALT_1, 3, 4500, 2000));
        vm.stopPrank();
    }

    function testResolveBorrowingWhenNotPausedSucceedsAndSetsNonce() public {
        vm.prank(callbackAdapter);
        controller.resolveBorrowing(_msg(positionId, borrower, SALT_1, 1, 4500, 2000));
        assertEq(controller.lastProcessedNonce(positionId), 1);
        assertFalse(controller.isBorrowingPaused(positionId));
        assertFalse(controller.pausedByRiskBreach(positionId));
    }

    function testEmergencyResumeWithAuditReason() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, 1, 8500, 1000));

        string memory reason = "Attested off-chain remediation: 10 ETH deposited on Base Sepolia";
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IBorrowingController.EmergencyBorrowingResumed(positionId, owner, reason, block.timestamp);

        controller.emergencyResumeBorrowing(positionId, reason);

        assertFalse(controller.isBorrowingPaused(positionId));
        assertFalse(controller.pausedByRiskBreach(positionId));

        vm.prank(borrower);
        controller.borrow(positionId, 200e18);
        assertEq(controller.positionBorrowDebt(positionId), 200e18);
    }

    function testRevertEmergencyResumeEmptyReasonOrNotPaused() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, 1, 8500, 1000));

        vm.prank(owner);
        vm.expectRevert(BorrowingController.EmptyEmergencyReason.selector);
        controller.emergencyResumeBorrowing(positionId, "");

        vm.prank(owner);
        controller.emergencyResumeBorrowing(positionId, "Valid justification");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.PositionNotPaused.selector, positionId));
        controller.emergencyResumeBorrowing(positionId, "Another justification");
    }

    function testRevertEmergencyResumeUnauthorizedCaller() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, borrower, SALT_1, 1, 8500, 1000));

        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, impostor));
        controller.emergencyResumeBorrowing(positionId, "Unauthorized call");
    }

    function testRevertWhenZeroPositionIdOrZeroSaltUsed() public {
        vm.prank(borrower);
        vm.expectRevert(CrossGuardIdentity.InvalidSalt.selector);
        controller.registerPosition(bytes32(0));

        vm.prank(borrower);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.borrow(bytes32(0), 100e18);

        vm.prank(callbackAdapter);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.pauseBorrowing(_msg(bytes32(0), borrower, SALT_1, 1, 8500, 1000));

        vm.prank(callbackAdapter);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.resolveBorrowing(_msg(bytes32(0), borrower, SALT_1, 1, 5000, 1000));

        vm.prank(owner);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.emergencyPauseBorrowing(bytes32(0));

        vm.prank(owner);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.resumeBorrowing(bytes32(0));

        vm.prank(owner);
        vm.expectRevert(BorrowingController.InvalidPositionId.selector);
        controller.emergencyResumeBorrowing(bytes32(0), "Valid justification");
    }
}

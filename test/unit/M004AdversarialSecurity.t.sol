// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {BorrowingController} from "../../src/destination/BorrowingController.sol";
import {IBorrowingController} from "../../src/interfaces/IBorrowingController.sol";
import {CrossGuardCallback} from "../../src/destination/CrossGuardCallback.sol";
import {MockCallbackProxy} from "reactive-test-lib/mock/MockCallbackProxy.sol";
import {CrossGuardReactive} from "../../src/reactive/CrossGuardReactive.sol";
import {MockOmniSystemContract} from "../mocks/MockOmniSystemContract.sol";
import {ISystemContract} from "../../src/interfaces/ISystemContract.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title M004AdversarialSecurityTest
/// @notice Comprehensive adversarial security, out-of-order delivery, failure simulation,
///         and invariant validation test suite for Mission M004.
contract M004AdversarialSecurityTest is Test {
    BorrowingController controller;
    CrossGuardCallback callbackReceiver;
    MockCallbackProxy callbackProxy;
    CrossGuardReactive reactiveContract;
    MockOmniSystemContract omniSys;

    address owner = address(0xAA);
    address callbackAdapter;
    address borrower = address(0xCC);
    address impostor = address(0xDEAD);
    address authorizedReactive;

    bytes32 positionId = keccak256("position-adversarial-1");
    bytes32 positionId2 = keccak256("position-adversarial-2");

    uint256 constant ORIGIN_CHAIN_ID = 84532;
    uint256 constant DEST_CHAIN_ID = 1301;
    uint64 constant CALLBACK_GAS_LIMIT = 300_000;
    address constant ORIGIN_RISK_CONTROLLER = address(0xBB11);

    bytes32 constant RISK_BREACH_TOPIC_0 = keccak256("RiskBreach(bytes32,address,uint256,uint256,uint256,uint256)");
    bytes32 constant RISK_RESOLVED_TOPIC_0 = keccak256("RiskResolved(bytes32,address,uint256,uint256,uint256,uint256)");

    function setUp() public {
        vm.startPrank(owner);

        // 1. Destination Lending Controller
        controller = new BorrowingController(owner);

        // 2. Mock Callback Proxy
        callbackProxy = new MockCallbackProxy();

        // 3. Mock Reactive Omni System
        omniSys = new MockOmniSystemContract();

        // 4. Reactive Smart Contract on Lasna
        reactiveContract = new CrossGuardReactive(
            owner, address(omniSys), ORIGIN_CHAIN_ID, ORIGIN_RISK_CONTROLLER, DEST_CHAIN_ID, address(0), 0
        );
        authorizedReactive = address(reactiveContract);

        // 5. Destination Callback Receiver
        callbackReceiver =
            new CrossGuardCallback(owner, address(callbackProxy), address(controller), authorizedReactive);
        callbackAdapter = address(callbackReceiver);

        // Link adapter in controller
        controller.setCallbackAdapter(callbackAdapter);

        // Link destination in reactive contract
        reactiveContract.setDestinationConfig(DEST_CHAIN_ID, callbackAdapter, CALLBACK_GAS_LIMIT);

        vm.stopPrank();

        // Register borrower positions
        vm.prank(borrower);
        controller.registerPosition(positionId);

        vm.prank(borrower);
        controller.registerPosition(positionId2);
    }

    /* ========================================================================== */
    /*        M004.2: DESTINATION PAUSE-STATE CORRECTNESS & ORTHOGONALITY         */
    /* ========================================================================== */

    /// @notice Test that an administrative emergency pause remains intact when risk resolution arrives.
    function testAdministrativePauseSurvivesRiskResolution() public {
        // Step 1: Admin places emergency pause
        vm.prank(owner);
        controller.emergencyPauseBorrowing(positionId);
        assertTrue(controller.isBorrowingPaused(positionId), "Must be paused");
        assertTrue(controller.pausedByAdmin(positionId), "Must be paused by admin");
        assertFalse(controller.pausedByRiskBreach(positionId), "Not paused by risk");

        // Step 2: Risk resolution callback arrives
        vm.prank(callbackAdapter);
        controller.resolveBorrowing(positionId, 1, 4500, block.timestamp);

        // Step 3: Admin pause MUST still be active!
        assertTrue(controller.isBorrowingPaused(positionId), "Borrowing MUST remain paused by admin");
        assertTrue(controller.pausedByAdmin(positionId), "pausedByAdmin MUST remain true");
        assertFalse(controller.pausedByRiskBreach(positionId), "pausedByRiskBreach must be false");
        assertEq(controller.lastProcessedNonce(positionId), 1, "Nonce must advance");

        // Borrower CANNOT borrow
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.BorrowingIsPaused.selector, positionId));
        controller.borrow(positionId, 100e18);

        // Step 4: Admin explicitly resumes borrowing
        vm.prank(owner);
        controller.resumeBorrowing(positionId);
        assertFalse(controller.isBorrowingPaused(positionId), "Borrowing should now be unpaused");
        assertFalse(controller.pausedByAdmin(positionId), "pausedByAdmin must be false");

        // Now borrower can borrow
        vm.prank(borrower);
        controller.borrow(positionId, 100e18);
        assertEq(controller.positionBorrowDebt(positionId), 100e18);
    }

    /// @notice Test that ordinary owner resume cannot bypass an active risk breach, even if admin pause was also placed.
    function testBothPauseReasonsActiveSimultaneously() public {
        // Step 1: Risk breach pauses position
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 1, 8500, block.timestamp);
        assertTrue(controller.pausedByRiskBreach(positionId));
        assertFalse(controller.pausedByAdmin(positionId));
        assertTrue(controller.isBorrowingPaused(positionId));

        // Step 2: Admin ALSO places emergency pause
        vm.prank(owner);
        controller.emergencyPauseBorrowing(positionId);
        assertTrue(controller.pausedByRiskBreach(positionId), "Risk pause still true");
        assertTrue(controller.pausedByAdmin(positionId), "Admin pause now true");
        assertTrue(controller.isBorrowingPaused(positionId), "Borrowing paused");

        // Step 3: Ordinary owner resume MUST revert because risk breach is active
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.CannotBypassActiveRiskBreach.selector, positionId));
        controller.resumeBorrowing(positionId);

        // Step 4: Risk resolution arrives with nonce 2
        vm.prank(callbackAdapter);
        controller.resolveBorrowing(positionId, 2, 4500, block.timestamp);
        assertFalse(controller.pausedByRiskBreach(positionId), "Risk breach cleared");
        assertTrue(controller.pausedByAdmin(positionId), "Admin pause preserved");
        assertTrue(controller.isBorrowingPaused(positionId), "Borrowing still paused by admin");

        // Step 5: Now owner can resume borrowing since risk breach is cleared
        vm.prank(owner);
        controller.resumeBorrowing(positionId);
        assertFalse(controller.pausedByAdmin(positionId), "Admin pause cleared");
        assertFalse(controller.isBorrowingPaused(positionId), "Borrowing unpaused");
    }

    /// @notice Test emergency resume when both pause reasons are active.
    function testEmergencyResumeClearsBothPausesWithAudit() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 1, 8500, block.timestamp);

        vm.prank(owner);
        controller.emergencyPauseBorrowing(positionId);

        assertTrue(controller.pausedByRiskBreach(positionId));
        assertTrue(controller.pausedByAdmin(positionId));

        // Emergency resume with reason
        string memory reason = "Audited off-chain settlement of $50,000";
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IBorrowingController.EmergencyBorrowingResumed(positionId, owner, reason, block.timestamp);
        controller.emergencyResumeBorrowing(positionId, reason);

        assertFalse(controller.pausedByRiskBreach(positionId));
        assertFalse(controller.pausedByAdmin(positionId));
        assertFalse(controller.isBorrowingPaused(positionId));
    }

    /// @notice Test repeated emergency pause and resume attempts.
    function testRepeatedEmergencyPauseAndResume() public {
        vm.startPrank(owner);

        // First emergency pause
        controller.emergencyPauseBorrowing(positionId);
        assertTrue(controller.pausedByAdmin(positionId));

        // Repeated emergency pause is idempotent on admin flag
        controller.emergencyPauseBorrowing(positionId);
        assertTrue(controller.pausedByAdmin(positionId));

        // Resume
        controller.resumeBorrowing(positionId);
        assertFalse(controller.pausedByAdmin(positionId));

        // Resuming again when not paused reverts PositionNotPaused
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.PositionNotPaused.selector, positionId));
        controller.resumeBorrowing(positionId);

        vm.stopPrank();
    }

    /// @notice Test unauthorized callers cannot trigger administrative pauses or resumes.
    function testUnauthorizedAdminActionsRevert() public {
        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, impostor));
        controller.emergencyPauseBorrowing(positionId);

        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, impostor));
        controller.resumeBorrowing(positionId);

        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, impostor));
        controller.emergencyResumeBorrowing(positionId, "Unauthorized reason");
    }

    /* ========================================================================== */
    /*        M004.3: OUT-OF-ORDER CALLBACK DELIVERY & RECOVERY LIVENESS          */
    /* ========================================================================== */

    /// @notice Scenario A: Resolution arrives before breach; converges to healthy state and rejects delayed breach.
    function testResolutionArrivingBeforeBreachConvergesSafely() public {
        // Initial state: position is unpaused, nonce is 0
        assertFalse(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastProcessedNonce(positionId), 0);

        // Resolution callback nonce 2 arrives first (breach nonce 1 was delayed)
        vm.prank(callbackAdapter);
        controller.resolveBorrowing(positionId, 2, 4500, block.timestamp);

        // Nonce advances to 2, position remains healthy and unpaused
        assertEq(controller.lastProcessedNonce(positionId), 2);
        assertFalse(controller.isBorrowingPaused(positionId));
        assertFalse(controller.pausedByRiskBreach(positionId));

        // Delayed breach nonce 1 arrives later: MUST REVERT as stale
        vm.prank(callbackAdapter);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 1, 2));
        controller.pauseBorrowing(positionId, 1, 8500, block.timestamp);

        // Position stays healthy!
        assertFalse(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastProcessedNonce(positionId), 2);
    }

    /// @notice Scenario B: Missing callback followed by newer state transitions.
    function testMissingCallbackFollowedByLaterBreach() public {
        // Nonce 1 is dropped/never arrives.
        // Nonce 2 (resolution) arrives first.
        vm.prank(callbackAdapter);
        controller.resolveBorrowing(positionId, 2, 4500, block.timestamp);
        assertEq(controller.lastProcessedNonce(positionId), 2);

        // Later breach nonce 3 occurs and arrives
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 3, 9000, block.timestamp);
        assertEq(controller.lastProcessedNonce(positionId), 3);
        assertTrue(controller.isBorrowingPaused(positionId));
        assertTrue(controller.pausedByRiskBreach(positionId));
    }

    /// @notice Scenario C: Duplicate, stale, and skipped nonces.
    function testDuplicateAndStaleNonces() public {
        vm.startPrank(callbackAdapter);

        controller.pauseBorrowing(positionId, 5, 8500, block.timestamp);
        assertEq(controller.lastProcessedNonce(positionId), 5);

        // Duplicate breach nonce 5 reverts
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 5, 5));
        controller.pauseBorrowing(positionId, 5, 8500, block.timestamp);

        // Stale resolution nonce 4 reverts
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 4, 5));
        controller.resolveBorrowing(positionId, 4, 4500, block.timestamp);

        // Skipped nonce 10 succeeds and establishes new watermark
        controller.resolveBorrowing(positionId, 10, 4500, block.timestamp);
        assertEq(controller.lastProcessedNonce(positionId), 10);

        // Nonce 8 reverts against watermark 10
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 8, 10));
        controller.pauseBorrowing(positionId, 8, 8500, block.timestamp);

        vm.stopPrank();
    }

    /// @notice Position isolation: Position A's state and nonces cannot affect Position B.
    function testPositionIsolationUnderAdversarialCallbacks() public {
        vm.startPrank(callbackAdapter);

        // Pause position 1 at nonce 5
        controller.pauseBorrowing(positionId, 5, 8500, block.timestamp);
        assertTrue(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastProcessedNonce(positionId), 5);

        // Position 2 remains unpaused at nonce 0
        assertFalse(controller.isBorrowingPaused(positionId2));
        assertEq(controller.lastProcessedNonce(positionId2), 0);

        // Nonce 1 on Position 2 succeeds because position nonces are isolated
        controller.pauseBorrowing(positionId2, 1, 8500, block.timestamp);
        assertTrue(controller.isBorrowingPaused(positionId2));
        assertEq(controller.lastProcessedNonce(positionId2), 1);

        // Resolve position 1 at nonce 6
        controller.resolveBorrowing(positionId, 6, 4500, block.timestamp);
        assertFalse(controller.isBorrowingPaused(positionId));

        // Position 2 remains paused
        assertTrue(controller.isBorrowingPaused(positionId2));

        vm.stopPrank();
    }

    /* ========================================================================== */
    /*        M004.4: EMERGENCY OVERRIDE & DELAYED-MESSAGE SECURITY               */
    /* ========================================================================== */

    /// @notice Delayed messages after emergency resume cannot replay older nonces.
    function testDelayedMessagesAfterEmergencyResume() public {
        // Step 1: Risk pause nonce 1 arrives
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 1, 8500, block.timestamp);
        assertTrue(controller.isBorrowingPaused(positionId));

        // Step 2: Owner performs emergency resume
        vm.prank(owner);
        controller.emergencyResumeBorrowing(positionId, "Emergency manual override");
        assertFalse(controller.isBorrowingPaused(positionId));

        // Step 3: Replaying nonce 1 fails
        vm.prank(callbackAdapter);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 1, 1));
        controller.pauseBorrowing(positionId, 1, 8500, block.timestamp);

        // Step 4: A legitimate newer breach nonce 2 arrives and correctly pauses
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(positionId, 2, 8800, block.timestamp);
        assertTrue(controller.isBorrowingPaused(positionId));

        // Step 5: A legitimate newer resolution nonce 3 arrives and unpauses
        vm.prank(callbackAdapter);
        controller.resolveBorrowing(positionId, 3, 4000, block.timestamp);
        assertFalse(controller.isBorrowingPaused(positionId));
    }

    /// @notice Changed callback adapter prevents old adapter from mutating state.
    function testChangedCallbackAdapterPreventsOldAdapterCalls() public {
        address newAdapter = address(0x9999);
        vm.prank(owner);
        controller.setCallbackAdapter(newAdapter);

        vm.prank(callbackAdapter);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedCallback.selector, callbackAdapter));
        controller.pauseBorrowing(positionId, 1, 8500, block.timestamp);
    }

    /* ========================================================================== */
    /*        M004.5: CALLBACK AUTHENTICATION ATTACKS VIA CROSSGUARDCALLBACK      */
    /* ========================================================================== */

    /// @notice Direct attacker calls to handleRiskBreach and handleRiskResolved revert.
    function testDirectAttackerCallsToCallbackReceiverRevert() public {
        vm.prank(impostor);
        vm.expectRevert("Authorized sender only");
        callbackReceiver.handleRiskBreach(authorizedReactive, positionId, 1, 8500, block.timestamp);

        vm.prank(impostor);
        vm.expectRevert("Authorized sender only");
        callbackReceiver.handleRiskResolved(authorizedReactive, positionId, 2, 4500, block.timestamp);
    }

    /// @notice Proxy delivering forged Reactive sender reverts UnauthorizedReactiveSender.
    function testForgedReactiveSenderThroughProxyReverts() public {
        address forgedReactive = address(0xBADBEEF);
        bytes memory payload = abi.encodeWithSignature(
            "handleRiskBreach(address,bytes32,uint256,uint256,uint256)",
            address(0),
            positionId,
            1,
            8500,
            block.timestamp
        );

        // Proxy executes callback with forged address injected
        (bool success,) = callbackProxy.executeCallback(address(callbackReceiver), payload, 300_000, forgedReactive);
        assertFalse(success, "Forged reactive sender must fail execution");
    }

    /// @notice Correct Reactive sender invoked through wrong proxy reverts.
    function testCorrectReactiveSenderThroughWrongProxyReverts() public {
        MockCallbackProxy fakeProxy = new MockCallbackProxy();
        bytes memory payload = abi.encodeWithSignature(
            "handleRiskBreach(address,bytes32,uint256,uint256,uint256)",
            address(0),
            positionId,
            1,
            8500,
            block.timestamp
        );

        (bool success,) = fakeProxy.executeCallback(address(callbackReceiver), payload, 300_000, authorizedReactive);
        assertFalse(success, "Wrong callback proxy must fail execution");
    }

    /// @notice Zero position ID through callback receiver reverts InvalidPositionId.
    function testZeroPositionIdThroughCallbackReceiverReverts() public {
        bytes memory payload = abi.encodeWithSignature(
            "handleRiskBreach(address,bytes32,uint256,uint256,uint256)",
            address(0),
            bytes32(0),
            1,
            8500,
            block.timestamp
        );

        (bool success,) = callbackProxy.executeCallback(address(callbackReceiver), payload, 300_000, authorizedReactive);
        assertFalse(success, "Zero positionId must revert");
    }

    /// @notice Unauthorized attempts to change configuration on CrossGuardCallback revert.
    function testUnauthorizedConfigChangesOnCallbackReceiverRevert() public {
        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, impostor));
        callbackReceiver.setAuthorizedReactiveSender(address(0x1234));

        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, impostor));
        callbackReceiver.setBorrowingController(address(0x5678));
    }

    /* ========================================================================== */
    /*        M004.6: REACTIVE EVENT-VALIDATION ATTACKS & FUZZ TESTING            */
    /* ========================================================================== */

    /// @notice Test that invalid log mutations in react() are rejected without submitting callbacks.
    function testReactiveRejectsAllInvalidLogMutations() public {
        // 1. Wrong chain ID
        _assertLogRejected(
            99999, // wrong chain ID
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            abi.encode(uint256(8500), uint256(8000), block.timestamp),
            "WRONG_CHAIN_ID"
        );

        // 2. Wrong emitter contract
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            address(0x9999), // wrong emitter
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            abi.encode(uint256(8500), uint256(8000), block.timestamp),
            "WRONG_EMITTER"
        );

        // 3. Wrong event topic
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            keccak256("SomeOtherEvent()"),
            positionId,
            borrower,
            1,
            abi.encode(uint256(8500), uint256(8000), block.timestamp),
            "WRONG_EVENT_TOPIC"
        );

        // 4. Zero position ID
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            bytes32(0),
            borrower,
            1,
            abi.encode(uint256(8500), uint256(8000), block.timestamp),
            "ZERO_POSITION_ID"
        );

        // 5. Zero user address
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            address(0),
            1,
            abi.encode(uint256(8500), uint256(8000), block.timestamp),
            "INVALID_INDEXED_USER"
        );

        // 6. Zero nonce
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            0,
            abi.encode(uint256(8500), uint256(8000), block.timestamp),
            "ZERO_NONCE"
        );

        // 7. Invalid data lengths: 0, 32, 64, 95, 97, 128
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            new bytes(0),
            "INVALID_DATA_LENGTH"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            new bytes(95),
            "INVALID_DATA_LENGTH"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            new bytes(97),
            "INVALID_DATA_LENGTH"
        );

        // 8. Invalid threshold bounds (0 or > 10,000)
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            abi.encode(uint256(8500), uint256(0), block.timestamp),
            "INVALID_THRESHOLD"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            abi.encode(uint256(8500), uint256(10001), block.timestamp),
            "INVALID_THRESHOLD"
        );

        // 9. Zero timestamp
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            abi.encode(uint256(8500), uint256(8000), uint256(0)),
            "INVALID_TIMESTAMP"
        );

        // 10. Breach event with LTV below threshold
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            abi.encode(uint256(7999), uint256(8000), block.timestamp),
            "BREACH_BELOW_THRESHOLD"
        );

        // 11. Resolution event with LTV at or above threshold
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_RESOLVED_TOPIC_0,
            positionId,
            borrower,
            1,
            abi.encode(uint256(8000), uint256(8000), block.timestamp),
            "RESOLVED_NOT_BELOW_THRESHOLD"
        );
    }

    /// @notice Fuzz test malformed LTV and threshold combinations in react().
    function testFuzzReactiveRiskThresholdSanity(uint256 ltv, uint256 threshold) public {
        vm.assume(threshold > 0 && threshold <= 10_000);
        vm.assume(ltv <= 50_000);

        uint256 initialCallbacks = omniSys.requestedCallbackCount();

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: ORIGIN_RISK_CONTROLLER,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(borrower)),
            topic_3: 1,
            data: abi.encode(ltv, threshold, block.timestamp),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(omniSys));
        reactiveContract.react(log);

        if (ltv >= threshold) {
            // Valid breach -> callback requested
            assertEq(omniSys.requestedCallbackCount(), initialCallbacks + 1);
        } else {
            // Invalid breach -> rejected without callback
            assertEq(omniSys.requestedCallbackCount(), initialCallbacks);
        }
    }

    /* ========================================================================== */
    /*        M004.7: CALLBACK DELIVERY AND FAILURE SIMULATION                    */
    /* ========================================================================== */

    /// @notice Test that an execution revert at destination does not mutate state or advance nonce.
    function testCallbackRevertLeavesStateUnmutated() public {
        // Deliver invalid nonce 0 to cause execution revert
        bytes memory invalidPayload = abi.encodeWithSignature(
            "handleRiskBreach(address,bytes32,uint256,uint256,uint256)",
            address(0),
            positionId,
            0, // Invalid nonce 0
            8500,
            block.timestamp
        );

        (bool success,) =
            callbackProxy.executeCallback(address(callbackReceiver), invalidPayload, 300_000, authorizedReactive);
        assertFalse(success, "Callback execution must revert");

        // Verify destination state is COMPLETELY unmutated
        assertFalse(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastProcessedNonce(positionId), 0);

        // Now deliver a valid callback: it must succeed cleanly
        bytes memory validPayload = abi.encodeWithSignature(
            "handleRiskBreach(address,bytes32,uint256,uint256,uint256)",
            address(0),
            positionId,
            1,
            8500,
            block.timestamp
        );
        (bool validSuccess,) =
            callbackProxy.executeCallback(address(callbackReceiver), validPayload, 300_000, authorizedReactive);
        assertTrue(validSuccess, "Subsequent valid callback must succeed");
        assertTrue(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastProcessedNonce(positionId), 1);
    }

    /* ========================================================================== */
    /*        M004.8: STATEFUL INVARIANT & PROPERTY-BASED TESTS                   */
    /* ========================================================================== */

    /// @notice Invariant 1: Borrowing must NEVER succeed while any pause flag is active.
    function testInvariantBorrowingNeverSucceedsWhilePaused(bool pauseByAdmin, bool pauseByRisk) public {
        vm.assume(pauseByAdmin || pauseByRisk);

        if (pauseByAdmin) {
            vm.prank(owner);
            controller.emergencyPauseBorrowing(positionId);
        }
        if (pauseByRisk) {
            vm.prank(callbackAdapter);
            controller.pauseBorrowing(positionId, 1, 8500, block.timestamp);
        }

        assertTrue(controller.isBorrowingPaused(positionId), "Invariant violated: must be paused");

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.BorrowingIsPaused.selector, positionId));
        controller.borrow(positionId, 50e18);
    }

    /// @notice Invariant 2: Fuzz testing nonce progression monotonicity across multiple positions.
    function testFuzzNonceMonotonicity(uint8 stepCount, uint16 rawNonce) public {
        vm.assume(stepCount > 0 && stepCount <= 20);
        uint256 currentNonce = uint256(rawNonce) + 1;

        vm.startPrank(callbackAdapter);
        for (uint256 i = 0; i < stepCount; i++) {
            currentNonce += 2;
            controller.pauseBorrowing(positionId, currentNonce, 8500, block.timestamp);
            assertEq(controller.lastProcessedNonce(positionId), currentNonce);

            // Replaying currentNonce - 1 or currentNonce MUST revert
            vm.expectRevert(
                abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, currentNonce, currentNonce)
            );
            controller.pauseBorrowing(positionId, currentNonce, 8500, block.timestamp);

            vm.expectRevert(
                abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, currentNonce - 1, currentNonce)
            );
            controller.resolveBorrowing(positionId, currentNonce - 1, 4000, block.timestamp);
        }
        vm.stopPrank();
    }

    /* -------------------------------------------------------------------------- */
    /*                              INTERNAL HELPERS                              */
    /* -------------------------------------------------------------------------- */

    function _assertLogRejected(
        uint256 chainId,
        address emitter,
        bytes32 topic0,
        bytes32 posId,
        address user,
        uint256 nonce,
        bytes memory data,
        string memory expectedReason
    ) internal {
        uint256 initialCallbacks = omniSys.requestedCallbackCount();

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: chainId,
            _contract: emitter,
            topic_0: uint256(topic0),
            topic_1: uint256(posId),
            topic_2: uint256(uint160(user)),
            topic_3: nonce,
            data: data,
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectEmit(true, true, true, true);
        emit CrossGuardReactive.ReactiveEventRejected(topic0, posId, nonce, expectedReason);

        vm.prank(address(omniSys));
        reactiveContract.react(log);

        assertEq(
            omniSys.requestedCallbackCount(),
            initialCallbacks,
            string(abi.encodePacked("Rejected event must not request callback: ", expectedReason))
        );
    }
}

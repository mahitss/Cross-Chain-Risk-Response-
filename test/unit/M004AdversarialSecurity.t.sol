// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {BorrowingController} from "../../src/destination/BorrowingController.sol";
import {IBorrowingController} from "../../src/interfaces/IBorrowingController.sol";
import {CrossGuardCallback} from "../../src/destination/CrossGuardCallback.sol";
import {ICrossGuardCallback} from "../../src/interfaces/ICrossGuardCallback.sol";
import {MockCallbackProxy} from "reactive-test-lib/mock/MockCallbackProxy.sol";
import {CrossGuardReactive} from "../../src/reactive/CrossGuardReactive.sol";
import {MockOmniSystemContract} from "../mocks/MockOmniSystemContract.sol";
import {CrossGuardIdentity} from "../../src/libraries/CrossGuardIdentity.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title M004AdversarialSecurityTest
/// @notice Comprehensive adversarial security, out-of-order delivery, failure simulation,
///         and invariant validation test suite updated for M007.1 canonical identity bindings.
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

    uint256 constant ORIGIN_CHAIN_ID = 84532;
    uint256 constant DEST_CHAIN_ID = 1301;
    uint64 constant CALLBACK_GAS_LIMIT = 300_000;
    address constant ORIGIN_RISK_CONTROLLER = address(0xBB11);
    address constant ORIGIN_VAULT = address(0xBB22);

    bytes32 constant SALT_1 = keccak256("salt-adversarial-1");
    bytes32 constant SALT_2 = keccak256("salt-adversarial-2");
    bytes32 positionId;
    bytes32 positionId2;

    bytes32 constant RISK_BREACH_TOPIC_0 =
        keccak256("RiskBreach(bytes32,address,uint256,uint8,address,bytes32,uint256,uint256,uint256)");
    bytes32 constant RISK_RESOLVED_TOPIC_0 =
        keccak256("RiskResolved(bytes32,address,uint256,uint8,address,bytes32,uint256,uint256,uint256)");

    function setUp() public {
        vm.startPrank(owner);

        controller = new BorrowingController(owner, ORIGIN_CHAIN_ID, ORIGIN_RISK_CONTROLLER, ORIGIN_VAULT);
        callbackProxy = new MockCallbackProxy();
        omniSys = new MockOmniSystemContract();

        reactiveContract = new CrossGuardReactive(
            owner, address(omniSys), ORIGIN_CHAIN_ID, ORIGIN_RISK_CONTROLLER, ORIGIN_VAULT, DEST_CHAIN_ID, address(0), 0
        );
        authorizedReactive = address(reactiveContract);

        callbackReceiver =
            new CrossGuardCallback(owner, address(callbackProxy), address(controller), authorizedReactive);
        callbackAdapter = address(callbackReceiver);

        controller.setCallbackAdapter(callbackAdapter);
        reactiveContract.setDestinationConfig(DEST_CHAIN_ID, callbackAdapter, CALLBACK_GAS_LIMIT);

        vm.stopPrank();

        vm.startPrank(borrower);
        positionId = controller.registerPosition(SALT_1);
        positionId2 = controller.registerPosition(SALT_2);
        vm.stopPrank();
    }

    function _msg(bytes32 posId, bytes32 salt, uint256 nonce, uint256 ltv, uint256 ts)
        internal
        view
        returns (CrossGuardIdentity.RiskCallbackMessage memory)
    {
        return CrossGuardIdentity.RiskCallbackMessage({
            identityVersion: CrossGuardIdentity.IDENTITY_VERSION,
            originChainId: ORIGIN_CHAIN_ID,
            originRiskController: ORIGIN_RISK_CONTROLLER,
            originVault: ORIGIN_VAULT,
            originUser: borrower,
            positionId: posId,
            salt: salt,
            nonce: nonce,
            riskLevel: ltv,
            timestamp: ts
        });
    }

    function _breachPayload(bytes32 posId, bytes32 salt, uint256 nonce, uint256 ltv, uint256 ts)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(ICrossGuardCallback.handleRiskBreach, (address(0), _msg(posId, salt, nonce, ltv, ts)));
    }

    function testAdministrativePauseSurvivesRiskResolution() public {
        vm.prank(owner);
        controller.emergencyPauseBorrowing(positionId);
        assertTrue(controller.isBorrowingPaused(positionId));
        assertTrue(controller.pausedByAdmin(positionId));
        assertFalse(controller.pausedByRiskBreach(positionId));

        vm.prank(callbackAdapter);
        controller.resolveBorrowing(_msg(positionId, SALT_1, 1, 4500, block.timestamp));

        assertTrue(controller.isBorrowingPaused(positionId));
        assertTrue(controller.pausedByAdmin(positionId));
        assertFalse(controller.pausedByRiskBreach(positionId));
        assertEq(controller.lastProcessedNonce(positionId), 1);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.BorrowingIsPaused.selector, positionId));
        controller.borrow(positionId, 100e18);

        vm.prank(owner);
        controller.resumeBorrowing(positionId);
        assertFalse(controller.isBorrowingPaused(positionId));
        assertFalse(controller.pausedByAdmin(positionId));

        vm.prank(borrower);
        controller.borrow(positionId, 100e18);
        assertEq(controller.positionBorrowDebt(positionId), 100e18);
    }

    function testBothPauseReasonsActiveSimultaneously() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, SALT_1, 1, 8500, block.timestamp));
        assertTrue(controller.pausedByRiskBreach(positionId));
        assertFalse(controller.pausedByAdmin(positionId));
        assertTrue(controller.isBorrowingPaused(positionId));

        vm.prank(owner);
        controller.emergencyPauseBorrowing(positionId);
        assertTrue(controller.pausedByRiskBreach(positionId));
        assertTrue(controller.pausedByAdmin(positionId));
        assertTrue(controller.isBorrowingPaused(positionId));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.CannotBypassActiveRiskBreach.selector, positionId));
        controller.resumeBorrowing(positionId);

        vm.prank(callbackAdapter);
        controller.resolveBorrowing(_msg(positionId, SALT_1, 2, 4500, block.timestamp));
        assertFalse(controller.pausedByRiskBreach(positionId));
        assertTrue(controller.pausedByAdmin(positionId));
        assertTrue(controller.isBorrowingPaused(positionId));

        vm.prank(owner);
        controller.resumeBorrowing(positionId);
        assertFalse(controller.pausedByAdmin(positionId));
        assertFalse(controller.isBorrowingPaused(positionId));
    }

    function testEmergencyResumeClearsBothPausesWithAudit() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, SALT_1, 1, 8500, block.timestamp));

        vm.prank(owner);
        controller.emergencyPauseBorrowing(positionId);

        string memory reason = "Audited off-chain settlement of $50,000";
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IBorrowingController.EmergencyBorrowingResumed(positionId, owner, reason, block.timestamp);
        controller.emergencyResumeBorrowing(positionId, reason);

        assertFalse(controller.pausedByRiskBreach(positionId));
        assertFalse(controller.pausedByAdmin(positionId));
        assertFalse(controller.isBorrowingPaused(positionId));
    }

    function testRepeatedEmergencyPauseAndResume() public {
        vm.startPrank(owner);
        controller.emergencyPauseBorrowing(positionId);
        assertTrue(controller.pausedByAdmin(positionId));

        controller.emergencyPauseBorrowing(positionId);
        assertTrue(controller.pausedByAdmin(positionId));

        controller.resumeBorrowing(positionId);
        assertFalse(controller.pausedByAdmin(positionId));

        vm.expectRevert(abi.encodeWithSelector(BorrowingController.PositionNotPaused.selector, positionId));
        controller.resumeBorrowing(positionId);
        vm.stopPrank();
    }

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

    function testResolutionArrivingBeforeBreachConvergesSafely() public {
        assertFalse(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastProcessedNonce(positionId), 0);

        vm.prank(callbackAdapter);
        controller.resolveBorrowing(_msg(positionId, SALT_1, 2, 4500, block.timestamp));

        assertEq(controller.lastProcessedNonce(positionId), 2);
        assertFalse(controller.isBorrowingPaused(positionId));
        assertFalse(controller.pausedByRiskBreach(positionId));

        vm.prank(callbackAdapter);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 1, 2));
        controller.pauseBorrowing(_msg(positionId, SALT_1, 1, 8500, block.timestamp));

        assertFalse(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastProcessedNonce(positionId), 2);
    }

    function testMissingCallbackFollowedByLaterBreach() public {
        vm.prank(callbackAdapter);
        controller.resolveBorrowing(_msg(positionId, SALT_1, 2, 4500, block.timestamp));
        assertEq(controller.lastProcessedNonce(positionId), 2);

        vm.prank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, SALT_1, 3, 9000, block.timestamp));
        assertEq(controller.lastProcessedNonce(positionId), 3);
        assertTrue(controller.isBorrowingPaused(positionId));
        assertTrue(controller.pausedByRiskBreach(positionId));
    }

    function testDuplicateAndStaleNonces() public {
        vm.startPrank(callbackAdapter);

        controller.pauseBorrowing(_msg(positionId, SALT_1, 5, 8500, block.timestamp));
        assertEq(controller.lastProcessedNonce(positionId), 5);

        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 5, 5));
        controller.pauseBorrowing(_msg(positionId, SALT_1, 5, 8500, block.timestamp));

        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 4, 5));
        controller.resolveBorrowing(_msg(positionId, SALT_1, 4, 4500, block.timestamp));

        controller.resolveBorrowing(_msg(positionId, SALT_1, 10, 4500, block.timestamp));
        assertEq(controller.lastProcessedNonce(positionId), 10);

        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 8, 10));
        controller.pauseBorrowing(_msg(positionId, SALT_1, 8, 8500, block.timestamp));

        vm.stopPrank();
    }

    function testPositionIsolationUnderAdversarialCallbacks() public {
        vm.startPrank(callbackAdapter);

        controller.pauseBorrowing(_msg(positionId, SALT_1, 5, 8500, block.timestamp));
        assertTrue(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastProcessedNonce(positionId), 5);

        assertFalse(controller.isBorrowingPaused(positionId2));
        assertEq(controller.lastProcessedNonce(positionId2), 0);

        controller.pauseBorrowing(_msg(positionId2, SALT_2, 1, 8500, block.timestamp));
        assertTrue(controller.isBorrowingPaused(positionId2));
        assertEq(controller.lastProcessedNonce(positionId2), 1);

        controller.resolveBorrowing(_msg(positionId, SALT_1, 6, 4500, block.timestamp));
        assertFalse(controller.isBorrowingPaused(positionId));

        assertTrue(controller.isBorrowingPaused(positionId2));

        vm.stopPrank();
    }

    function testDelayedMessagesAfterEmergencyResume() public {
        vm.prank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, SALT_1, 1, 8500, block.timestamp));
        assertTrue(controller.isBorrowingPaused(positionId));

        vm.prank(owner);
        controller.emergencyResumeBorrowing(positionId, "Emergency manual override");
        assertFalse(controller.isBorrowingPaused(positionId));

        vm.prank(callbackAdapter);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, 1, 1));
        controller.pauseBorrowing(_msg(positionId, SALT_1, 1, 8500, block.timestamp));

        vm.prank(callbackAdapter);
        controller.pauseBorrowing(_msg(positionId, SALT_1, 2, 8800, block.timestamp));
        assertTrue(controller.isBorrowingPaused(positionId));

        vm.prank(callbackAdapter);
        controller.resolveBorrowing(_msg(positionId, SALT_1, 3, 4000, block.timestamp));
        assertFalse(controller.isBorrowingPaused(positionId));
    }

    function testChangedCallbackAdapterPreventsOldAdapterCalls() public {
        address newAdapter = address(0x9999);
        vm.prank(owner);
        controller.setCallbackAdapter(newAdapter);

        vm.prank(callbackAdapter);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedCallback.selector, callbackAdapter));
        controller.pauseBorrowing(_msg(positionId, SALT_1, 1, 8500, block.timestamp));
    }

    function testDirectAttackerCallsToCallbackReceiverRevert() public {
        vm.prank(impostor);
        vm.expectRevert("Authorized sender only");
        callbackReceiver.handleRiskBreach(authorizedReactive, _msg(positionId, SALT_1, 1, 8500, block.timestamp));

        vm.prank(impostor);
        vm.expectRevert("Authorized sender only");
        callbackReceiver.handleRiskResolved(authorizedReactive, _msg(positionId, SALT_1, 2, 4500, block.timestamp));
    }

    function testForgedReactiveSenderThroughProxyReverts() public {
        address forgedReactive = address(0xBADBEEF);
        bytes memory payload = _breachPayload(positionId, SALT_1, 1, 8500, block.timestamp);

        (bool success,) = callbackProxy.executeCallback(address(callbackReceiver), payload, 300_000, forgedReactive);
        assertFalse(success, "Forged reactive sender must fail execution");
    }

    function testCorrectReactiveSenderThroughWrongProxyReverts() public {
        MockCallbackProxy fakeProxy = new MockCallbackProxy();
        bytes memory payload = _breachPayload(positionId, SALT_1, 1, 8500, block.timestamp);

        (bool success,) = fakeProxy.executeCallback(address(callbackReceiver), payload, 300_000, authorizedReactive);
        assertFalse(success, "Wrong callback proxy must fail execution");
    }

    function testZeroPositionIdThroughCallbackReceiverReverts() public {
        bytes memory payload = _breachPayload(bytes32(0), SALT_1, 1, 8500, block.timestamp);

        (bool success,) = callbackProxy.executeCallback(address(callbackReceiver), payload, 300_000, authorizedReactive);
        assertFalse(success, "Zero positionId must revert");
    }

    function testUnauthorizedConfigChangesOnCallbackReceiverRevert() public {
        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, impostor));
        callbackReceiver.setAuthorizedReactiveSender(address(0x1234));

        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, impostor));
        callbackReceiver.setBorrowingController(address(0x5678));
    }

    function testReactiveRejectsAllInvalidLogMutations() public {
        bytes memory validData = abi.encode(
            CrossGuardIdentity.IDENTITY_VERSION, ORIGIN_VAULT, SALT_1, uint256(8500), uint256(8000), block.timestamp
        );

        _assertLogRejected(
            99999, ORIGIN_RISK_CONTROLLER, RISK_BREACH_TOPIC_0, positionId, borrower, 1, validData, "WRONG_CHAIN_ID"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID, address(0x9999), RISK_BREACH_TOPIC_0, positionId, borrower, 1, validData, "WRONG_EMITTER"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            keccak256("SomeOtherEvent()"),
            positionId,
            borrower,
            1,
            validData,
            "WRONG_EVENT_TOPIC"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            bytes32(0),
            borrower,
            1,
            validData,
            "ZERO_POSITION_ID"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            address(0),
            1,
            validData,
            "INVALID_INDEXED_USER"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            0,
            validData,
            "ZERO_NONCE"
        );
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
            new bytes(96),
            "INVALID_DATA_LENGTH"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            new bytes(193),
            "INVALID_DATA_LENGTH"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            abi.encode(
                CrossGuardIdentity.IDENTITY_VERSION, ORIGIN_VAULT, SALT_1, uint256(8500), uint256(0), block.timestamp
            ),
            "INVALID_THRESHOLD"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            abi.encode(
                CrossGuardIdentity.IDENTITY_VERSION,
                ORIGIN_VAULT,
                SALT_1,
                uint256(8500),
                uint256(10001),
                block.timestamp
            ),
            "INVALID_THRESHOLD"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            abi.encode(
                CrossGuardIdentity.IDENTITY_VERSION, ORIGIN_VAULT, SALT_1, uint256(8500), uint256(8000), uint256(0)
            ),
            "INVALID_TIMESTAMP"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_BREACH_TOPIC_0,
            positionId,
            borrower,
            1,
            abi.encode(
                CrossGuardIdentity.IDENTITY_VERSION, ORIGIN_VAULT, SALT_1, uint256(7999), uint256(8000), block.timestamp
            ),
            "BREACH_BELOW_THRESHOLD"
        );
        _assertLogRejected(
            ORIGIN_CHAIN_ID,
            ORIGIN_RISK_CONTROLLER,
            RISK_RESOLVED_TOPIC_0,
            positionId,
            borrower,
            1,
            abi.encode(
                CrossGuardIdentity.IDENTITY_VERSION, ORIGIN_VAULT, SALT_1, uint256(8000), uint256(8000), block.timestamp
            ),
            "RESOLVED_NOT_BELOW_THRESHOLD"
        );
    }

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
            data: abi.encode(
                CrossGuardIdentity.IDENTITY_VERSION, ORIGIN_VAULT, SALT_1, ltv, threshold, block.timestamp
            ),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(omniSys));
        reactiveContract.react(log);

        if (ltv >= threshold) {
            assertEq(omniSys.requestedCallbackCount(), initialCallbacks + 1);
        } else {
            assertEq(omniSys.requestedCallbackCount(), initialCallbacks);
        }
    }

    function testCallbackRevertLeavesStateUnmutated() public {
        bytes memory invalidPayload = _breachPayload(positionId, SALT_1, 0, 8500, block.timestamp);

        (bool success,) =
            callbackProxy.executeCallback(address(callbackReceiver), invalidPayload, 300_000, authorizedReactive);
        assertFalse(success, "Callback execution must revert");

        assertFalse(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastProcessedNonce(positionId), 0);

        bytes memory validPayload = _breachPayload(positionId, SALT_1, 1, 8500, block.timestamp);
        (bool validSuccess,) =
            callbackProxy.executeCallback(address(callbackReceiver), validPayload, 300_000, authorizedReactive);
        assertTrue(validSuccess, "Subsequent valid callback must succeed");
        assertTrue(controller.isBorrowingPaused(positionId));
        assertEq(controller.lastProcessedNonce(positionId), 1);
    }

    function testInvariantBorrowingNeverSucceedsWhilePaused(bool pauseByAdmin, bool pauseByRisk) public {
        vm.assume(pauseByAdmin || pauseByRisk);

        if (pauseByAdmin) {
            vm.prank(owner);
            controller.emergencyPauseBorrowing(positionId);
        }
        if (pauseByRisk) {
            vm.prank(callbackAdapter);
            controller.pauseBorrowing(_msg(positionId, SALT_1, 1, 8500, block.timestamp));
        }

        assertTrue(controller.isBorrowingPaused(positionId));

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.BorrowingIsPaused.selector, positionId));
        controller.borrow(positionId, 50e18);
    }

    function testFuzzNonceMonotonicity(uint8 stepCount, uint16 rawNonce) public {
        vm.assume(stepCount > 0 && stepCount <= 20);
        uint256 currentNonce = uint256(rawNonce) + 1;

        vm.startPrank(callbackAdapter);
        for (uint256 i = 0; i < stepCount; i++) {
            currentNonce += 2;
            controller.pauseBorrowing(_msg(positionId, SALT_1, currentNonce, 8500, block.timestamp));
            assertEq(controller.lastProcessedNonce(positionId), currentNonce);

            vm.expectRevert(
                abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, currentNonce, currentNonce)
            );
            controller.pauseBorrowing(_msg(positionId, SALT_1, currentNonce, 8500, block.timestamp));

            vm.expectRevert(
                abi.encodeWithSelector(BorrowingController.InvalidNonce.selector, currentNonce - 1, currentNonce)
            );
            controller.resolveBorrowing(_msg(positionId, SALT_1, currentNonce - 1, 4000, block.timestamp));
        }
        vm.stopPrank();
    }

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

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {RiskController} from "../../src/origin/RiskController.sol";
import {CollateralVault} from "../../src/origin/CollateralVault.sol";
import {TestValuationSource} from "../../src/origin/TestValuationSource.sol";
import {CrossGuardReactive} from "../../src/reactive/CrossGuardReactive.sol";
import {BorrowingController} from "../../src/destination/BorrowingController.sol";
import {CrossGuardCallback} from "../../src/destination/CrossGuardCallback.sol";
import {MockOmniSystemContract} from "../mocks/MockOmniSystemContract.sol";
import {MockCallbackProxy} from "reactive-test-lib/mock/MockCallbackProxy.sol";
import {ISystemContract} from "../../src/interfaces/ISystemContract.sol";
import {ICrossGuardCallback} from "../../src/interfaces/ICrossGuardCallback.sol";
import {CrossGuardIdentity} from "../../src/libraries/CrossGuardIdentity.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title M006RecoveryTest
/// @notice Comprehensive verification suite for M006 Controlled Callback Recovery,
///         Event Idempotency, Monotonic Nonce Ordering, and Cross-Chain Reconciliation
///         preserving all invariants on M007.1 canonical position identity.
contract M006RecoveryTest is Test {
    TestValuationSource oracle;
    RiskController riskController;
    CollateralVault vault;
    BorrowingController borrowingController;
    CrossGuardCallback crossGuardCallback;
    CrossGuardReactive reactiveContract;
    MockOmniSystemContract mockSystem;
    MockCallbackProxy callbackProxy;

    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 constant REACTIVE_LASNA_CHAIN_ID = 5318007;
    uint256 constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint64 constant CALLBACK_GAS_LIMIT = 300_000;
    uint256 constant RISK_THRESHOLD_BPS = 8000;

    address owner = address(0xAA);
    address alice = address(0xBB);
    address stranger = address(0xDD);
    address mockWeth = address(0x1111);
    address mockUsdc = address(0x2222);

    bytes32 constant ALICE_SALT = keccak256("position-m006-salt");
    bytes32 positionId;

    event StaleOriginEventIgnored(bytes32 indexed positionId, uint256 receivedNonce, uint256 latestNonce);
    event CallbackRetryRequested(
        bytes32 indexed positionId, uint256 indexed nonce, uint8 retryAttempt, bytes32 reasonCode
    );

    function setUp() public {
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);

        vm.startPrank(owner);
        oracle = new TestValuationSource(owner);
        oracle.setAssetPrice(mockWeth, 3000e8);
        oracle.setAssetPrice(mockUsdc, 1e8);

        riskController = new RiskController(owner, RISK_THRESHOLD_BPS);
        vault = new CollateralVault(owner, address(oracle), address(riskController));
        riskController.setAuthorizedVault(address(vault), true);

        mockSystem = new MockOmniSystemContract();

        address predictedReactive = vm.computeCreateAddress(owner, vm.getNonce(owner));
        reactiveContract = new CrossGuardReactive(
            owner,
            address(mockSystem),
            BASE_SEPOLIA_CHAIN_ID,
            address(riskController),
            address(vault),
            UNICHAIN_SEPOLIA_CHAIN_ID,
            address(0),
            0
        );
        assertEq(address(reactiveContract), predictedReactive);

        callbackProxy = new MockCallbackProxy();
        borrowingController =
            new BorrowingController(owner, BASE_SEPOLIA_CHAIN_ID, address(riskController), address(vault));
        crossGuardCallback = new CrossGuardCallback(
            owner, address(callbackProxy), address(borrowingController), address(reactiveContract)
        );
        borrowingController.setCallbackAdapter(address(crossGuardCallback));

        reactiveContract.setDestinationConfig(
            UNICHAIN_SEPOLIA_CHAIN_ID, address(crossGuardCallback), CALLBACK_GAS_LIMIT
        );
        vm.stopPrank();

        vm.prank(alice);
        positionId = borrowingController.registerPosition(ALICE_SALT);

        vm.startPrank(alice);
        bytes32 openedId = vault.openPosition(ALICE_SALT, mockWeth, 2e18);
        assertEq(openedId, positionId);
        vault.recordBorrow(positionId, mockUsdc, 2000e18);
        vm.stopPrank();
    }

    function _eventData(address originVault, bytes32 salt, uint256 ltv, uint256 ts)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(CrossGuardIdentity.IDENTITY_VERSION, originVault, salt, ltv, RISK_THRESHOLD_BPS, ts);
    }

    function _triggerOriginBreach() internal returns (Vm.Log memory breachLog) {
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 1000e8);

        vm.recordLogs();
        vault.evaluatePositionRisk(positionId);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 breachTopic = reactiveContract.RISK_BREACH_TOPIC_0();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(riskController) && entries[i].topics[0] == breachTopic) {
                return entries[i];
            }
        }
        revert("Breach log not found");
    }

    function _toLogRecord(Vm.Log memory log) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(log.topics[0]),
            topic_1: uint256(log.topics[1]),
            topic_2: uint256(log.topics[2]),
            topic_3: uint256(log.topics[3]),
            data: log.data,
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function test01_NormalBreachDelivery() public {
        Vm.Log memory breachLog = _triggerOriginBreach();
        IReactive.LogRecord memory rec = _toLogRecord(breachLog);

        vm.prank(address(mockSystem));
        reactiveContract.react(rec);

        assertEq(mockSystem.requestedCallbackCount(), 1);
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = mockSystem.getLastRequestedCallback();

        (bool success,) =
            callbackProxy.executeCallback(cb.recipient, cb.payload, cb.gasLimit, address(reactiveContract));
        assertTrue(success);

        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);
    }

    function test02_DuplicateOriginEvaluationIdempotency() public {
        _triggerOriginBreach();
        assertEq(riskController.positionNonce(positionId), 1);
        assertTrue(riskController.isPositionBreached(positionId));

        vm.recordLogs();
        (bool stillBreached,, uint256 repeatNonce) = vault.evaluatePositionRisk(positionId);
        assertTrue(stillBreached);
        assertEq(repeatNonce, 1);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 breachTopic = reactiveContract.RISK_BREACH_TOPIC_0();
        bool foundSecondEvent = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(riskController) && entries[i].topics[0] == breachTopic) {
                foundSecondEvent = true;
                break;
            }
        }
        assertFalse(foundSecondEvent);

        IReactive.LogRecord memory duplicateLog = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(breachTopic),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 1,
            data: _eventData(address(vault), ALICE_SALT, 10000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(mockSystem));
        reactiveContract.react(duplicateLog);
        assertEq(mockSystem.requestedCallbackCount(), 1);

        vm.prank(address(mockSystem));
        vm.expectEmit(true, false, false, true);
        emit StaleOriginEventIgnored(positionId, 1, 1);
        reactiveContract.react(duplicateLog);
        assertEq(mockSystem.requestedCallbackCount(), 1);
    }

    function test03_CallbackDeliveryFailureLeavesStateUnmutated() public {
        Vm.Log memory breachLog = _triggerOriginBreach();
        IReactive.LogRecord memory rec = _toLogRecord(breachLog);

        vm.prank(address(mockSystem));
        reactiveContract.react(rec);

        ISystemContract.CallbackConfiguration_V_1_0 memory cb = mockSystem.getLastRequestedCallback();

        (bool success,) = callbackProxy.executeCallback(cb.recipient, cb.payload, 1000, address(reactiveContract));
        assertFalse(success);

        assertFalse(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 0);

        (uint256 nonce, CrossGuardReactive.CallbackType cType,, uint8 retries,) =
            reactiveContract.getLatestCallback(positionId);
        assertEq(nonce, 1);
        assertEq(uint8(cType), uint8(CrossGuardReactive.CallbackType.BREACH));
        assertEq(retries, 0);
    }

    function test04_SuccessfulSameNonceRecovery() public {
        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));

        ISystemContract.CallbackConfiguration_V_1_0 memory initialCb = mockSystem.getLastRequestedCallback();

        (bool initialSuccess,) =
            callbackProxy.executeCallback(initialCb.recipient, initialCb.payload, 1000, address(reactiveContract));
        assertFalse(initialSuccess);
        assertEq(borrowingController.lastProcessedNonce(positionId), 0);

        bytes32 reason = bytes32("RECOVERY_GAS_EXHAUSTION");
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit CallbackRetryRequested(positionId, 1, 1, reason);
        reactiveContract.retryFailedCallback(positionId, 1, reason);

        assertEq(mockSystem.requestedCallbackCount(), 2);
        ISystemContract.CallbackConfiguration_V_1_0 memory retriedCb = mockSystem.getLastRequestedCallback();

        assertEq(retriedCb.payload, initialCb.payload);
        assertEq(retriedCb.recipient, address(crossGuardCallback));

        (bool retryExecSuccess,) = callbackProxy.executeCallback(
            retriedCb.recipient, retriedCb.payload, retriedCb.gasLimit, address(reactiveContract)
        );
        assertTrue(retryExecSuccess);

        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);
    }

    function test05_RetryAfterSuccessfulDeliveryRevertsOnDestination() public {
        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));

        ISystemContract.CallbackConfiguration_V_1_0 memory initialCb = mockSystem.getLastRequestedCallback();

        (bool initialSuccess,) = callbackProxy.executeCallback(
            initialCb.recipient, initialCb.payload, initialCb.gasLimit, address(reactiveContract)
        );
        assertTrue(initialSuccess);
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);

        vm.prank(owner);
        reactiveContract.retryFailedCallback(positionId, 1, bytes32("RECOVERY_MISTAKE"));

        ISystemContract.CallbackConfiguration_V_1_0 memory retriedCb = mockSystem.getLastRequestedCallback();

        (bool replaySuccess,) = callbackProxy.executeCallback(
            retriedCb.recipient, retriedCb.payload, retriedCb.gasLimit, address(reactiveContract)
        );
        assertFalse(replaySuccess);
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);
    }

    function test06_OutOfOrderEventHandling() public {
        IReactive.LogRecord memory resolutionLog = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_RESOLVED_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 2,
            data: _eventData(address(vault), ALICE_SALT, 4000, block.timestamp + 10),
            block_number: 105,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(mockSystem));
        reactiveContract.react(resolutionLog);

        assertEq(reactiveContract.latestOriginNonce(positionId), 2);
        assertEq(mockSystem.requestedCallbackCount(), 1);

        IReactive.LogRecord memory delayedBreachLog = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 1,
            data: _eventData(address(vault), ALICE_SALT, 9000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(mockSystem));
        vm.expectEmit(true, false, false, true);
        emit StaleOriginEventIgnored(positionId, 1, 2);
        reactiveContract.react(delayedBreachLog);

        assertEq(mockSystem.requestedCallbackCount(), 1);
    }

    function test07_OldRetryAfterNewerStateRejected() public {
        IReactive.LogRecord memory log1 = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 1,
            data: _eventData(address(vault), ALICE_SALT, 8500, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        vm.prank(address(mockSystem));
        reactiveContract.react(log1);

        IReactive.LogRecord memory log2 = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_RESOLVED_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 2,
            data: _eventData(address(vault), ALICE_SALT, 4000, block.timestamp + 5),
            block_number: 102,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        vm.prank(address(mockSystem));
        reactiveContract.react(log2);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.NonceMismatch.selector, 1, 2));
        reactiveContract.retryFailedCallback(positionId, 1, bytes32("RETRY_SUPERSEDED"));
    }

    function test08_RetryLimitEnforcement() public {
        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));

        bytes32 reason = bytes32("RECOVERY_ATTEMPT");

        for (uint8 i = 1; i <= 3; i++) {
            vm.prank(owner);
            reactiveContract.retryFailedCallback(positionId, 1, reason);
            (,,, uint8 count,) = reactiveContract.getLatestCallback(positionId);
            assertEq(count, i);
        }

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CrossGuardReactive.RetryLimitExceeded.selector, positionId, uint8(3), uint8(3))
        );
        reactiveContract.retryFailedCallback(positionId, 1, reason);

        IReactive.LogRecord memory log2 = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_RESOLVED_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 2,
            data: _eventData(address(vault), ALICE_SALT, 4000, block.timestamp + 10),
            block_number: 105,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        vm.prank(address(mockSystem));
        reactiveContract.react(log2);

        (,,, uint8 resetCount,) = reactiveContract.getLatestCallback(positionId);
        assertEq(resetCount, 0);

        vm.prank(owner);
        reactiveContract.retryFailedCallback(positionId, 2, reason);
        (,,, uint8 countAfterReset,) = reactiveContract.getLatestCallback(positionId);
        assertEq(countAfterReset, 1);
    }

    function test09_UnauthorizedRetryReverts() public {
        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reactiveContract.retryFailedCallback(positionId, 1, bytes32("UNAUTHORIZED"));
    }

    function test10_InvalidRetryInputs() public {
        bytes32 reason = bytes32("RECOVERY_CHECK");

        vm.prank(owner);
        vm.expectRevert(CrossGuardReactive.InvalidPositionId.selector);
        reactiveContract.retryFailedCallback(bytes32(0), 1, reason);

        vm.prank(owner);
        vm.expectRevert(CrossGuardReactive.InvalidReasonCode.selector);
        reactiveContract.retryFailedCallback(positionId, 1, bytes32(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.NoCallbackPayloadStored.selector, positionId));
        reactiveContract.retryFailedCallback(positionId, 1, reason);

        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.NonceMismatch.selector, 999, 1));
        reactiveContract.retryFailedCallback(positionId, 999, reason);
    }

    function test11_MultiPositionIsolation() public {
        bytes32 bobSalt = keccak256("bob-salt-B");
        address bobUser = address(0xEEEE);

        vm.prank(bobUser);
        bytes32 posB = borrowingController.registerPosition(bobSalt);

        IReactive.LogRecord memory logA = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 1,
            data: _eventData(address(vault), ALICE_SALT, 8500, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        vm.prank(address(mockSystem));
        reactiveContract.react(logA);

        IReactive.LogRecord memory logB = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(posB),
            topic_2: uint256(uint160(bobUser)),
            topic_3: 1,
            data: _eventData(address(vault), bobSalt, 9000, block.timestamp),
            block_number: 101,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        vm.prank(address(mockSystem));
        reactiveContract.react(logB);

        vm.startPrank(owner);
        reactiveContract.retryFailedCallback(positionId, 1, bytes32("RETRY_A"));
        reactiveContract.retryFailedCallback(positionId, 1, bytes32("RETRY_A"));
        vm.stopPrank();

        (,,, uint8 retriesA,) = reactiveContract.getLatestCallback(positionId);
        (,,, uint8 retriesB,) = reactiveContract.getLatestCallback(posB);

        assertEq(retriesA, 2);
        assertEq(retriesB, 0);
    }

    function test12_AdministrativePauseProtection() public {
        vm.prank(owner);
        borrowingController.emergencyPauseBorrowing(positionId);
        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertTrue(borrowingController.pausedByAdmin(positionId));

        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));

        ISystemContract.CallbackConfiguration_V_1_0 memory cbBreach = mockSystem.getLastRequestedCallback();
        callbackProxy.executeCallback(
            cbBreach.recipient, cbBreach.payload, cbBreach.gasLimit, address(reactiveContract)
        );

        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertTrue(borrowingController.pausedByRiskBreach(positionId));
        assertTrue(borrowingController.pausedByAdmin(positionId));

        IReactive.LogRecord memory resLog = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_RESOLVED_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 2,
            data: _eventData(address(vault), ALICE_SALT, 4000, block.timestamp + 20),
            block_number: 110,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        vm.prank(address(mockSystem));
        reactiveContract.react(resLog);

        ISystemContract.CallbackConfiguration_V_1_0 memory cbRes = mockSystem.getLastRequestedCallback();
        callbackProxy.executeCallback(cbRes.recipient, cbRes.payload, cbRes.gasLimit, address(reactiveContract));

        assertFalse(borrowingController.pausedByRiskBreach(positionId));
        assertTrue(borrowingController.pausedByAdmin(positionId));
        assertTrue(borrowingController.isBorrowingPaused(positionId));

        vm.prank(owner);
        borrowingController.resumeBorrowing(positionId);
        assertFalse(borrowingController.isBorrowingPaused(positionId));
    }

    function test13_ConfigurationCorrection() public {
        vm.prank(owner);
        CrossGuardReactive unconfiguredReactive = new CrossGuardReactive(
            owner,
            address(mockSystem),
            BASE_SEPOLIA_CHAIN_ID,
            address(riskController),
            address(vault),
            UNICHAIN_SEPOLIA_CHAIN_ID,
            address(0),
            0
        );

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 1,
            data: _eventData(address(vault), ALICE_SALT, 8500, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        uint256 startCount = mockSystem.requestedCallbackCount();
        vm.prank(address(mockSystem));
        unconfiguredReactive.react(log);
        assertEq(mockSystem.requestedCallbackCount(), startCount);

        (
            uint256 nonce,
            CrossGuardReactive.CallbackType cType,,
            uint8 retries,
            CrossGuardReactive.DispatchStatus status
        ) = unconfiguredReactive.getLatestCallback(positionId);
        assertEq(nonce, 1);
        assertEq(uint8(cType), uint8(CrossGuardReactive.CallbackType.BREACH));
        assertEq(retries, 0);
        assertEq(uint8(status), uint8(CrossGuardReactive.DispatchStatus.PENDING_DISPATCH));

        vm.prank(owner);
        unconfiguredReactive.setDestinationConfig(
            UNICHAIN_SEPOLIA_CHAIN_ID, address(crossGuardCallback), CALLBACK_GAS_LIMIT
        );

        vm.prank(owner);
        unconfiguredReactive.dispatchPendingCallback(positionId, 1);
        assertEq(mockSystem.requestedCallbackCount(), startCount + 1);

        (,,,, CrossGuardReactive.DispatchStatus statusAfter) = unconfiguredReactive.getLatestCallback(positionId);
        assertEq(uint8(statusAfter), uint8(CrossGuardReactive.DispatchStatus.REQUESTED));

        vm.prank(address(mockSystem));
        unconfiguredReactive.react(log);
        assertEq(mockSystem.requestedCallbackCount(), startCount + 1);
    }

    function test14_InsufficientFundingDebtDiagnosis() public {
        assertEq(mockSystem.debt(address(reactiveContract)), 0);

        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));

        uint256 balBefore = address(reactiveContract).balance;
        vm.prank(owner);
        reactiveContract.retryFailedCallback(positionId, 1, bytes32("RECOVERY_CHECK_DEBT"));
        assertEq(address(reactiveContract).balance, balBefore);
    }

    function test15_FuzzRecoveryInvariants(uint8 extraRetries, uint16 fuzzLtv) public {
        uint256 validBreachLtv = bound(uint256(fuzzLtv), 8000, 10000);
        uint8 retriesToAttempt = uint8(bound(uint256(extraRetries), 1, 3));

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 1,
            data: _eventData(address(vault), ALICE_SALT, validBreachLtv, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(reactiveContract.latestOriginNonce(positionId), 1);

        for (uint8 i = 1; i <= retriesToAttempt; i++) {
            vm.prank(owner);
            reactiveContract.retryFailedCallback(positionId, 1, bytes32("FUZZ_RETRY"));
        }

        (uint256 storedNonce, CrossGuardReactive.CallbackType cType, bytes memory payload, uint8 count,) =
            reactiveContract.getLatestCallback(positionId);

        assertEq(storedNonce, 1);
        assertEq(uint8(cType), uint8(CrossGuardReactive.CallbackType.BREACH));
        assertEq(count, retriesToAttempt);
        assertTrue(count <= 3);

        bytes4 selector;
        assembly {
            selector := mload(add(payload, 32))
        }
        assertEq(selector, ICrossGuardCallback.handleRiskBreach.selector);
    }

    function test16_DeferredPendingDispatchCannotBeRetriedUntilSubmitted() public {
        vm.prank(owner);
        CrossGuardReactive unconf = new CrossGuardReactive(
            owner,
            address(mockSystem),
            BASE_SEPOLIA_CHAIN_ID,
            address(riskController),
            address(vault),
            UNICHAIN_SEPOLIA_CHAIN_ID,
            address(0),
            0
        );

        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        unconf.react(_toLogRecord(breachLog));

        vm.prank(owner);
        unconf.setDestinationConfig(UNICHAIN_SEPOLIA_CHAIN_ID, address(crossGuardCallback), CALLBACK_GAS_LIMIT);

        vm.prank(owner);
        vm.expectRevert(CrossGuardReactive.CallbackNotRequested.selector);
        unconf.retryFailedCallback(positionId, 1, bytes32("WRONG_PATH"));

        vm.prank(owner);
        unconf.dispatchPendingCallback(positionId, 1);
        (,,, uint8 retries, CrossGuardReactive.DispatchStatus st) = unconf.getLatestCallback(positionId);
        assertEq(retries, 0);
        assertEq(uint8(st), uint8(CrossGuardReactive.DispatchStatus.REQUESTED));
    }

    function test17_OnChainConfigDriftTargetsNewCallbackOnRetry() public {
        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));
        assertEq(mockSystem.getLastRequestedCallback().recipient, address(crossGuardCallback));

        address newCallback = address(0xBEEF00000000000000000000000000000000BEEf);
        vm.prank(owner);
        reactiveContract.setDestinationConfig(UNICHAIN_SEPOLIA_CHAIN_ID, newCallback, CALLBACK_GAS_LIMIT);

        vm.prank(owner);
        reactiveContract.retryFailedCallback(positionId, 1, bytes32("DRIFT_DEMO"));
        assertEq(mockSystem.getLastRequestedCallback().recipient, newCallback);
    }

    function test18_WorkstreamEUnauthorizedDispatchAndRetryGuardsRemainStrict() public {
        vm.prank(owner);
        CrossGuardReactive unconf = new CrossGuardReactive(
            owner,
            address(mockSystem),
            BASE_SEPOLIA_CHAIN_ID,
            address(riskController),
            address(vault),
            UNICHAIN_SEPOLIA_CHAIN_ID,
            address(0),
            0
        );

        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        unconf.react(_toLogRecord(breachLog));

        vm.prank(owner);
        unconf.setDestinationConfig(UNICHAIN_SEPOLIA_CHAIN_ID, address(crossGuardCallback), CALLBACK_GAS_LIMIT);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        unconf.dispatchPendingCallback(positionId, 1);

        vm.prank(owner);
        unconf.dispatchPendingCallback(positionId, 1);

        vm.prank(owner);
        borrowingController.emergencyPauseBorrowing(positionId);

        (,, bytes memory breachPayload,,) = unconf.getLatestCallback(positionId);
        callbackProxy.executeCallback(address(crossGuardCallback), breachPayload, CALLBACK_GAS_LIMIT, address(unconf));
        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertTrue(borrowingController.pausedByAdmin(positionId));
    }
}

/// @title M006RecoveryHandler
/// @notice Stateful handler driving valid, deferred, failed, replayed, and retried multi-chain sequences.
contract M006RecoveryHandler is Test {
    RiskController public riskController;
    CrossGuardReactive public reactiveContract;
    CrossGuardReactive public deferredReactive;
    MockOmniSystemContract public mockSystem;
    MockCallbackProxy public callbackProxy;
    CrossGuardCallback public crossGuardCallback;
    CrossGuardCallback public deferredCallback;
    BorrowingController public borrowingController;

    address public owner;
    address public vaultAddr;
    address public userA = address(0xA11C);
    address public userB = address(0xB0B0);
    bytes32 public constant saltA = keccak256("inv-salt-A");
    bytes32 public constant saltB = keccak256("inv-salt-B");
    bytes32 public posA;
    bytes32 public posB;

    uint256 constant BASE_CHAIN = 84532;
    uint256 constant DEST_CHAIN = 1301;

    uint256[2] public ghostMaxAcceptedNonce;
    uint256[2] public ghostMaxDestNonce;
    uint256 public ghostLastTouchedIndex;
    uint256[2] public ghostPosBNonceBeforeAOp;
    uint256 public ghostUnexpectedSuccessCount;
    bool public ghostIsolationViolated;
    bool public ghostConfusedPendingRetrySucceeded;

    mapping(bytes32 => mapping(uint256 => uint256)) public nonceSuccessCount;
    mapping(bytes32 => bytes) public recordedPayload;
    mapping(bytes32 => uint256) public recordedPayloadNonce;

    constructor(
        address _owner,
        address _vaultAddr,
        RiskController _riskController,
        CrossGuardReactive _reactiveContract,
        CrossGuardReactive _deferredReactive,
        MockOmniSystemContract _mockSystem,
        MockCallbackProxy _callbackProxy,
        CrossGuardCallback _crossGuardCallback,
        CrossGuardCallback _deferredCallback,
        BorrowingController _borrowingController
    ) {
        owner = _owner;
        vaultAddr = _vaultAddr;
        riskController = _riskController;
        reactiveContract = _reactiveContract;
        deferredReactive = _deferredReactive;
        mockSystem = _mockSystem;
        callbackProxy = _callbackProxy;
        crossGuardCallback = _crossGuardCallback;
        deferredCallback = _deferredCallback;
        borrowingController = _borrowingController;

        posA = CrossGuardIdentity.computePositionId(BASE_CHAIN, address(riskController), vaultAddr, userA, saltA);
        posB = CrossGuardIdentity.computePositionId(BASE_CHAIN, address(riskController), vaultAddr, userB, saltB);
    }

    function _pos(uint256 idx) internal view returns (bytes32, address, bytes32) {
        if (idx % 2 == 0) return (posA, userA, saltA);
        return (posB, userB, saltB);
    }

    function deliverOriginTransition(uint256 posIdx, bool breach) external {
        vm.chainId(BASE_CHAIN);
        uint256 idx = posIdx % 2;
        (bytes32 pos, address usr, bytes32 slt) = _pos(idx);
        uint256 otherIdx = 1 - idx;
        (bytes32 otherPos,,) = _pos(otherIdx);

        uint256 otherOriginBefore = reactiveContract.latestOriginNonce(otherPos);
        uint256 otherDestBefore = borrowingController.lastProcessedNonce(otherPos);

        uint256 colVal = 10_000e8;
        uint256 debtVal = breach ? 9_000e8 : 4_000e8;

        uint256 prevOriginNonce = riskController.positionNonce(pos);

        vm.prank(vaultAddr);
        (bool isBreached, uint256 ltvBps, uint256 originNonce) = riskController.assessRisk(pos, usr, colVal, debtVal);

        if (originNonce > prevOriginNonce) {
            bytes32 expectedTopic =
                isBreached ? reactiveContract.RISK_BREACH_TOPIC_0() : reactiveContract.RISK_RESOLVED_TOPIC_0();

            IReactive.LogRecord memory rec = IReactive.LogRecord({
                chain_id: BASE_CHAIN,
                _contract: address(riskController),
                topic_0: uint256(expectedTopic),
                topic_1: uint256(pos),
                topic_2: uint256(uint160(usr)),
                topic_3: originNonce,
                data: abi.encode(
                    CrossGuardIdentity.IDENTITY_VERSION,
                    vaultAddr,
                    slt,
                    ltvBps,
                    riskController.riskThresholdBps(),
                    block.timestamp
                ),
                block_number: block.number,
                op_code: 0,
                block_hash: 0,
                tx_hash: 0,
                log_index: 0
            });

            vm.startPrank(address(mockSystem));
            reactiveContract.react(rec);
            deferredReactive.react(rec);
            vm.stopPrank();

            recordedPayload[pos] = mockSystem.getLastRequestedCallback().payload;
            recordedPayloadNonce[pos] = originNonce;
        } else if (originNonce > 0 && posIdx % 5 == 0) {
            bytes32 staleTopic =
                isBreached ? reactiveContract.RISK_BREACH_TOPIC_0() : reactiveContract.RISK_RESOLVED_TOPIC_0();
            IReactive.LogRecord memory staleRec = IReactive.LogRecord({
                chain_id: BASE_CHAIN,
                _contract: address(riskController),
                topic_0: uint256(staleTopic),
                topic_1: uint256(pos),
                topic_2: uint256(uint160(usr)),
                topic_3: originNonce,
                data: abi.encode(
                    CrossGuardIdentity.IDENTITY_VERSION,
                    vaultAddr,
                    slt,
                    ltvBps,
                    riskController.riskThresholdBps(),
                    block.timestamp
                ),
                block_number: block.number,
                op_code: 0,
                block_hash: 0,
                tx_hash: 0,
                log_index: 0
            });
            vm.prank(address(mockSystem));
            reactiveContract.react(staleRec);
        }

        uint256 acceptedNow = reactiveContract.latestOriginNonce(pos);
        if (acceptedNow > ghostMaxAcceptedNonce[idx]) {
            ghostMaxAcceptedNonce[idx] = acceptedNow;
        }
        if (
            reactiveContract.latestOriginNonce(otherPos) != otherOriginBefore
                || borrowingController.lastProcessedNonce(otherPos) != otherDestBefore
        ) {
            ghostIsolationViolated = true;
        }
    }

    function exerciseDeferredContract(uint256 posIdx, bool configureAndDispatch) external {
        uint256 idx = posIdx % 2;
        (bytes32 pos,,) = _pos(idx);
        (uint256 dNonce,,,, CrossGuardReactive.DispatchStatus dStatus) = deferredReactive.getLatestCallback(pos);
        if (dNonce == 0) return;

        if (dStatus == CrossGuardReactive.DispatchStatus.PENDING_DISPATCH) {
            vm.prank(owner);
            try deferredReactive.retryFailedCallback(pos, dNonce, bytes32("BAD_RETRY_WHILE_PENDING")) {
                ghostConfusedPendingRetrySucceeded = true;
            } catch {}

            if (configureAndDispatch) {
                vm.startPrank(owner);
                if (deferredReactive.destinationCallback() == address(0)) {
                    deferredReactive.setDestinationConfig(DEST_CHAIN, address(deferredCallback), 300_000);
                }
                deferredReactive.dispatchPendingCallback(pos, dNonce);
                vm.stopPrank();
            }
        }
    }

    function executeStoredCallback(uint256 posIdx, bool sufficientGas) external {
        uint256 idx = posIdx % 2;
        (bytes32 pos,,) = _pos(idx);
        (bytes32 otherPos,,) = _pos(1 - idx);

        (uint256 nonce,, bytes memory payload,, CrossGuardReactive.DispatchStatus status) =
            reactiveContract.getLatestCallback(pos);
        if (status != CrossGuardReactive.DispatchStatus.REQUESTED || payload.length == 0) return;

        uint256 otherOriginBefore = reactiveContract.latestOriginNonce(otherPos);
        uint256 otherDestBefore = borrowingController.lastProcessedNonce(otherPos);
        uint64 gasLim = sufficientGas ? 300_000 : 1_000;

        uint256 prevDestNonce = borrowingController.lastProcessedNonce(pos);
        (bool ok,) =
            callbackProxy.executeCallback(address(crossGuardCallback), payload, gasLim, address(reactiveContract));

        if (ok) {
            nonceSuccessCount[pos][nonce]++;
            if (nonceSuccessCount[pos][nonce] > 1) {
                ghostUnexpectedSuccessCount++;
            }
        } else {
            if (borrowingController.lastProcessedNonce(pos) != prevDestNonce) {
                ghostUnexpectedSuccessCount++;
            }
        }

        uint256 destNow = borrowingController.lastProcessedNonce(pos);
        if (destNow > ghostMaxDestNonce[idx]) {
            ghostMaxDestNonce[idx] = destNow;
        }

        if (
            reactiveContract.latestOriginNonce(otherPos) != otherOriginBefore
                || borrowingController.lastProcessedNonce(otherPos) != otherDestBefore
        ) {
            ghostIsolationViolated = true;
        }
    }

    function tryRetryLatestCallback(uint256 posIdx) external {
        uint256 idx = posIdx % 2;
        (bytes32 pos,,) = _pos(idx);
        (uint256 nonce,,,, CrossGuardReactive.DispatchStatus status) = reactiveContract.getLatestCallback(pos);
        if (nonce == 0) return;

        vm.prank(owner);
        try reactiveContract.retryFailedCallback(pos, nonce, bytes32("INV_RETRY")) {
            if (status == CrossGuardReactive.DispatchStatus.PENDING_DISPATCH) {
                ghostConfusedPendingRetrySucceeded = true;
            }
        } catch {}
    }

    function tryReplayOldPayload(uint256 posIdx) external {
        uint256 idx = posIdx % 2;
        (bytes32 pos,,) = _pos(idx);
        bytes memory oldPayload = recordedPayload[pos];
        uint256 oldNonce = recordedPayloadNonce[pos];
        if (oldPayload.length == 0) return;

        uint256 destNow = borrowingController.lastProcessedNonce(pos);
        if (oldNonce <= destNow) {
            (bool ok,) = callbackProxy.executeCallback(
                address(crossGuardCallback), oldPayload, 300_000, address(reactiveContract)
            );
            if (ok) {
                ghostUnexpectedSuccessCount++;
            }
        }
    }
}

/// @title M006RecoveryInvariantTest
/// @notice Handler-based stateful invariant test suite for CrossGuard M006.1 recovery semantics.
contract M006RecoveryInvariantTest is Test {
    RiskController riskController;
    CrossGuardReactive reactiveContract;
    CrossGuardReactive deferredReactive;
    MockOmniSystemContract mockSystem;
    MockCallbackProxy callbackProxy;
    CrossGuardCallback crossGuardCallback;
    CrossGuardCallback deferredCallback;
    BorrowingController borrowingController;
    M006RecoveryHandler handler;

    address owner = address(0xAA);
    address vaultAddr = address(0x5555);

    function setUp() public {
        vm.chainId(84532);
        vm.startPrank(owner);
        riskController = new RiskController(owner, 8000);
        riskController.setAuthorizedVault(vaultAddr, true);

        mockSystem = new MockOmniSystemContract();
        address predictedReactive = vm.computeCreateAddress(owner, vm.getNonce(owner));
        reactiveContract = new CrossGuardReactive(
            owner, address(mockSystem), 84532, address(riskController), vaultAddr, 1301, address(0), 0
        );
        assertEq(address(reactiveContract), predictedReactive);

        deferredReactive = new CrossGuardReactive(
            owner, address(mockSystem), 84532, address(riskController), vaultAddr, 0, address(0), 0
        );

        callbackProxy = new MockCallbackProxy();
        borrowingController = new BorrowingController(owner, 84532, address(riskController), vaultAddr);
        crossGuardCallback = new CrossGuardCallback(
            owner, address(callbackProxy), address(borrowingController), address(reactiveContract)
        );
        deferredCallback = new CrossGuardCallback(
            owner, address(callbackProxy), address(borrowingController), address(deferredReactive)
        );
        borrowingController.setCallbackAdapter(address(crossGuardCallback));
        reactiveContract.setDestinationConfig(1301, address(crossGuardCallback), 300_000);
        vm.stopPrank();

        handler = new M006RecoveryHandler(
            owner,
            vaultAddr,
            riskController,
            reactiveContract,
            deferredReactive,
            mockSystem,
            callbackProxy,
            crossGuardCallback,
            deferredCallback,
            borrowingController
        );

        vm.startPrank(vaultAddr);
        riskController.registerPositionIdentity(handler.posA(), handler.userA(), handler.saltA());
        riskController.registerPositionIdentity(handler.posB(), handler.userB(), handler.saltB());
        vm.stopPrank();

        vm.prank(handler.userA());
        borrowingController.registerPosition(handler.saltA());
        vm.prank(handler.userB());
        borrowingController.registerPosition(handler.saltB());

        targetContract(address(handler));
    }

    function invariant_AcceptedNoncesNeverDecrease() public view {
        assertGe(reactiveContract.latestOriginNonce(handler.posA()), handler.ghostMaxAcceptedNonce(0));
        assertGe(reactiveContract.latestOriginNonce(handler.posB()), handler.ghostMaxAcceptedNonce(1));
    }

    function invariant_DestinationProcessedNoncesNeverDecrease() public view {
        assertGe(borrowingController.lastProcessedNonce(handler.posA()), handler.ghostMaxDestNonce(0));
        assertGe(borrowingController.lastProcessedNonce(handler.posB()), handler.ghostMaxDestNonce(1));
    }

    function invariant_RetryCountNeverExceedsThree() public view {
        (,,, uint8 retriesA,) = reactiveContract.getLatestCallback(handler.posA());
        (,,, uint8 retriesB,) = reactiveContract.getLatestCallback(handler.posB());
        (,,, uint8 defRetriesA,) = deferredReactive.getLatestCallback(handler.posA());
        (,,, uint8 defRetriesB,) = deferredReactive.getLatestCallback(handler.posB());
        assertLe(retriesA, 3);
        assertLe(retriesB, 3);
        assertLe(defRetriesA, 3);
        assertLe(defRetriesB, 3);
    }

    function invariant_PendingAndRequestedNeverConfused() public view {
        assertFalse(handler.ghostConfusedPendingRetrySucceeded());
    }

    function invariant_PositionIsolationPreserved() public view {
        assertFalse(handler.ghostIsolationViolated());
    }

    function invariant_NoDuplicateOrStaleDestinationApplication() public view {
        assertEq(handler.ghostUnexpectedSuccessCount(), 0);
    }
}

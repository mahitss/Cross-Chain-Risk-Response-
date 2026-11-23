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
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title M006RecoveryTest
/// @notice Comprehensive verification suite for M006: Controlled Callback Recovery,
///         Event Idempotency, Monotonic Nonce Ordering, and Cross-Chain Reconciliation.
contract M006RecoveryTest is Test {
    // Infrastructure
    TestValuationSource oracle;
    RiskController riskController;
    CollateralVault vault;
    BorrowingController borrowingController;
    CrossGuardCallback crossGuardCallback;
    CrossGuardReactive reactiveContract;
    MockOmniSystemContract mockSystem;
    MockCallbackProxy callbackProxy;

    // Topology
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 constant REACTIVE_LASNA_CHAIN_ID = 5318007;
    uint256 constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint64 constant CALLBACK_GAS_LIMIT = 300_000;
    uint256 constant RISK_THRESHOLD_BPS = 8000; // 80%

    // Actors
    address owner = address(0xAA);
    address alice = address(0xBB);
    address stranger = address(0xDD);
    address mockWeth = address(0x1111);
    address mockUsdc = address(0x2222);

    bytes32 positionId;

    event StaleOriginEventIgnored(bytes32 indexed positionId, uint256 receivedNonce, uint256 latestNonce);
    event CallbackRetryRequested(
        bytes32 indexed positionId, uint256 indexed nonce, uint8 retryAttempt, bytes32 reasonCode
    );

    function setUp() public {
        positionId = keccak256(abi.encodePacked(alice, "position-m006", BASE_SEPOLIA_CHAIN_ID));

        vm.startPrank(owner);
        // 1. Origin
        oracle = new TestValuationSource(owner);
        oracle.setAssetPrice(mockWeth, 3000e8);
        oracle.setAssetPrice(mockUsdc, 1e8);

        riskController = new RiskController(owner, RISK_THRESHOLD_BPS);
        vault = new CollateralVault(owner, address(oracle), address(riskController));
        riskController.setAuthorizedVault(address(vault), true);

        // 2. Reactive
        mockSystem = new MockOmniSystemContract();

        // Predict address
        address predictedReactive = vm.computeCreateAddress(owner, vm.getNonce(owner));
        reactiveContract = new CrossGuardReactive(
            owner,
            address(mockSystem),
            BASE_SEPOLIA_CHAIN_ID,
            address(riskController),
            UNICHAIN_SEPOLIA_CHAIN_ID,
            address(0),
            0
        );
        assertEq(address(reactiveContract), predictedReactive);

        // 3. Destination
        callbackProxy = new MockCallbackProxy();
        borrowingController = new BorrowingController(owner);
        crossGuardCallback = new CrossGuardCallback(
            owner, address(callbackProxy), address(borrowingController), address(reactiveContract)
        );
        borrowingController.setCallbackAdapter(address(crossGuardCallback));

        // Link destination config
        reactiveContract.setDestinationConfig(
            UNICHAIN_SEPOLIA_CHAIN_ID, address(crossGuardCallback), CALLBACK_GAS_LIMIT
        );
        vm.stopPrank();

        // Register position and set healthy state
        vm.prank(alice);
        borrowingController.registerPosition(positionId);

        vm.startPrank(alice);
        vault.depositCollateral(positionId, mockWeth, 2e18); // $6,000
        vault.recordBorrow(positionId, mockUsdc, 2000e18); // $2,000 (33.33% LTV)
        vm.stopPrank();
    }

    // Helper: Trigger price drop and evaluate on origin
    function _triggerOriginBreach() internal returns (Vm.Log memory breachLog) {
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2000e8); // $4,000 collateral, $2,000 debt -> 50%? Wait, let's make debt 3600:
        // Let's borrow more to reach breach or set price lower:
        // Collateral 2 WETH at $1000 = $2000, Debt = $2000 -> 100% LTV >= 80%
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

    // ==========================================
    // 1. Normal Breach Delivery
    // ==========================================
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

    // ==========================================
    // 2. Duplicate Origin Evaluation Idempotency
    // ==========================================
    function test02_DuplicateOriginEvaluationIdempotency() public {
        _triggerOriginBreach();
        assertEq(riskController.positionNonce(positionId), 1);
        assertTrue(riskController.isPositionBreached(positionId));

        // Evaluate again while position remains breached
        vm.recordLogs();
        (bool stillBreached,, uint256 repeatNonce) = vault.evaluatePositionRisk(positionId);
        assertTrue(stillBreached);
        assertEq(repeatNonce, 1, "Nonce must not increment on repeated breach");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 breachTopic = reactiveContract.RISK_BREACH_TOPIC_0();
        bool foundSecondEvent = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(riskController) && entries[i].topics[0] == breachTopic) {
                foundSecondEvent = true;
                break;
            }
        }
        assertFalse(foundSecondEvent, "No RiskBreach event emitted on repeated breach");

        // If duplicate event is replayed to Reactive Lasna, it ignores it
        IReactive.LogRecord memory duplicateLog = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(breachTopic),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 1,
            data: abi.encode(10000, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        // First delivery:
        vm.prank(address(mockSystem));
        reactiveContract.react(duplicateLog);
        assertEq(mockSystem.requestedCallbackCount(), 1);

        // Second delivery (replay):
        vm.prank(address(mockSystem));
        vm.expectEmit(true, false, false, true);
        emit StaleOriginEventIgnored(positionId, 1, 1);
        reactiveContract.react(duplicateLog);
        assertEq(mockSystem.requestedCallbackCount(), 1, "Duplicate log must not request callback");
    }

    // ==========================================
    // 3. Callback Delivery Failure Leaves State Unmutated
    // ==========================================
    function test03_CallbackDeliveryFailureLeavesStateUnmutated() public {
        Vm.Log memory breachLog = _triggerOriginBreach();
        IReactive.LogRecord memory rec = _toLogRecord(breachLog);

        vm.prank(address(mockSystem));
        reactiveContract.react(rec);

        ISystemContract.CallbackConfiguration_V_1_0 memory cb = mockSystem.getLastRequestedCallback();

        // Destination delivery fails (e.g. out of gas or revert simulated via insufficient gas limit)
        (bool success,) = callbackProxy.executeCallback(cb.recipient, cb.payload, 1000, address(reactiveContract));
        assertFalse(success, "Callback execution should fail due to out-of-gas");

        // Destination state remains completely unmutated
        assertFalse(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 0);

        // Reactive contract holds stored callback state ready for recovery
        (uint256 nonce, CrossGuardReactive.CallbackType cType,, uint8 retries) =
            reactiveContract.getLatestCallback(positionId);
        assertEq(nonce, 1);
        assertEq(uint8(cType), uint8(CrossGuardReactive.CallbackType.BREACH));
        assertEq(retries, 0);
    }

    // ==========================================
    // 4. Successful Same-Nonce Recovery
    // ==========================================
    function test04_SuccessfulSameNonceRecovery() public {
        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));

        ISystemContract.CallbackConfiguration_V_1_0 memory initialCb = mockSystem.getLastRequestedCallback();

        // Initial callback fails
        (bool initialSuccess,) =
            callbackProxy.executeCallback(initialCb.recipient, initialCb.payload, 1000, address(reactiveContract));
        assertFalse(initialSuccess);
        assertEq(borrowingController.lastProcessedNonce(positionId), 0);

        // Owner investigates, verifies preflight conditions, and initiates retry
        bytes32 reason = bytes32("RECOVERY_GAS_EXHAUSTION");
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit CallbackRetryRequested(positionId, 1, 1, reason);
        reactiveContract.retryFailedCallback(positionId, 1, reason);

        assertEq(mockSystem.requestedCallbackCount(), 2);
        ISystemContract.CallbackConfiguration_V_1_0 memory retriedCb = mockSystem.getLastRequestedCallback();

        // Ensure retried payload and gas configuration match
        assertEq(retriedCb.payload, initialCb.payload);
        assertEq(retriedCb.recipient, address(crossGuardCallback));

        // Destination executes retried callback with adequate gas
        (bool retryExecSuccess,) = callbackProxy.executeCallback(
            retriedCb.recipient, retriedCb.payload, retriedCb.gasLimit, address(reactiveContract)
        );
        assertTrue(retryExecSuccess, "Retried callback must succeed");

        // Destination state successfully paused and nonce advanced
        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);
    }

    // ==========================================
    // 5. Retry After Successful Delivery Reverts on Destination
    // ==========================================
    function test05_RetryAfterSuccessfulDeliveryRevertsOnDestination() public {
        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));

        ISystemContract.CallbackConfiguration_V_1_0 memory initialCb = mockSystem.getLastRequestedCallback();

        // Initial callback SUCCEEDS
        (bool initialSuccess,) = callbackProxy.executeCallback(
            initialCb.recipient, initialCb.payload, initialCb.gasLimit, address(reactiveContract)
        );
        assertTrue(initialSuccess);
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);

        // Owner mistakenly retries same nonce
        vm.prank(owner);
        reactiveContract.retryFailedCallback(positionId, 1, bytes32("RECOVERY_MISTAKE"));

        ISystemContract.CallbackConfiguration_V_1_0 memory retriedCb = mockSystem.getLastRequestedCallback();

        // Destination receives retry of already-processed nonce 1
        // Proxy execution fails because BorrowingController reverts with InvalidNonce(1, 1)
        (bool replaySuccess,) = callbackProxy.executeCallback(
            retriedCb.recipient, retriedCb.payload, retriedCb.gasLimit, address(reactiveContract)
        );
        assertFalse(replaySuccess, "Replaying already-processed nonce must revert on destination");
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);
    }

    // ==========================================
    // 6. Out-of-Order Event Handling
    // ==========================================
    function test06_OutOfOrderEventHandling() public {
        // Step 1: Simulate resolution nonce 2 arriving BEFORE breach nonce 1
        IReactive.LogRecord memory resolutionLog = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_RESOLVED_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 2,
            data: abi.encode(4000, 8000, block.timestamp + 10),
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

        // Step 2: Delayed breach log with nonce 1 arrives
        IReactive.LogRecord memory delayedBreachLog = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 1,
            data: abi.encode(9000, 8000, block.timestamp),
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

        assertEq(mockSystem.requestedCallbackCount(), 1, "Delayed older nonce must not dispatch callback");
    }

    // ==========================================
    // 7. Old Retry After Newer State Rejected
    // ==========================================
    function test07_OldRetryAfterNewerStateRejected() public {
        // Breach nonce 1 arrives
        IReactive.LogRecord memory log1 = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 1,
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        vm.prank(address(mockSystem));
        reactiveContract.react(log1);

        // Resolution nonce 2 arrives
        IReactive.LogRecord memory log2 = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_RESOLVED_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 2,
            data: abi.encode(4000, 8000, block.timestamp + 5),
            block_number: 102,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        vm.prank(address(mockSystem));
        reactiveContract.react(log2);

        // Attempting to retry obsolete nonce 1 reverts with NonceMismatch(1, 2)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.NonceMismatch.selector, 1, 2));
        reactiveContract.retryFailedCallback(positionId, 1, bytes32("RETRY_SUPERSEDED"));
    }

    // ==========================================
    // 8. Retry Limit Enforcement
    // ==========================================
    function test08_RetryLimitEnforcement() public {
        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));

        bytes32 reason = bytes32("RECOVERY_ATTEMPT");

        // 3 retries permitted
        for (uint8 i = 1; i <= 3; i++) {
            vm.prank(owner);
            reactiveContract.retryFailedCallback(positionId, 1, reason);
            (,,, uint8 count) = reactiveContract.getLatestCallback(positionId);
            assertEq(count, i);
        }

        // 4th retry reverts with RetryLimitExceeded
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CrossGuardReactive.RetryLimitExceeded.selector, positionId, uint8(3), uint8(3))
        );
        reactiveContract.retryFailedCallback(positionId, 1, reason);

        // New event arrives with nonce 2 -> resets retry budget
        IReactive.LogRecord memory log2 = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_RESOLVED_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 2,
            data: abi.encode(4000, 8000, block.timestamp + 10),
            block_number: 105,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        vm.prank(address(mockSystem));
        reactiveContract.react(log2);

        (,,, uint8 resetCount) = reactiveContract.getLatestCallback(positionId);
        assertEq(resetCount, 0, "New origin event must reset retry count");

        // Retry on nonce 2 succeeds
        vm.prank(owner);
        reactiveContract.retryFailedCallback(positionId, 2, reason);
        (,,, uint8 countAfterReset) = reactiveContract.getLatestCallback(positionId);
        assertEq(countAfterReset, 1);
    }

    // ==========================================
    // 9. Unauthorized Retry
    // ==========================================
    function test09_UnauthorizedRetryReverts() public {
        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reactiveContract.retryFailedCallback(positionId, 1, bytes32("UNAUTHORIZED"));
    }

    // ==========================================
    // 10. Invalid Retry Inputs
    // ==========================================
    function test10_InvalidRetryInputs() public {
        bytes32 reason = bytes32("RECOVERY_CHECK");

        // Zero positionId
        vm.prank(owner);
        vm.expectRevert(CrossGuardReactive.InvalidPositionId.selector);
        reactiveContract.retryFailedCallback(bytes32(0), 1, reason);

        // Zero reasonCode
        vm.prank(owner);
        vm.expectRevert(CrossGuardReactive.InvalidReasonCode.selector);
        reactiveContract.retryFailedCallback(positionId, 1, bytes32(0));

        // No callback stored
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.NoCallbackPayloadStored.selector, positionId));
        reactiveContract.retryFailedCallback(positionId, 1, reason);

        // Store breach
        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));

        // Nonce mismatch
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.NonceMismatch.selector, 999, 1));
        reactiveContract.retryFailedCallback(positionId, 999, reason);
    }

    // ==========================================
    // 11. Multi-Position Isolation
    // ==========================================
    function test11_MultiPositionIsolation() public {
        bytes32 posB = keccak256("position-B");
        address bobUser = address(0xEEEE);

        vm.prank(bobUser);
        borrowingController.registerPosition(posB);

        // Position A breach
        IReactive.LogRecord memory logA = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 1,
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        vm.prank(address(mockSystem));
        reactiveContract.react(logA);

        // Position B breach
        IReactive.LogRecord memory logB = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(posB),
            topic_2: uint256(uint160(bobUser)),
            topic_3: 1,
            data: abi.encode(9000, 8000, block.timestamp),
            block_number: 101,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        vm.prank(address(mockSystem));
        reactiveContract.react(logB);

        // Retry Position A twice
        vm.startPrank(owner);
        reactiveContract.retryFailedCallback(positionId, 1, bytes32("RETRY_A"));
        reactiveContract.retryFailedCallback(positionId, 1, bytes32("RETRY_A"));
        vm.stopPrank();

        (,,, uint8 retriesA) = reactiveContract.getLatestCallback(positionId);
        (,,, uint8 retriesB) = reactiveContract.getLatestCallback(posB);

        assertEq(retriesA, 2, "Position A retries should be 2");
        assertEq(retriesB, 0, "Position B retries must remain 0");
    }

    // ==========================================
    // 12. Administrative Pause Protection
    // ==========================================
    function test12_AdministrativePauseProtection() public {
        // Destination owner pauses position administratively
        vm.prank(owner);
        borrowingController.emergencyPauseBorrowing(positionId);
        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertTrue(borrowingController.pausedByAdmin(positionId));

        // Breach arrives
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

        // Resolution arrives (nonce 2)
        IReactive.LogRecord memory resLog = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_RESOLVED_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 2,
            data: abi.encode(4000, 8000, block.timestamp + 20),
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

        // Risk breach is cleared, but admin pause keeps borrowing paused
        assertFalse(borrowingController.pausedByRiskBreach(positionId));
        assertTrue(borrowingController.pausedByAdmin(positionId));
        assertTrue(borrowingController.isBorrowingPaused(positionId));

        // Only explicit admin resume unpauses
        vm.prank(owner);
        borrowingController.resumeBorrowing(positionId);
        assertFalse(borrowingController.isBorrowingPaused(positionId));
    }

    // ==========================================
    // 13. Configuration Correction
    // ==========================================
    function test13_ConfigurationCorrection() public {
        // Deploy fresh reactive contract with unconfigured destination
        vm.prank(owner);
        CrossGuardReactive unconfiguredReactive = new CrossGuardReactive(
            owner,
            address(mockSystem),
            BASE_SEPOLIA_CHAIN_ID,
            address(riskController),
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
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        uint256 startCount = mockSystem.requestedCallbackCount();
        vm.prank(address(mockSystem));
        unconfiguredReactive.react(log);
        assertEq(mockSystem.requestedCallbackCount(), startCount, "No callback while unconfigured");

        // Owner corrects configuration
        vm.prank(owner);
        unconfiguredReactive.setDestinationConfig(
            UNICHAIN_SEPOLIA_CHAIN_ID, address(crossGuardCallback), CALLBACK_GAS_LIMIT
        );

        // Now event succeeds
        vm.prank(address(mockSystem));
        unconfiguredReactive.react(log);
        assertEq(mockSystem.requestedCallbackCount(), startCount + 1, "Callback succeeds after config correction");
    }

    // ==========================================
    // 14. Insufficient Funding / Debt Diagnosis
    // ==========================================
    function test14_InsufficientFundingDebtDiagnosis() public {
        // Verify mock system debt is inspectable
        assertEq(mockSystem.debt(address(reactiveContract)), 0);

        // Ensure retry does not perform unauthorized state mutations or auto-funding
        Vm.Log memory breachLog = _triggerOriginBreach();
        vm.prank(address(mockSystem));
        reactiveContract.react(_toLogRecord(breachLog));

        uint256 balBefore = address(reactiveContract).balance;
        vm.prank(owner);
        reactiveContract.retryFailedCallback(positionId, 1, bytes32("RECOVERY_CHECK_DEBT"));
        assertEq(address(reactiveContract).balance, balBefore, "Retry must not spend or fund reactive contract balance");
    }

    // ==========================================
    // 15. Fuzz / Property Tests
    // ==========================================
    function test15_FuzzRecoveryInvariants(uint8 extraRetries, uint16 fuzzLtv) public {
        // Bound inputs
        uint256 validBreachLtv = bound(uint256(fuzzLtv), 8000, 10000);
        uint8 retriesToAttempt = uint8(bound(uint256(extraRetries), 1, 3));

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: BASE_SEPOLIA_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(alice)),
            topic_3: 1,
            data: abi.encode(validBreachLtv, 8000, block.timestamp),
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

        (uint256 storedNonce, CrossGuardReactive.CallbackType cType, bytes memory payload, uint8 count) =
            reactiveContract.getLatestCallback(positionId);

        assertEq(storedNonce, 1);
        assertEq(uint8(cType), uint8(CrossGuardReactive.CallbackType.BREACH));
        assertEq(count, retriesToAttempt);
        assertTrue(count <= 3, "Retry count must never exceed 3");

        bytes4 selector;
        assembly {
            selector := mload(add(payload, 32))
        }
        assertEq(selector, ICrossGuardCallback.handleRiskBreach.selector);
    }
}

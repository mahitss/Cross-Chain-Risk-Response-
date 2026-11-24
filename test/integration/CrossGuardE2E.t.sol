// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {TestValuationSource} from "../../src/origin/TestValuationSource.sol";
import {RiskController} from "../../src/origin/RiskController.sol";
import {CollateralVault} from "../../src/origin/CollateralVault.sol";
import {BorrowingController} from "../../src/destination/BorrowingController.sol";
import {CrossGuardCallback} from "../../src/destination/CrossGuardCallback.sol";
import {CrossGuardReactive} from "../../src/reactive/CrossGuardReactive.sol";
import {MockOmniSystemContract} from "../mocks/MockOmniSystemContract.sol";
import {MockCallbackProxy} from "reactive-test-lib/mock/MockCallbackProxy.sol";
import {ISystemContract} from "../../src/interfaces/ISystemContract.sol";
import {ICrossGuardCallback} from "../../src/interfaces/ICrossGuardCallback.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

/// @title CrossGuardE2ETest
/// @notice End-to-end integration test suite verifying the Omni-native CrossGuard pipeline:
///         Base Sepolia (84532) -> Reactive Lasna (5318007) -> Unichain Sepolia (1301).
///         Verifies Omni system contract callback requests, complete payload structures,
///         injected Reactive contract address authentication, and replay protection without legacy events.
contract CrossGuardE2ETest is Test {
    // Contracts
    TestValuationSource oracle;
    RiskController riskController;
    CollateralVault vault;
    BorrowingController borrowingController;
    CrossGuardCallback crossGuardCallback;
    CrossGuardReactive crossGuardReactive;
    MockOmniSystemContract omniSys;
    MockCallbackProxy callbackProxy;

    // Chain IDs
    uint256 constant ORIGIN_CHAIN_ID = 84532; // Base Sepolia
    uint256 constant DEST_CHAIN_ID = 1301; // Unichain Sepolia
    uint64 constant CALLBACK_GAS_LIMIT = 300_000;
    uint256 constant RISK_THRESHOLD_BPS = 8000; // 80%

    // Actors & Assets
    address owner = address(0xAA);
    address alice = address(0xBB);
    address bob = address(0xCC);
    address mockWeth = address(0x1111);
    address mockUsdc = address(0x2222);

    bytes32 positionId;

    function setUp() public {
        positionId = keccak256(abi.encodePacked(alice, "position-1", ORIGIN_CHAIN_ID));

        // 1. Deploy Origin contracts (Base Sepolia - 84532)
        vm.startPrank(owner);
        oracle = new TestValuationSource(owner);
        oracle.setAssetPrice(mockWeth, 3000e8); // $3,000 WETH
        oracle.setAssetPrice(mockUsdc, 1e8); // $1.00 USDC

        riskController = new RiskController(owner, RISK_THRESHOLD_BPS);
        vault = new CollateralVault(owner, address(oracle), address(riskController));
        riskController.setAuthorizedVault(address(vault), true);

        // 2. Deploy Reactive infrastructure (Lasna - 5318007)
        omniSys = new MockOmniSystemContract();

        // 3. Deploy Destination infrastructure (Unichain Sepolia - 1301)
        callbackProxy = new MockCallbackProxy();
        borrowingController = new BorrowingController(owner);

        // Compute predicted reactive contract address to simulate clean deployment sequencing
        address predictedReactiveAddress = vm.computeCreateAddress(owner, vm.getNonce(owner));

        // Deploy CrossGuardReactive on Lasna first
        crossGuardReactive = new CrossGuardReactive(
            owner,
            address(omniSys),
            ORIGIN_CHAIN_ID,
            address(riskController),
            DEST_CHAIN_ID,
            address(0), // Destination not yet deployed
            0
        );
        assertEq(address(crossGuardReactive), predictedReactiveAddress);

        // Deploy Destination CrossGuardCallback using the actual CrossGuardReactive address
        crossGuardCallback = new CrossGuardCallback(
            owner, address(callbackProxy), address(borrowingController), address(crossGuardReactive)
        );
        borrowingController.setCallbackAdapter(address(crossGuardCallback));

        // Link destination callback into CrossGuardReactive
        crossGuardReactive.setDestinationConfig(DEST_CHAIN_ID, address(crossGuardCallback), CALLBACK_GAS_LIMIT);
        vm.stopPrank();

        // 4. Register Alice's position on Unichain Sepolia
        vm.prank(alice);
        borrowingController.registerPosition(positionId);

        // 5. Initial collateral deposit and borrow on Base Sepolia (Healthy: 33.33% LTV)
        vm.startPrank(alice);
        vault.depositCollateral(positionId, mockWeth, 2e18); // $6,000 collateral
        vault.recordBorrow(positionId, mockUsdc, 2000e18); // $2,000 debt
        vm.stopPrank();
    }

    function testEndToEndOmniCrossChainRiskResponse() public {
        // Step 1: Alice borrows on destination chain (Unichain Sepolia) - Healthy
        vm.prank(alice);
        borrowingController.borrow(positionId, 500e18);
        assertFalse(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.positionBorrowDebt(positionId), 500e18);

        // Step 2: Unrelated user Bob cannot borrow against Alice's position
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedBorrower.selector, bob, alice));
        borrowingController.borrow(positionId, 100e18);

        // Step 3: Alice borrows safely while collateral is healthy ($4,000 debt on $6,000 collateral -> 66.66% LTV)
        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 2000e18);

        // Market shock: Collateral value drops on Base Sepolia ($3,000 -> $2,300)
        // Collateral: $4,600, Debt: $4,000 -> LTV: 86.95% (exceeds 80.00% threshold)
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2300e8);

        // Origin safety policy test: Alice cannot borrow any more debt once position is underwater
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.PositionUnsafeOrBreached.selector, positionId, 8913, 8000)
        );
        vault.recordBorrow(positionId, mockUsdc, 100e18);

        // Step 4: Evaluate position risk on Base Sepolia and capture RiskBreach log
        vm.recordLogs();
        (bool isBreached, uint256 ltvBps, uint256 nonce) = vault.evaluatePositionRisk(positionId);
        assertTrue(isBreached, "Position should be breached");
        assertEq(ltvBps, 8695, "LTV should be 8695 bps");
        assertEq(nonce, 1, "Nonce should be 1");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 riskBreachTopic0 = crossGuardReactive.RISK_BREACH_TOPIC_0();

        Vm.Log memory breachLog;
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(riskController) && entries[i].topics[0] == riskBreachTopic0) {
                breachLog = entries[i];
                found = true;
                break;
            }
        }
        assertTrue(found, "RiskBreach event must be emitted by RiskController");

        // Step 5: Deliver event from Omni System Contract to CrossGuardReactive on Lasna
        IReactive.LogRecord memory reactiveLog = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(breachLog.topics[0]),
            topic_1: uint256(breachLog.topics[1]),
            topic_2: uint256(breachLog.topics[2]),
            topic_3: uint256(breachLog.topics[3]),
            data: breachLog.data,
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        // Trigger react() via Omni System Contract
        vm.prank(address(omniSys));
        crossGuardReactive.react(reactiveLog);

        // Step 6: Verify Omni System Contract received exactly one callback request
        assertEq(omniSys.requestedCallbackCount(), 1, "Omni system contract must receive exactly 1 callback request");

        ISystemContract.CallbackConfiguration_V_1_0 memory cbReq = omniSys.getLastRequestedCallback();

        // Step 7: Verify complete callback destination, recipient, gas limit, and payload
        assertEq(cbReq.chainId, DEST_CHAIN_ID, "Callback target chain must be Unichain Sepolia (1301)");
        assertEq(cbReq.recipient, address(crossGuardCallback), "Recipient must be CrossGuardCallback");
        assertEq(cbReq.gasLimit, CALLBACK_GAS_LIMIT, "Gas limit must match configured 300,000");

        // Verify payload contents
        bytes memory payload = cbReq.payload;
        bytes4 selector;
        assembly {
            selector := mload(add(payload, 32))
        }
        assertEq(
            selector, ICrossGuardCallback.handleRiskBreach.selector, "Payload selector must match handleRiskBreach"
        );

        // Step 8: Execute destination callback via official Callback Proxy
        // Proxy injects the authenticated Reactive contract address (address(crossGuardReactive))
        (bool execSuccess,) =
            callbackProxy.executeCallback(cbReq.recipient, cbReq.payload, cbReq.gasLimit, address(crossGuardReactive));
        assertTrue(execSuccess, "Destination callback execution must succeed");

        // Step 9: Verify destination borrowing is paused and nonce is updated
        assertTrue(borrowingController.isBorrowingPaused(positionId), "Borrowing must be paused for position");
        assertEq(borrowingController.lastProcessedNonce(positionId), 1, "Processed nonce must equal 1");

        // Step 10: Alice can no longer borrow on Unichain
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.BorrowingIsPaused.selector, positionId));
        borrowingController.borrow(positionId, 100e18);

        // Step 11: Adversarial replay protection - Duplicate callback with nonce = 1 must revert
        (bool replaySuccess,) =
            callbackProxy.executeCallback(cbReq.recipient, cbReq.payload, cbReq.gasLimit, address(crossGuardReactive));
        assertFalse(replaySuccess, "Replaying duplicate nonce callback must fail");

        // Step 12: Adversarial sender authentication - Forged reactive sender must revert
        address forgedReactiveContract = address(0xDEADBEEF);
        (bool forgedSuccess,) =
            callbackProxy.executeCallback(cbReq.recipient, cbReq.payload, cbReq.gasLimit, forgedReactiveContract);
        assertFalse(forgedSuccess, "Forged reactive contract sender must fail authentication");

        // Step 13: Adversarial sender authentication - Legacy RVM ID assumption must revert
        address legacyRvmId = address(uint160(uint256(keccak256("legacy-rvm-id"))));
        (bool legacySuccess,) =
            callbackProxy.executeCallback(cbReq.recipient, cbReq.payload, cbReq.gasLimit, legacyRvmId);
        assertFalse(legacySuccess, "Legacy RVM ID assumption must fail when expecting deployed contract address");

        // Step 14: Verify stale breach protection on origin
        // Oracle rebounds back to $3,000/WETH
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 3000e8);

        // Alice cannot borrow on origin before explicit risk evaluation clears breach state
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionInBreachedState.selector, positionId));
        vault.recordBorrow(positionId, mockUsdc, 100e18);

        // Ordinary owner resume cannot bypass active risk breach on destination
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.CannotBypassActiveRiskBreach.selector, positionId));
        borrowingController.resumeBorrowing(positionId);

        // Step 15: Explicit origin healthy evaluation emits RiskResolved with monotonic nonce = 2
        vm.recordLogs();
        (bool recovered, uint256 recLtv, uint256 recNonce) = vault.evaluatePositionRisk(positionId);
        assertFalse(recovered, "Position must now be healthy");
        assertEq(recLtv, 6666, "LTV should be 6666 bps ($4,000 / $6,000)");
        assertEq(recNonce, 2, "Monotonic nonce must be 2");

        Vm.Log[] memory resolvedEntries = vm.getRecordedLogs();
        bytes32 riskResolvedTopic0 = crossGuardReactive.RISK_RESOLVED_TOPIC_0();
        Vm.Log memory resolvedLog;
        bool foundResolved = false;
        for (uint256 i = 0; i < resolvedEntries.length; i++) {
            if (
                resolvedEntries[i].emitter == address(riskController)
                    && resolvedEntries[i].topics[0] == riskResolvedTopic0
            ) {
                resolvedLog = resolvedEntries[i];
                foundResolved = true;
                break;
            }
        }
        assertTrue(foundResolved, "RiskResolved event must be emitted by RiskController");

        // Step 16: Reactive Lasna processes RiskResolved and dispatches resolution callback
        IReactive.LogRecord memory reactiveResolvedLog = IReactive.LogRecord({
            chain_id: 84532,
            _contract: address(riskController),
            topic_0: uint256(resolvedLog.topics[0]),
            topic_1: uint256(resolvedLog.topics[1]),
            topic_2: uint256(resolvedLog.topics[2]),
            topic_3: uint256(resolvedLog.topics[3]),
            data: resolvedLog.data,
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(omniSys));
        crossGuardReactive.react(reactiveResolvedLog);

        assertEq(omniSys.requestedCallbackCount(), 2, "Omni system contract must have 2 callback requests");
        ISystemContract.CallbackConfiguration_V_1_0 memory resCbReq = omniSys.getLastRequestedCallback();
        assertEq(resCbReq.recipient, address(crossGuardCallback));

        // Step 17: Destination Callback Proxy executes handleRiskResolved
        (bool resCallbackSuccess,) = callbackProxy.executeCallback(
            resCbReq.recipient, resCbReq.payload, resCbReq.gasLimit, address(crossGuardReactive)
        );
        assertTrue(resCallbackSuccess, "Destination resolution callback execution must succeed");

        // Step 18: Destination borrowing is resumed and nonce is updated to 2
        assertFalse(borrowingController.isBorrowingPaused(positionId), "Borrowing must be resumed");
        assertEq(borrowingController.lastProcessedNonce(positionId), 2, "Processed nonce must equal 2");

        // Step 19: Alice can borrow on Unichain again
        vm.prank(alice);
        borrowingController.borrow(positionId, 100e18);
        assertEq(borrowingController.positionBorrowDebt(positionId), 600e18);

        // Step 20: Alice can borrow on Base again
        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 100e18);
    }

    function testNoOmniCallbackWhenRiskIsWithinThreshold() public {
        // Collateral = $6,000, Debt = $2,000 -> LTV = 33.33% (Healthy)
        vm.recordLogs();
        (bool isBreached, uint256 ltvBps, uint256 nonce) = vault.evaluatePositionRisk(positionId);
        assertFalse(isBreached, "Position should be healthy");
        assertEq(ltvBps, 3333);
        assertEq(nonce, 0);

        // RiskBreach event is not emitted
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 riskBreachTopic0 = crossGuardReactive.RISK_BREACH_TOPIC_0();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(riskController)) {
                assertTrue(entries[i].topics[0] != riskBreachTopic0, "RiskBreach must not be emitted");
            }
        }

        // Omni system contract callback requests remain 0
        assertEq(omniSys.requestedCallbackCount(), 0, "No callback request should be registered");
        assertFalse(borrowingController.isBorrowingPaused(positionId));
    }

    function testEndToEndControlledCallbackRecoveryLifecycle() public {
        // 1. Position healthy on origin ($6,000 collateral, $2,000 debt -> 33.33% LTV)
        assertFalse(borrowingController.isBorrowingPaused(positionId));

        // 2. Alice borrows safely while collateral is healthy ($4,000 debt on $6,000 collateral -> 66.66% LTV)
        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 2000e18);

        // Market shock: Collateral value drops on Base Sepolia ($3,000 -> $2,300)
        // Collateral: $4,600, Debt: $4,000 -> LTV: 86.95% (exceeds 80.00% threshold)
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2300e8);

        // Evaluate risk on Base Sepolia
        vm.recordLogs();
        (bool isBreached,, uint256 breachNonce) = vault.evaluatePositionRisk(positionId);
        assertTrue(isBreached);
        assertEq(breachNonce, 1);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 breachTopic = crossGuardReactive.RISK_BREACH_TOPIC_0();
        Vm.Log memory breachLog;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(riskController) && entries[i].topics[0] == breachTopic) {
                breachLog = entries[i];
                break;
            }
        }

        // Deliver to Reactive Lasna
        IReactive.LogRecord memory reactiveLog = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(breachLog.topics[0]),
            topic_1: uint256(breachLog.topics[1]),
            topic_2: uint256(breachLog.topics[2]),
            topic_3: uint256(breachLog.topics[3]),
            data: breachLog.data,
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(omniSys));
        crossGuardReactive.react(reactiveLog);
        assertEq(omniSys.requestedCallbackCount(), 1);

        ISystemContract.CallbackConfiguration_V_1_0 memory cb1 = omniSys.getLastRequestedCallback();

        // 3. Simulated destination delivery failure: out-of-gas
        (bool execFail,) = callbackProxy.executeCallback(cb1.recipient, cb1.payload, 1000, address(crossGuardReactive));
        assertFalse(execFail, "Simulated callback execution should fail");

        // Destination remains unpaused, lastProcessedNonce remains 0
        assertFalse(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 0);

        // 4. Repeated evaluation on Base Sepolia does not increment nonce (Idempotency)
        (bool stillBreached,, uint256 repeatedNonce) = vault.evaluatePositionRisk(positionId);
        assertTrue(stillBreached);
        assertEq(repeatedNonce, 1);

        // 5. Controlled Recovery: Owner diagnoses issue and triggers retryFailedCallback
        bytes32 reason = bytes32("RECOVERY_GAS_EXHAUSTION");
        vm.prank(owner);
        crossGuardReactive.retryFailedCallback(positionId, 1, reason);
        assertEq(omniSys.requestedCallbackCount(), 2);

        ISystemContract.CallbackConfiguration_V_1_0 memory retryCb = omniSys.getLastRequestedCallback();
        assertEq(retryCb.payload, cb1.payload, "Retried payload must match exact original breach payload");

        // 6. Destination executes retried callback with sufficient gas
        (bool retrySuccess,) = callbackProxy.executeCallback(
            retryCb.recipient, retryCb.payload, retryCb.gasLimit, address(crossGuardReactive)
        );
        assertTrue(retrySuccess, "Destination retried callback must succeed");

        // Destination is now safely paused, nonce = 1
        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);

        // 7. Verify replay protection: replaying the retry callback reverts on destination
        (bool replaySuccess,) = callbackProxy.executeCallback(
            retryCb.recipient, retryCb.payload, retryCb.gasLimit, address(crossGuardReactive)
        );
        assertFalse(replaySuccess, "Replaying same-nonce callback must revert on destination");

        // 8. Recovery to Healthy on Base Sepolia: Alice deposits more collateral ($6,000 extra)
        vm.prank(alice);
        vault.depositCollateral(positionId, mockWeth, 3e18); // Total 5 WETH = $10,000 collateral, $3,500 debt -> 35% LTV

        vm.recordLogs();
        (bool recoveredBreached,, uint256 resNonce) = vault.evaluatePositionRisk(positionId);
        assertFalse(recoveredBreached);
        assertEq(resNonce, 2);

        Vm.Log[] memory resEntries = vm.getRecordedLogs();
        bytes32 resTopic = crossGuardReactive.RISK_RESOLVED_TOPIC_0();
        Vm.Log memory resLog;
        for (uint256 i = 0; i < resEntries.length; i++) {
            if (resEntries[i].emitter == address(riskController) && resEntries[i].topics[0] == resTopic) {
                resLog = resEntries[i];
                break;
            }
        }

        // Deliver resolution to Reactive Lasna
        IReactive.LogRecord memory reactiveResLog = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(resLog.topics[0]),
            topic_1: uint256(resLog.topics[1]),
            topic_2: uint256(resLog.topics[2]),
            topic_3: uint256(resLog.topics[3]),
            data: resLog.data,
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(omniSys));
        crossGuardReactive.react(reactiveResLog);
        assertEq(omniSys.requestedCallbackCount(), 3);

        ISystemContract.CallbackConfiguration_V_1_0 memory cbRes = omniSys.getLastRequestedCallback();

        // Destination executes resolution callback
        (bool resSuccess,) =
            callbackProxy.executeCallback(cbRes.recipient, cbRes.payload, cbRes.gasLimit, address(crossGuardReactive));
        assertTrue(resSuccess, "Resolution callback execution must succeed");

        // Destination is unpaused, nonce = 2
        assertFalse(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 2);
    }

    /// @notice M006.1 End-to-End Test: Valid breach accepted while destination unconfigured -> durable pending
    ///         storage -> configuration corrected -> dispatchPendingCallback() -> destination failure ->
    ///         retryFailedCallback() -> destination paused -> later collateral replenishment & resolution.
    function testEndToEndDeferredDispatchAndControlledRecovery() public {
        // Deploy a fresh Reactive contract in Stage 1 (unconfigured destination)
        vm.startPrank(owner);
        MockOmniSystemContract freshSys = new MockOmniSystemContract();
        address predictedReactive = vm.computeCreateAddress(owner, vm.getNonce(owner));
        CrossGuardReactive unconfReactive = new CrossGuardReactive(
            owner, address(freshSys), ORIGIN_CHAIN_ID, address(riskController), 0, address(0), 0
        );
        assertEq(address(unconfReactive), predictedReactive);

        // Fresh destination adapter pointing to the unconfigured reactive instance
        CrossGuardCallback deferredCb = new CrossGuardCallback(
            owner, address(callbackProxy), address(borrowingController), address(unconfReactive)
        );
        borrowingController.setCallbackAdapter(address(deferredCb));
        vm.stopPrank();

        // 1. Alice borrows additional $2,000 while healthy (total $4,000 debt on $6,000 collateral -> 66.66% LTV)
        // Then collateral drops to $2,300 -> $4,600 collateral, $4,000 debt -> 86.95% LTV >= 80% threshold
        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 2000e18);

        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2300e8);

        vm.recordLogs();
        vault.evaluatePositionRisk(positionId);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 breachTopic = unconfReactive.RISK_BREACH_TOPIC_0();
        Vm.Log memory breachLog;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(riskController) && entries[i].topics[0] == breachTopic) {
                breachLog = entries[i];
                break;
            }
        }

        // 2. Reactive intercepts log BEFORE destination is configured -> deferred durably as PENDING_DISPATCH
        vm.prank(address(freshSys));
        unconfReactive.react(
            IReactive.LogRecord({
                chain_id: ORIGIN_CHAIN_ID,
                _contract: address(riskController),
                topic_0: uint256(breachLog.topics[0]),
                topic_1: uint256(breachLog.topics[1]),
                topic_2: uint256(breachLog.topics[2]),
                topic_3: uint256(breachLog.topics[3]),
                data: breachLog.data,
                block_number: block.number,
                op_code: 0,
                block_hash: 0,
                tx_hash: 0,
                log_index: 0
            })
        );
        assertEq(freshSys.requestedCallbackCount(), 0, "Deferred breach must not request callback yet");
        assertEq(unconfReactive.latestOriginNonce(positionId), 1, "Accepted nonce must advance");
        (,,,, CrossGuardReactive.DispatchStatus stPending) = unconfReactive.getLatestCallback(positionId);
        assertEq(uint8(stPending), uint8(CrossGuardReactive.DispatchStatus.PENDING_DISPATCH));

        // 3. Owner corrects configuration and manually dispatches pending event (without burning retryCount)
        vm.startPrank(owner);
        unconfReactive.setDestinationConfig(DEST_CHAIN_ID, address(deferredCb), CALLBACK_GAS_LIMIT);
        unconfReactive.dispatchPendingCallback(positionId, 1);
        vm.stopPrank();

        assertEq(freshSys.requestedCallbackCount(), 1);
        (,,, uint8 retriesAfterDispatch, CrossGuardReactive.DispatchStatus stRequested) =
            unconfReactive.getLatestCallback(positionId);
        assertEq(retriesAfterDispatch, 0);
        assertEq(uint8(stRequested), uint8(CrossGuardReactive.DispatchStatus.REQUESTED));

        // 4. First dispatched callback fails on Unichain (out of gas), then owner retries with same nonce
        ISystemContract.CallbackConfiguration_V_1_0 memory cb1 = freshSys.getLastRequestedCallback();
        (bool failExec,) = callbackProxy.executeCallback(cb1.recipient, cb1.payload, 1000, address(unconfReactive));
        assertFalse(failExec);
        assertEq(borrowingController.lastProcessedNonce(positionId), 0);

        vm.prank(owner);
        unconfReactive.retryFailedCallback(positionId, 1, bytes32("RECOVERY_GAS_EXHAUSTION"));
        assertEq(freshSys.requestedCallbackCount(), 2);

        ISystemContract.CallbackConfiguration_V_1_0 memory retryCb = freshSys.getLastRequestedCallback();
        (bool okExec,) =
            callbackProxy.executeCallback(retryCb.recipient, retryCb.payload, retryCb.gasLimit, address(unconfReactive));
        assertTrue(okExec);
        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);
    }
}

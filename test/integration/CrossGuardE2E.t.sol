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
import {CrossGuardIdentity} from "../../src/libraries/CrossGuardIdentity.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

/// @title CrossGuardE2ETest
/// @notice End-to-end integration test suite verifying the Omni-native M007.1 CrossGuard pipeline:
///         Base Sepolia (84532) -> Reactive Lasna (5318007) -> Unichain Sepolia (1301).
contract CrossGuardE2ETest is Test {
    TestValuationSource oracle;
    RiskController riskController;
    CollateralVault vault;
    BorrowingController borrowingController;
    CrossGuardCallback crossGuardCallback;
    CrossGuardReactive crossGuardReactive;
    MockOmniSystemContract omniSys;
    MockCallbackProxy callbackProxy;

    uint256 constant ORIGIN_CHAIN_ID = 84532;
    uint256 constant DEST_CHAIN_ID = 1301;
    uint64 constant CALLBACK_GAS_LIMIT = 300_000;
    uint256 constant RISK_THRESHOLD_BPS = 8000;

    uint256 alicePk = 0xA11CE;
    address owner = address(0xAA);
    address alice;
    address bob = address(0xCC);
    address mockWeth = address(0x1111);
    address mockUsdc = address(0x2222);

    bytes32 constant SALT_1 = keccak256("e2e-salt-1");
    bytes32 positionId;

    function setUp() public {
        alice = vm.addr(alicePk);
        vm.chainId(ORIGIN_CHAIN_ID);

        vm.startPrank(owner);
        oracle = new TestValuationSource(owner);
        oracle.setAssetPrice(mockWeth, 3000e8);
        oracle.setAssetPrice(mockUsdc, 1e8);

        riskController = new RiskController(owner, RISK_THRESHOLD_BPS);
        vault = new CollateralVault(owner, address(oracle), address(riskController));
        riskController.setAuthorizedVault(address(vault), true);

        omniSys = new MockOmniSystemContract();
        callbackProxy = new MockCallbackProxy();
        borrowingController = new BorrowingController(owner, ORIGIN_CHAIN_ID, address(riskController), address(vault));

        address predictedReactiveAddress = vm.computeCreateAddress(owner, vm.getNonce(owner));

        crossGuardReactive = new CrossGuardReactive(
            owner,
            address(omniSys),
            ORIGIN_CHAIN_ID,
            address(riskController),
            address(vault),
            DEST_CHAIN_ID,
            address(0),
            0
        );
        assertEq(address(crossGuardReactive), predictedReactiveAddress);

        crossGuardCallback = new CrossGuardCallback(
            owner, address(callbackProxy), address(borrowingController), address(crossGuardReactive)
        );
        borrowingController.setCallbackAdapter(address(crossGuardCallback));

        crossGuardReactive.setDestinationConfig(DEST_CHAIN_ID, address(crossGuardCallback), CALLBACK_GAS_LIMIT);
        vm.stopPrank();

        // Register Alice's canonical same-wallet position on destination
        vm.prank(alice);
        bytes32 destPosId = borrowingController.registerPosition(SALT_1);

        // Open canonical position on origin and record safe initial borrow
        vm.startPrank(alice);
        positionId = vault.openPosition(SALT_1, mockWeth, 2e18);
        assertEq(positionId, destPosId);
        vault.recordBorrow(positionId, mockUsdc, 2000e18);
        vm.stopPrank();
    }

    function testEndToEndOmniCrossChainRiskResponse() public {
        vm.prank(alice);
        borrowingController.borrow(positionId, 500e18);
        assertFalse(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.positionBorrowDebt(positionId), 500e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedBorrower.selector, bob, alice));
        borrowingController.borrow(positionId, 100e18);

        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 2000e18);

        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2300e8);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.PositionUnsafeOrBreached.selector, positionId, 8913, 8000)
        );
        vault.recordBorrow(positionId, mockUsdc, 100e18);

        vm.recordLogs();
        (bool isBreached, uint256 ltvBps, uint256 nonce) = vault.evaluatePositionRisk(positionId);
        assertTrue(isBreached);
        assertEq(ltvBps, 8695);
        assertEq(nonce, 1);

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
        ISystemContract.CallbackConfiguration_V_1_0 memory cbReq = omniSys.getLastRequestedCallback();
        assertEq(cbReq.chainId, DEST_CHAIN_ID);
        assertEq(cbReq.recipient, address(crossGuardCallback));
        assertEq(cbReq.gasLimit, CALLBACK_GAS_LIMIT);

        bytes memory payload = cbReq.payload;
        bytes4 selector;
        assembly {
            selector := mload(add(payload, 32))
        }
        assertEq(selector, ICrossGuardCallback.handleRiskBreach.selector);

        (bool execSuccess,) =
            callbackProxy.executeCallback(cbReq.recipient, cbReq.payload, cbReq.gasLimit, address(crossGuardReactive));
        assertTrue(execSuccess);

        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.BorrowingIsPaused.selector, positionId));
        borrowingController.borrow(positionId, 100e18);

        (bool replaySuccess,) =
            callbackProxy.executeCallback(cbReq.recipient, cbReq.payload, cbReq.gasLimit, address(crossGuardReactive));
        assertFalse(replaySuccess);

        address forgedReactiveContract = address(0xDEADBEEF);
        (bool forgedSuccess,) =
            callbackProxy.executeCallback(cbReq.recipient, cbReq.payload, cbReq.gasLimit, forgedReactiveContract);
        assertFalse(forgedSuccess);

        address legacyRvmId = address(uint160(uint256(keccak256("legacy-rvm-id"))));
        (bool legacySuccess,) =
            callbackProxy.executeCallback(cbReq.recipient, cbReq.payload, cbReq.gasLimit, legacyRvmId);
        assertFalse(legacySuccess);

        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 3000e8);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionInBreachedState.selector, positionId));
        vault.recordBorrow(positionId, mockUsdc, 100e18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.CannotBypassActiveRiskBreach.selector, positionId));
        borrowingController.resumeBorrowing(positionId);

        vm.recordLogs();
        (bool recovered, uint256 recLtv, uint256 recNonce) = vault.evaluatePositionRisk(positionId);
        assertFalse(recovered);
        assertEq(recLtv, 6666);
        assertEq(recNonce, 2);

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
        assertTrue(foundResolved);

        IReactive.LogRecord memory reactiveResolvedLog = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
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

        assertEq(omniSys.requestedCallbackCount(), 2);
        ISystemContract.CallbackConfiguration_V_1_0 memory resCbReq = omniSys.getLastRequestedCallback();
        assertEq(resCbReq.recipient, address(crossGuardCallback));

        (bool resCallbackSuccess,) = callbackProxy.executeCallback(
            resCbReq.recipient, resCbReq.payload, resCbReq.gasLimit, address(crossGuardReactive)
        );
        assertTrue(resCallbackSuccess);

        assertFalse(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 2);

        vm.prank(alice);
        borrowingController.borrow(positionId, 100e18);
        assertEq(borrowingController.positionBorrowDebt(positionId), 600e18);

        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 100e18);
    }

    function testNoOmniCallbackWhenRiskIsWithinThreshold() public {
        vm.recordLogs();
        (bool isBreached, uint256 ltvBps, uint256 nonce) = vault.evaluatePositionRisk(positionId);
        assertFalse(isBreached);
        assertEq(ltvBps, 3333);
        assertEq(nonce, 0);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 riskBreachTopic0 = crossGuardReactive.RISK_BREACH_TOPIC_0();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(riskController)) {
                assertTrue(entries[i].topics[0] != riskBreachTopic0);
            }
        }

        assertEq(omniSys.requestedCallbackCount(), 0);
        assertFalse(borrowingController.isBorrowingPaused(positionId));
    }

    function testEndToEndControlledCallbackRecoveryLifecycle() public {
        assertFalse(borrowingController.isBorrowingPaused(positionId));

        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 2000e18);

        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2300e8);

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

        (bool execFail,) = callbackProxy.executeCallback(cb1.recipient, cb1.payload, 1000, address(crossGuardReactive));
        assertFalse(execFail);

        assertFalse(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 0);

        (bool stillBreached,, uint256 repeatedNonce) = vault.evaluatePositionRisk(positionId);
        assertTrue(stillBreached);
        assertEq(repeatedNonce, 1);

        bytes32 reason = bytes32("RECOVERY_GAS_EXHAUSTION");
        vm.prank(owner);
        crossGuardReactive.retryFailedCallback(positionId, 1, reason);
        assertEq(omniSys.requestedCallbackCount(), 2);

        ISystemContract.CallbackConfiguration_V_1_0 memory retryCb = omniSys.getLastRequestedCallback();
        assertEq(retryCb.payload, cb1.payload);

        (bool retrySuccess,) = callbackProxy.executeCallback(
            retryCb.recipient, retryCb.payload, retryCb.gasLimit, address(crossGuardReactive)
        );
        assertTrue(retrySuccess);

        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);

        (bool replaySuccess,) = callbackProxy.executeCallback(
            retryCb.recipient, retryCb.payload, retryCb.gasLimit, address(crossGuardReactive)
        );
        assertFalse(replaySuccess);

        vm.prank(alice);
        vault.depositCollateral(positionId, mockWeth, 3e18);

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

        (bool resSuccess,) =
            callbackProxy.executeCallback(cbRes.recipient, cbRes.payload, cbRes.gasLimit, address(crossGuardReactive));
        assertTrue(resSuccess);

        assertFalse(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 2);
    }

    function testEndToEndDeferredDispatchAndControlledRecovery() public {
        vm.startPrank(owner);
        MockOmniSystemContract freshSys = new MockOmniSystemContract();
        address predictedReactive = vm.computeCreateAddress(owner, vm.getNonce(owner));
        CrossGuardReactive unconfReactive = new CrossGuardReactive(
            owner, address(freshSys), ORIGIN_CHAIN_ID, address(riskController), address(vault), 0, address(0), 0
        );
        assertEq(address(unconfReactive), predictedReactive);

        CrossGuardCallback deferredCb = new CrossGuardCallback(
            owner, address(callbackProxy), address(borrowingController), address(unconfReactive)
        );
        borrowingController.setCallbackAdapter(address(deferredCb));
        vm.stopPrank();

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
        assertEq(freshSys.requestedCallbackCount(), 0);
        assertEq(unconfReactive.latestOriginNonce(positionId), 1);
        (,,,, CrossGuardReactive.DispatchStatus stPending) = unconfReactive.getLatestCallback(positionId);
        assertEq(uint8(stPending), uint8(CrossGuardReactive.DispatchStatus.PENDING_DISPATCH));

        vm.startPrank(owner);
        unconfReactive.setDestinationConfig(DEST_CHAIN_ID, address(deferredCb), CALLBACK_GAS_LIMIT);
        unconfReactive.dispatchPendingCallback(positionId, 1);
        vm.stopPrank();

        assertEq(freshSys.requestedCallbackCount(), 1);
        (,,, uint8 retriesAfterDispatch, CrossGuardReactive.DispatchStatus stRequested) =
            unconfReactive.getLatestCallback(positionId);
        assertEq(retriesAfterDispatch, 0);
        assertEq(uint8(stRequested), uint8(CrossGuardReactive.DispatchStatus.REQUESTED));

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

    function testEndToEndCrossWalletDelegatedOwnershipAndCallbackPreservation() public {
        address aliceDest = address(0xD357);
        address relayer = address(0x9999);
        bytes32 delegatedSalt = keccak256("e2e-delegated-salt");

        vm.startPrank(alice);
        bytes32 delPosId = vault.openPosition(delegatedSalt, mockWeth, 2e18);
        vault.recordBorrow(delPosId, mockUsdc, 4500e18);
        vm.stopPrank();

        // Simulate Unichain destination signing + relayer registration of aliceDest
        vm.chainId(DEST_CHAIN_ID);
        CrossGuardIdentity.OriginIdentity memory id = vault.getPositionIdentity(delPosId);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = borrowingController.computeAuthorizePositionDigest(id, aliceDest, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.prank(relayer);
        bytes32 registeredPos =
            borrowingController.registerPositionWithAuthorization(id, aliceDest, deadline, abi.encodePacked(r, s, v));
        assertEq(registeredPos, delPosId);
        assertEq(borrowingController.positionOwners(delPosId), aliceDest);

        // Delegated destination wallet borrows safely; origin wallet Alice cannot borrow as another dest wallet
        vm.prank(aliceDest);
        borrowingController.borrow(delPosId, 300e18);

        // Price crash triggers breach back on Base Sepolia (84532)
        vm.chainId(ORIGIN_CHAIN_ID);
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2000e8);

        vm.recordLogs();
        vault.evaluatePositionRisk(delPosId);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 breachTopic = crossGuardReactive.RISK_BREACH_TOPIC_0();
        Vm.Log memory bLog;
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == address(riskController) && entries[i].topics[0] == breachTopic
                    && entries[i].topics[1] == delPosId
            ) {
                bLog = entries[i];
                break;
            }
        }

        vm.prank(address(omniSys));
        crossGuardReactive.react(
            IReactive.LogRecord({
                chain_id: ORIGIN_CHAIN_ID,
                _contract: address(riskController),
                topic_0: uint256(bLog.topics[0]),
                topic_1: uint256(bLog.topics[1]),
                topic_2: uint256(bLog.topics[2]),
                topic_3: uint256(bLog.topics[3]),
                data: bLog.data,
                block_number: block.number,
                op_code: 0,
                block_hash: 0,
                tx_hash: 0,
                log_index: 0
            })
        );

        ISystemContract.CallbackConfiguration_V_1_0 memory cb = omniSys.getLastRequestedCallback();
        (bool pausedOk,) =
            callbackProxy.executeCallback(cb.recipient, cb.payload, cb.gasLimit, address(crossGuardReactive));
        assertTrue(pausedOk);

        // Callback paused position AND strictly preserved delegated owner aliceDest (did NOT overwrite with alice!)
        assertTrue(borrowingController.isBorrowingPaused(delPosId));
        assertEq(borrowingController.positionOwners(delPosId), aliceDest);
        assertEq(borrowingController.originUsers(delPosId), alice);
    }
}

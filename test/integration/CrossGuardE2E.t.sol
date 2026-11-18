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
            CALLBACK_GAS_LIMIT,
            RISK_THRESHOLD_BPS
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

        // Step 3: Collateral value drops on Base Sepolia ($3,000 -> $2,300)
        // Alice borrows another $2,000 USDC on Base -> Collateral: $4,600, Debt: $4,000 -> LTV: 86.95% (breach)
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2300e8);

        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 2000e18);

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

        // Step 14: Emergency recovery by authorized owner
        vm.prank(owner);
        borrowingController.resumeBorrowing(positionId);
        assertFalse(borrowingController.isBorrowingPaused(positionId), "Borrowing should be resumed");

        // Alice can borrow again
        vm.prank(alice);
        borrowingController.borrow(positionId, 100e18);
        assertEq(borrowingController.positionBorrowDebt(positionId), 600e18);
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
}

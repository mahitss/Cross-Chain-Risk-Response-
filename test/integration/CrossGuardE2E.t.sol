// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {ReactiveTest} from "reactive-test-lib/base/ReactiveTest.sol";
import {CallbackResult} from "reactive-test-lib/interfaces/IReactiveInterfaces.sol";

import {TestValuationSource} from "../../src/origin/TestValuationSource.sol";
import {RiskController} from "../../src/origin/RiskController.sol";
import {CollateralVault} from "../../src/origin/CollateralVault.sol";
import {BorrowingController} from "../../src/destination/BorrowingController.sol";
import {CrossGuardCallback} from "../../src/destination/CrossGuardCallback.sol";
import {CrossGuardReactive} from "../../src/reactive/CrossGuardReactive.sol";
import {MockOmniSystemContract} from "../mocks/MockOmniSystemContract.sol";

/// @title CrossGuardE2ETest
/// @notice Complete end-to-end multi-chain simulation of CrossGuard using ReactiveTest.
///         Verifies Base Sepolia (84532) -> Reactive Lasna (5318007) -> Unichain Sepolia (1301)
///         with Omni system interface, replay protection nonces, and position ownership validation.
contract CrossGuardE2ETest is ReactiveTest {
    // Contracts
    TestValuationSource oracle;
    RiskController riskController;
    CollateralVault vault;
    BorrowingController borrowingController;
    CrossGuardCallback crossGuardCallback;
    CrossGuardReactive crossGuardReactive;
    MockOmniSystemContract omniSys;

    // Chain IDs
    uint256 constant ORIGIN_CHAIN_ID = 84532; // Base Sepolia
    uint256 constant DEST_CHAIN_ID = 1301; // Unichain Sepolia

    // Actors & Assets
    address owner = address(0xAA);
    address alice = address(0xBB);
    address bob = address(0xCC);
    address mockWeth = address(0x1111);
    address mockUsdc = address(0x2222);

    bytes32 positionId;

    function setUp() public override {
        super.setUp();

        positionId = keccak256(abi.encodePacked(alice, "position-1", ORIGIN_CHAIN_ID));

        // 1. Deploy Origin contracts (Base Sepolia - 84532)
        vm.startPrank(owner);
        oracle = new TestValuationSource(owner);
        oracle.setAssetPrice(mockWeth, 3000e8); // $3,000 WETH
        oracle.setAssetPrice(mockUsdc, 1e8); // $1.00 USDC

        riskController = new RiskController(owner, 8000); // 80% LTV threshold
        vault = new CollateralVault(owner, address(oracle), address(riskController));
        riskController.setAuthorizedVault(address(vault), true);

        // 2. Deploy Destination contracts (Unichain Sepolia - 1301)
        borrowingController = new BorrowingController(owner);
        crossGuardCallback = new CrossGuardCallback(
            owner,
            address(proxy),
            address(borrowingController),
            rvmId // Deployer / RVM ID injected by MockCallbackProxy
        );
        borrowingController.setCallbackAdapter(address(crossGuardCallback));

        // 3. Deploy Omni System Contract Mock & etch to sys address for simulator
        omniSys = new MockOmniSystemContract();
        vm.etch(address(sys), address(omniSys).code);

        // Deploy CrossGuardReactive pointing to system contract
        crossGuardReactive = new CrossGuardReactive(
            owner,
            address(sys),
            ORIGIN_CHAIN_ID,
            address(riskController),
            DEST_CHAIN_ID,
            address(crossGuardCallback),
            300_000,
            8000 // 80% threshold filter
        );
        vm.stopPrank();

        // 4. Position registration on destination chain (Alice is trusted owner)
        vm.prank(alice);
        borrowingController.registerPosition(positionId);

        // 5. Initial collateral deposit and borrow on Base Sepolia
        vm.startPrank(alice);
        vault.depositCollateral(positionId, mockWeth, 2e18); // $6,000 collateral
        vault.recordBorrow(positionId, mockUsdc, 2000e18); // $2,000 debt -> LTV = 33.33%
        vm.stopPrank();
    }

    function testEndToEndCrossChainRiskResponseWithNonce() public {
        // Step 1: Initial borrowing on destination chain is healthy and allowed for owner
        vm.prank(alice);
        borrowingController.borrow(positionId, 500e18);
        assertFalse(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.positionBorrowDebt(positionId), 500e18);

        // Step 2: Unrelated user Bob cannot borrow against Alice's position
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnauthorizedBorrower.selector, bob, alice));
        borrowingController.borrow(positionId, 100e18);

        // Step 3: Collateral price drops on Base Sepolia from $3,000 to $2,300
        // New collateral value = 2 * $2300 = $4,600
        // Alice borrows another $2,000 USDC on Base -> Total debt = $4,000
        // New LTV = 4000 / 4600 = 86.95% (8695 bps) >= 8000 bps -> Threshold breached!
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2300e8);

        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 2000e18);

        // Step 4: Trigger position evaluation on Base Sepolia and execute full reactive simulation
        // triggerAndReact runs:
        //  - vault.evaluatePositionRisk(positionId) -> emits RiskBreach with nonce = 1
        //  - sys matches subscription -> invokes CrossGuardReactive.react()
        //  - CrossGuardReactive emits Callback to Unichain Sepolia with nonce = 1
        //  - MockCallbackProxy executes handleRiskBreach on CrossGuardCallback with injected rvmId
        //  - CrossGuardCallback invokes BorrowingController.pauseBorrowing(positionId, nonce=1, ...)
        CallbackResult[] memory results = triggerAndReact(
            address(vault), abi.encodeWithSelector(vault.evaluatePositionRisk.selector, positionId), ORIGIN_CHAIN_ID
        );

        // Step 5: Verify callback execution results
        assertCallbackCount(results, 1);
        assertCallbackSuccess(results, 0);
        assertCallbackEmitted(results, address(crossGuardCallback));

        // Step 6: Verify destination state is paused and nonce recorded
        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);

        // Step 7: Verify subsequent borrowing attempt on Unichain Sepolia is blocked
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.BorrowingIsPaused.selector, positionId));
        borrowingController.borrow(positionId, 100e18);

        // Step 8: Test replay protection - re-executing same callback with nonce = 1 via proxy fails
        bytes memory duplicatePayload = abi.encodeWithSignature(
            "handleRiskBreach(address,bytes32,uint256,uint256,uint256)",
            address(0),
            positionId,
            1, // Duplicate nonce!
            8695,
            block.timestamp
        );
        (bool success,) = proxy.executeCallback(address(crossGuardCallback), duplicatePayload, 300_000, rvmId);
        assertFalse(success); // Reverts with InvalidNonce

        // Step 9: Emergency / Administrative recovery
        // Owner unpauses position after collateral is restored or debt is remediated
        vm.prank(owner);
        borrowingController.resumeBorrowing(positionId);
        assertFalse(borrowingController.isBorrowingPaused(positionId));

        // Step 10: Borrowing works again
        vm.prank(alice);
        borrowingController.borrow(positionId, 100e18);
        assertEq(borrowingController.positionBorrowDebt(positionId), 600e18);
    }

    function testNoCallbackWhenRiskIsWithinThreshold() public {
        // Collateral = $6,000, Debt = $2,000 -> LTV = 33.33% (Healthy)
        CallbackResult[] memory results = triggerAndReact(
            address(vault), abi.encodeWithSelector(vault.evaluatePositionRisk.selector, positionId), ORIGIN_CHAIN_ID
        );

        // No breach occurred -> 0 callbacks fired
        assertCallbackCount(results, 0);
        assertFalse(borrowingController.isBorrowingPaused(positionId));
    }
}

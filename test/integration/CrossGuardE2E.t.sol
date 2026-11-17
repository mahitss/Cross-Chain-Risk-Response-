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

/// @title CrossGuardE2ETest
/// @notice Complete end-to-end multi-chain simulation of CrossGuard using ReactiveTest.
///         Verifies Base Sepolia (84532) -> Reactive Lasna (5318007) -> Unichain Sepolia (1301).
contract CrossGuardE2ETest is ReactiveTest {
    // Contracts
    TestValuationSource oracle;
    RiskController riskController;
    CollateralVault vault;
    BorrowingController borrowingController;
    CrossGuardCallback crossGuardCallback;
    CrossGuardReactive crossGuardReactive;

    // Chain IDs
    uint256 constant ORIGIN_CHAIN_ID = 84532;   // Base Sepolia
    uint256 constant DEST_CHAIN_ID = 1301;     // Unichain Sepolia

    // Actors & Assets
    address owner = address(0xAA);
    address alice = address(0xBB);
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
        oracle.setAssetPrice(mockUsdc, 1e8);    // $1.00 USDC

        riskController = new RiskController(owner, 8000); // 80% LTV threshold
        vault = new CollateralVault(owner, address(oracle), address(riskController));
        riskController.setAuthorizedVault(address(vault), true);

        // 2. Deploy Destination contracts (Unichain Sepolia - 1301)
        borrowingController = new BorrowingController(owner);
        crossGuardCallback = new CrossGuardCallback(
            owner,
            address(proxy),
            address(borrowingController),
            rvmId // Deployer / RVM ID set by ReactiveTest
        );
        borrowingController.setCallbackAdapter(address(crossGuardCallback));

        // 3. Deploy Reactive Contract (Reactive Lasna)
        // Subscribes via MockSystemContract (`sys`) to RiskController events
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

        // 4. Initial state: Alice deposits 2 WETH ($6,000) and borrows 2,000 USDC ($2,000)
        vm.startPrank(alice);
        vault.depositCollateral(positionId, mockWeth, 2e18);
        vault.recordBorrow(positionId, mockUsdc, 2000e18);
        vm.stopPrank();
    }

    function testEndToEndCrossChainRiskResponse() public {
        // Step 1: Verify initial borrowing on destination chain is healthy and allowed
        vm.prank(alice);
        borrowingController.borrow(positionId, 500e18);
        assertFalse(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.positionBorrowDebt(positionId), 500e18);

        // Step 2: Collateral price drops on Base Sepolia from $3,000 to $2,300
        // New collateral value = 2 * $2300 = $4,600
        // Alice borrows another $2,000 USDC -> Total debt = $4,000
        // New LTV = 4000 / 4600 = 86.95% (8695 bps) >= 8000 bps -> Threshold breached!
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2300e8);

        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 2000e18);

        // Step 3: Trigger position evaluation on Base Sepolia and execute full reactive simulation
        // triggerAndReact runs:
        //  - vault.evaluatePositionRisk(positionId) -> emits RiskBreach on Base Sepolia (84532)
        //  - sys matches subscription -> invokes CrossGuardReactive.react()
        //  - CrossGuardReactive emits Callback to Unichain Sepolia (1301)
        //  - MockCallbackProxy executes handleRiskBreach on CrossGuardCallback with injected rvmId
        //  - CrossGuardCallback invokes BorrowingController.pauseBorrowing()
        CallbackResult[] memory results = triggerAndReact(
            address(vault),
            abi.encodeWithSelector(vault.evaluatePositionRisk.selector, positionId),
            ORIGIN_CHAIN_ID
        );

        // Step 4: Verify callback execution results
        assertCallbackCount(results, 1);
        assertCallbackSuccess(results, 0);
        assertCallbackEmitted(results, address(crossGuardCallback));

        // Step 5: Verify destination state is now paused
        assertTrue(borrowingController.isBorrowingPaused(positionId));

        // Step 6: Verify subsequent borrowing attempt on Unichain Sepolia is blocked
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.BorrowingIsPaused.selector, positionId));
        borrowingController.borrow(positionId, 100e18);

        // Step 7: Emergency / Administrative recovery
        // Owner unpauses position after collateral is restored or debt is remediated
        vm.prank(owner);
        borrowingController.resumeBorrowing(positionId);
        assertFalse(borrowingController.isBorrowingPaused(positionId));

        // Step 8: Borrowing works again
        vm.prank(alice);
        borrowingController.borrow(positionId, 100e18);
        assertEq(borrowingController.positionBorrowDebt(positionId), 600e18);
    }

    function testNoCallbackWhenRiskIsWithinThreshold() public {
        // Collateral = $6,000, Debt = $2,000 -> LTV = 33.33% (Healthy)
        CallbackResult[] memory results = triggerAndReact(
            address(vault),
            abi.encodeWithSelector(vault.evaluatePositionRisk.selector, positionId),
            ORIGIN_CHAIN_ID
        );

        // No breach occurred -> 0 callbacks fired
        assertCallbackCount(results, 0);
        assertFalse(borrowingController.isBorrowingPaused(positionId));
    }
}

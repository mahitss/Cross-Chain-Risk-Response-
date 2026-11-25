// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {CollateralVault} from "../../src/origin/CollateralVault.sol";
import {RiskController} from "../../src/origin/RiskController.sol";
import {TestValuationSource} from "../../src/origin/TestValuationSource.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CollateralVaultTest is Test {
    CollateralVault vault;
    RiskController riskController;
    TestValuationSource oracle;

    address owner = address(0xAA);
    address alice = address(0xBB);
    address bob = address(0xCC);
    address stranger = address(0xDD);

    address mockWeth = address(0x1111);
    address mockWbtc = address(0x3333);
    address mockUsdc = address(0x2222);
    address mockDai = address(0x4444);

    bytes32 positionId = keccak256("alice-position");

    event ValuationSourceUpdated(address indexed oldOracle, address indexed newOracle);

    function setUp() public {
        vm.startPrank(owner);
        oracle = new TestValuationSource(owner);
        riskController = new RiskController(owner, 8000); // 80% threshold

        vault = new CollateralVault(owner, address(oracle), address(riskController));
        riskController.setAuthorizedVault(address(vault), true);

        // Prices: WETH = $3,000, USDC = $1, WBTC = $60,000, DAI = $1
        oracle.setAssetPrice(mockWeth, 3000e8);
        oracle.setAssetPrice(mockUsdc, 1e8);
        oracle.setAssetPrice(mockWbtc, 60000e8);
        oracle.setAssetPrice(mockDai, 1e8);
        vm.stopPrank();
    }

    function testDepositCollateralAndBorrow() public {
        vm.startPrank(alice);
        // Deposit 2 WETH ($6,000)
        vault.depositCollateral(positionId, mockWeth, 2e18);

        // Borrow 2,000 USDC ($2,000)
        vault.recordBorrow(positionId, mockUsdc, 2000e18);
        vm.stopPrank();

        (address user, address colAsset, uint256 colAmount, address debtAsset, uint256 debtAmount) =
            vault.getPosition(positionId);

        assertEq(user, alice);
        assertEq(colAsset, mockWeth);
        assertEq(colAmount, 2e18);
        assertEq(debtAsset, mockUsdc);
        assertEq(debtAmount, 2000e18);
        assertEq(vault.positionCollateralAsset(positionId), mockWeth);
        assertEq(vault.positionDebtAsset(positionId), mockUsdc);
    }

    function testRevertWhenMixedCollateralAsset() public {
        vm.startPrank(alice);
        // Initial deposit in WETH
        vault.depositCollateral(positionId, mockWeth, 2e18);

        // Attempting to deposit WBTC into WETH position must revert
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AssetMismatch.selector, mockWbtc, mockWeth));
        vault.depositCollateral(positionId, mockWbtc, 1e18);
        vm.stopPrank();
    }

    function testRevertWhenMixedDebtAsset() public {
        vm.startPrank(alice);
        vault.depositCollateral(positionId, mockWeth, 2e18);
        // Initial borrow in USDC
        vault.recordBorrow(positionId, mockUsdc, 1000e18);

        // Attempting to record borrow in DAI against USDC position must revert
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AssetMismatch.selector, mockDai, mockUsdc));
        vault.recordBorrow(positionId, mockDai, 500e18);
        vm.stopPrank();
    }

    function testEvaluatePositionHealthy() public {
        vm.startPrank(alice);
        vault.depositCollateral(positionId, mockWeth, 2e18); // $6,000
        vault.recordBorrow(positionId, mockUsdc, 2000e18); // $2,000 -> LTV = 33.33% (3333 bps)
        vm.stopPrank();

        (bool isBreached, uint256 ltvBps, uint256 nonce) = vault.evaluatePositionRisk(positionId);
        assertFalse(isBreached);
        assertEq(ltvBps, 3333);
        assertEq(nonce, 0);
    }

    function testEvaluatePositionBreachedAfterPriceDrop() public {
        vm.startPrank(alice);
        vault.depositCollateral(positionId, mockWeth, 2e18); // $6,000
        vault.recordBorrow(positionId, mockUsdc, 4500e18); // $4,500 -> LTV = 7500 bps (Healthy)
        vm.stopPrank();

        (bool breachedBefore,,) = vault.evaluatePositionRisk(positionId);
        assertFalse(breachedBefore);

        // Flash crash: WETH drops to $2,500
        // New Collateral value: 2 * $2500 = $5,000. Debt = $4,500.
        // New LTV: 4500 / 5000 = 90% (9000 bps) >= 80% (8000 bps) -> BREACH!
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2500e8);

        (bool isBreached, uint256 ltvBps, uint256 nonce) = vault.evaluatePositionRisk(positionId);
        assertTrue(isBreached);
        assertEq(ltvBps, 9000);
        assertEq(nonce, 1);
    }

    function testRevertWhenUnauthorizedUserModifiesPosition() public {
        vm.prank(alice);
        vault.depositCollateral(positionId, mockWeth, 1e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.UnauthorizedUser.selector, bob, alice));
        vault.depositCollateral(positionId, mockWeth, 1e18);
    }

    function testRevertWhenBorrowingOnUninitializedPosition() public {
        bytes32 uninitPos = keccak256("uninit");
        vm.prank(alice);
        vm.expectRevert(CollateralVault.PositionNotInitialized.selector);
        vault.recordBorrow(uninitPos, mockUsdc, 100e18);
    }

    function testRevertWhenEvaluatingUninitializedPosition() public {
        bytes32 uninitPos = keccak256("uninit");
        vm.expectRevert(CollateralVault.PositionNotInitialized.selector);
        vault.evaluatePositionRisk(uninitPos);
    }

    function testZeroAmountAndZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAmount.selector);
        vault.depositCollateral(positionId, mockWeth, 0);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        vault.depositCollateral(positionId, address(0), 1e18);

        vm.prank(alice);
        vault.depositCollateral(positionId, mockWeth, 1e18);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAmount.selector);
        vault.recordBorrow(positionId, mockUsdc, 0);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        vault.recordBorrow(positionId, address(0), 100e18);
    }

    function testSettersAndAdminControl() public {
        address newOracle = address(0x777);
        address oldOracle = address(vault.valuationSource());

        // RiskController is immutable to guarantee breach state continuity
        assertEq(address(vault.riskController()), address(riskController));

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit ValuationSourceUpdated(oldOracle, newOracle);
        vault.setValuationSource(newOracle);
        assertEq(address(vault.valuationSource()), newOracle);

        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        vault.setValuationSource(address(0));
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setValuationSource(newOracle);
    }

    function testRiskControllerImmutabilityPreservesBreachContinuity() public {
        // 1. Establish position and deposit collateral
        vm.startPrank(alice);
        vault.depositCollateral(positionId, mockWeth, 2e18); // $6,000 collateral
        vault.recordBorrow(positionId, mockUsdc, 4000e18); // $4,000 debt (66.66% LTV)
        vm.stopPrank();

        // 2. Market shock causes breach (WETH drops from $3,000 to $2,000 -> $4,000 collateral, $4,000 debt = 100% LTV)
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2000e8);

        (bool isBreached,,) = vault.evaluatePositionRisk(positionId);
        assertTrue(isBreached, "Position must be breached");
        assertTrue(riskController.isPositionBreached(positionId), "Breach recorded in risk controller");

        // 3. Immutability guarantee: risk controller reference cannot be manipulated or swapped
        assertEq(address(vault.riskController()), address(riskController));

        // 4. Further borrowing is strictly rejected while breach is active
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionInBreachedState.selector, positionId));
        vault.recordBorrow(positionId, mockUsdc, 100e18);

        // 5. Oracle price recovers (WETH goes to $4,000 -> $8,000 collateral, $4,000 debt = 50% LTV)
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 4000e8);

        // 6. Stale breach protection: borrow still rejected until explicit evaluation
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionInBreachedState.selector, positionId));
        vault.recordBorrow(positionId, mockUsdc, 100e18);

        // 7. Explicit evaluation clears breach in the immutable controller
        (bool recoveredBreached, uint256 newLtv,) = vault.evaluatePositionRisk(positionId);
        assertFalse(recoveredBreached, "Breach cleared after explicit evaluation");
        assertEq(newLtv, 5000);
        assertFalse(riskController.isPositionBreached(positionId), "Breach cleared in controller");

        // 8. Borrowing is now successfully permitted
        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 500e18);
        (,,, address debtAsset, uint256 debtAmount) = vault.getPosition(positionId);
        assertEq(debtAsset, mockUsdc);
        assertEq(debtAmount, 4500e18);
    }

    function testConstructorZeroAddressRevert() public {
        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        new CollateralVault(owner, address(0), address(riskController));

        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        new CollateralVault(owner, address(oracle), address(0));
    }

    /* -------------------------------------------------------------------------- */
    /*               M003.1 ORIGIN BORROWING SAFETY & RECOVERY TESTS             */
    /* -------------------------------------------------------------------------- */

    function testRevertBorrowWhenZeroCollateral() public {
        vm.prank(alice);
        vault.depositCollateral(positionId, mockWeth, 1e18);

        // Zero out collateralAmount in storage (_positions mapping at slot 2 since riskController is immutable)
        bytes32 colAmountSlot = bytes32(uint256(keccak256(abi.encode(positionId, uint256(2)))) + 2);
        vm.store(address(vault), colAmountSlot, bytes32(0));

        (,, uint256 colAmount,,) = vault.getPosition(positionId);
        assertEq(colAmount, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionUncollateralized.selector, positionId));
        vault.recordBorrow(positionId, mockUsdc, 100e18);
    }

    function testRevertBorrowWhenExceedingRiskThreshold() public {
        vm.startPrank(alice);
        // Deposit 2 WETH ($6,000)
        vault.depositCollateral(positionId, mockWeth, 2e18);

        // At 80% threshold, max safe borrow is strictly < $4,800
        // Attempting to borrow $4,800 USDC (80.00% LTV) must revert with PositionUnsafeOrBreached
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.PositionUnsafeOrBreached.selector, positionId, 8000, 8000)
        );
        vault.recordBorrow(positionId, mockUsdc, 4800e18);

        // Attempting to borrow $5,000 USDC (83.33% LTV) must revert
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.PositionUnsafeOrBreached.selector, positionId, 8333, 8000)
        );
        vault.recordBorrow(positionId, mockUsdc, 5000e18);

        // Safe borrow of $4,000 USDC (66.66% LTV) succeeds
        vault.recordBorrow(positionId, mockUsdc, 4000e18);
        vm.stopPrank();

        (,,,, uint256 debt) = vault.getPosition(positionId);
        assertEq(debt, 4000e18);
    }

    function testRevertBorrowWhenPositionAlreadyBreached() public {
        vm.startPrank(alice);
        // Deposit 2 WETH ($6,000) and borrow $4,500 USDC (75% LTV, healthy)
        vault.depositCollateral(positionId, mockWeth, 2e18);
        vault.recordBorrow(positionId, mockUsdc, 4500e18);
        vm.stopPrank();

        // Collateral crashes to $2,000/WETH -> Collateral: $4,000, Debt: $4,500 -> LTV: 112.5% (Breached!)
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2000e8);

        // Any attempt to borrow more debt must revert
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.PositionUnsafeOrBreached.selector, positionId, 11500, 8000)
        );
        vault.recordBorrow(positionId, mockUsdc, 100e18);
    }

    function testRecoveryLifecycleOnOrigin() public {
        vm.startPrank(alice);
        vault.depositCollateral(positionId, mockWeth, 2e18); // $6,000
        vault.recordBorrow(positionId, mockUsdc, 4500e18); // $4,500 (LTV = 75%)
        vm.stopPrank();

        // Step 1: Market shock -> WETH drops to $2,500 ($5,000 col, $4,500 debt -> 90% LTV)
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2500e8);

        (bool isBreached, uint256 ltv, uint256 nonce) = vault.evaluatePositionRisk(positionId);
        assertTrue(isBreached);
        assertEq(ltv, 9000);
        assertEq(nonce, 1);

        // Step 2: Alice remedies position by depositing 2 more WETH ($5,000 more collateral)
        // Total collateral = 4 WETH @ $2,500 = $10,000. Debt = $4,500.
        // New LTV = 4,500 / 10,000 = 45% (4500 bps) < 80% (Healthy!)
        vm.prank(alice);
        vault.depositCollateral(positionId, mockWeth, 2e18);

        (bool recovered, uint256 recLtv, uint256 recNonce) = vault.evaluatePositionRisk(positionId);
        assertFalse(recovered, "Position must now be recovered");
        assertEq(recLtv, 4500);
        assertEq(recNonce, 2, "Recovery must increment monotonic nonce");

        // Step 3: Now Alice can safely borrow again
        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 1000e18); // total debt $5,500 -> 55% LTV
        (,,,, uint256 newDebt) = vault.getPosition(positionId);
        assertEq(newDebt, 5500e18);
    }

    /* -------------------------------------------------------------------------- */
    /*               M003.2 STALE BREACH & FULL-PRECISION ARITHMETIC TESTS       */
    /* -------------------------------------------------------------------------- */

    function testStaleBreachStateBorrowRejectionUntilExplicitEvaluation() public {
        vm.startPrank(alice);
        vault.depositCollateral(positionId, mockWeth, 2e18); // $6,000
        vault.recordBorrow(positionId, mockUsdc, 4500e18); // $4,500 (LTV = 75%)
        vm.stopPrank();

        // 1. Position breaches: WETH drops to $2,500 (Collateral $5,000, Debt $4,500 -> LTV = 90%)
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2500e8);

        (bool isBreached,,) = vault.evaluatePositionRisk(positionId);
        assertTrue(isBreached);
        assertTrue(riskController.isPositionBreached(positionId));

        // 2. Oracle recovers: WETH price rebounds to $3,000 (Collateral becomes $6,000 -> LTV would be 75%)
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 3000e8);

        // 3. Stale breach protection: Alice attempts to borrow BEFORE explicit evaluation
        // MUST REVERT with PositionInBreachedState even though current pricing would be healthy!
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionInBreachedState.selector, positionId));
        vault.recordBorrow(positionId, mockUsdc, 100e18);

        // Breach state remains active in RiskController
        assertTrue(riskController.isPositionBreached(positionId));

        // 4. Explicit healthy risk evaluation is performed
        (bool recovered, uint256 recLtv, uint256 recNonce) = vault.evaluatePositionRisk(positionId);
        assertFalse(recovered);
        assertEq(recLtv, 7500);
        assertEq(recNonce, 2);
        assertFalse(riskController.isPositionBreached(positionId));

        // 5. Outcome based on projected LTV:
        // A) Borrow that pushes position beyond 80% threshold fails
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.PositionUnsafeOrBreached.selector, positionId, 8333, 8000)
        );
        vault.recordBorrow(positionId, mockUsdc, 500e18); // $4,500 + $500 = $5,000 / $6,000 = 83.33%

        // B) Safe borrow within threshold succeeds
        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 200e18); // $4,500 + $200 = $4,700 / $6,000 = 78.33%
        (,,,, uint256 finalDebt) = vault.getPosition(positionId);
        assertEq(finalDebt, 4700e18);
    }

    function testExtremeValuationMathDoesNotOverflow() public {
        bytes32 extremePos = keccak256("extreme-pos");
        address whale = address(0xEEEE);

        // Whale deposits massive amount where amount * price exceeds 2^256 if not handled safely
        // 1e30 tokens at $3,000 (3000e8) -> 3e41 (fits in 256 bits, but intermediate 512-bit safe)
        vm.prank(whale);
        vault.depositCollateral(extremePos, mockWeth, 1e30);

        // Price set to very large number
        address mockMegaToken = address(0x9999);
        vm.prank(owner);
        oracle.setAssetPrice(mockMegaToken, 1e20); // $1 trillion per token

        vm.prank(whale);
        vault.depositCollateral(extremePos, mockWeth, 1e25);

        (bool isBreached, uint256 ltv,) = vault.evaluatePositionRisk(extremePos);
        assertFalse(isBreached);
        assertEq(ltv, 0);
    }

    function testRevertWhenZeroPositionIdUsed() public {
        // Zero position ID rejected on depositCollateral
        vm.prank(alice);
        vm.expectRevert(CollateralVault.InvalidPositionId.selector);
        vault.depositCollateral(bytes32(0), mockWeth, 1e18);

        // Zero position ID rejected on recordBorrow
        vm.prank(alice);
        vm.expectRevert(CollateralVault.InvalidPositionId.selector);
        vault.recordBorrow(bytes32(0), mockUsdc, 100e18);

        // Zero position ID rejected on evaluatePositionRisk
        vm.expectRevert(CollateralVault.InvalidPositionId.selector);
        vault.evaluatePositionRisk(bytes32(0));
    }
}

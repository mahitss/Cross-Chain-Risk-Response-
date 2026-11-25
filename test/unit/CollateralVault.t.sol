// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {CollateralVault} from "../../src/origin/CollateralVault.sol";
import {RiskController} from "../../src/origin/RiskController.sol";
import {TestValuationSource} from "../../src/origin/TestValuationSource.sol";
import {CrossGuardIdentity} from "../../src/libraries/CrossGuardIdentity.sol";
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

    bytes32 constant ALICE_SALT = keccak256("alice-position-salt");

    event ValuationSourceUpdated(address indexed oldOracle, address indexed newOracle);

    function setUp() public {
        vm.startPrank(owner);
        oracle = new TestValuationSource(owner);
        riskController = new RiskController(owner, 8000); // 80% threshold

        vault = new CollateralVault(owner, address(oracle), address(riskController));
        riskController.setAuthorizedVault(address(vault), true);

        oracle.setAssetPrice(mockWeth, 3000e8);
        oracle.setAssetPrice(mockUsdc, 1e8);
        oracle.setAssetPrice(mockWbtc, 60000e8);
        oracle.setAssetPrice(mockDai, 1e8);
        vm.stopPrank();
    }

    function testDepositCollateralAndBorrow() public {
        vm.startPrank(alice);
        bytes32 positionId = vault.openPosition(ALICE_SALT, mockWeth, 2e18);
        assertEq(positionId, vault.computePositionId(alice, ALICE_SALT));

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
        bytes32 positionId = vault.openPosition(ALICE_SALT, mockWeth, 2e18);

        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AssetMismatch.selector, mockWbtc, mockWeth));
        vault.depositCollateral(positionId, mockWbtc, 1e18);
        vm.stopPrank();
    }

    function testRevertWhenMixedDebtAsset() public {
        vm.startPrank(alice);
        bytes32 positionId = vault.openPosition(ALICE_SALT, mockWeth, 2e18);
        vault.recordBorrow(positionId, mockUsdc, 1000e18);

        vm.expectRevert(abi.encodeWithSelector(CollateralVault.AssetMismatch.selector, mockDai, mockUsdc));
        vault.recordBorrow(positionId, mockDai, 500e18);
        vm.stopPrank();
    }

    function testEvaluatePositionHealthy() public {
        vm.startPrank(alice);
        bytes32 positionId = vault.openPosition(ALICE_SALT, mockWeth, 2e18);
        vault.recordBorrow(positionId, mockUsdc, 2000e18);
        vm.stopPrank();

        (bool isBreached, uint256 ltvBps, uint256 nonce) = vault.evaluatePositionRisk(positionId);
        assertFalse(isBreached);
        assertEq(ltvBps, 3333);
        assertEq(nonce, 0);
    }

    function testEvaluatePositionBreachedAfterPriceDrop() public {
        vm.startPrank(alice);
        bytes32 positionId = vault.openPosition(ALICE_SALT, mockWeth, 2e18);
        vault.recordBorrow(positionId, mockUsdc, 4500e18);
        vm.stopPrank();

        (bool breachedBefore,,) = vault.evaluatePositionRisk(positionId);
        assertFalse(breachedBefore);

        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2500e8);

        (bool isBreached, uint256 ltvBps, uint256 nonce) = vault.evaluatePositionRisk(positionId);
        assertTrue(isBreached);
        assertEq(ltvBps, 9000);
        assertEq(nonce, 1);
    }

    function testRevertWhenUnauthorizedUserModifiesPosition() public {
        vm.prank(alice);
        bytes32 positionId = vault.openPosition(ALICE_SALT, mockWeth, 1e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.UnauthorizedUser.selector, bob, alice));
        vault.depositCollateral(positionId, mockWeth, 1e18);
    }

    function testRevertWhenDepositingOrBorrowingOnUninitializedPosition() public {
        bytes32 uninitPos = vault.computePositionId(alice, ALICE_SALT);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.PositionNotInitialized.selector);
        vault.depositCollateral(uninitPos, mockWeth, 1e18);

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
        vault.openPosition(ALICE_SALT, mockWeth, 0);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        vault.openPosition(ALICE_SALT, address(0), 1e18);

        vm.prank(alice);
        bytes32 positionId = vault.openPosition(ALICE_SALT, mockWeth, 1e18);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAmount.selector);
        vault.depositCollateral(positionId, mockWeth, 0);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        vault.depositCollateral(positionId, address(0), 1e18);

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
        vm.startPrank(alice);
        bytes32 positionId = vault.openPosition(ALICE_SALT, mockWeth, 2e18);
        vault.recordBorrow(positionId, mockUsdc, 4000e18);
        vm.stopPrank();

        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2000e8);

        (bool isBreached,,) = vault.evaluatePositionRisk(positionId);
        assertTrue(isBreached, "Position must be breached");
        assertTrue(riskController.isPositionBreached(positionId), "Breach recorded in risk controller");
        assertEq(address(vault.riskController()), address(riskController));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionInBreachedState.selector, positionId));
        vault.recordBorrow(positionId, mockUsdc, 100e18);

        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 4000e8);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionInBreachedState.selector, positionId));
        vault.recordBorrow(positionId, mockUsdc, 100e18);

        (bool recoveredBreached, uint256 newLtv,) = vault.evaluatePositionRisk(positionId);
        assertFalse(recoveredBreached, "Breach cleared after explicit evaluation");
        assertEq(newLtv, 5000);
        assertFalse(riskController.isPositionBreached(positionId), "Breach cleared in controller");

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

    function testRevertBorrowWhenZeroCollateral() public {
        vm.prank(alice);
        bytes32 positionId = vault.openPosition(ALICE_SALT, mockWeth, 1e18);

        // Zero out collateralAmount in storage (_positions mapping at slot 2)
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
        bytes32 positionId = vault.openPosition(ALICE_SALT, mockWeth, 2e18);

        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.PositionUnsafeOrBreached.selector, positionId, 8000, 8000)
        );
        vault.recordBorrow(positionId, mockUsdc, 4800e18);

        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.PositionUnsafeOrBreached.selector, positionId, 8333, 8000)
        );
        vault.recordBorrow(positionId, mockUsdc, 5000e18);

        vault.recordBorrow(positionId, mockUsdc, 4000e18);
        vm.stopPrank();

        (,,,, uint256 debt) = vault.getPosition(positionId);
        assertEq(debt, 4000e18);
    }

    function testRevertBorrowWhenPositionAlreadyBreached() public {
        vm.startPrank(alice);
        bytes32 positionId = vault.openPosition(ALICE_SALT, mockWeth, 2e18);
        vault.recordBorrow(positionId, mockUsdc, 4500e18);
        vm.stopPrank();

        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2000e8);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.PositionUnsafeOrBreached.selector, positionId, 11500, 8000)
        );
        vault.recordBorrow(positionId, mockUsdc, 100e18);
    }

    function testRecoveryLifecycleOnOrigin() public {
        vm.startPrank(alice);
        bytes32 positionId = vault.openPosition(ALICE_SALT, mockWeth, 2e18);
        vault.recordBorrow(positionId, mockUsdc, 4500e18);
        vm.stopPrank();

        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2500e8);

        (bool isBreached, uint256 ltv, uint256 nonce) = vault.evaluatePositionRisk(positionId);
        assertTrue(isBreached);
        assertEq(ltv, 9000);
        assertEq(nonce, 1);

        vm.prank(alice);
        vault.depositCollateral(positionId, mockWeth, 2e18);

        (bool recovered, uint256 recLtv, uint256 recNonce) = vault.evaluatePositionRisk(positionId);
        assertFalse(recovered, "Position must now be recovered");
        assertEq(recLtv, 4500);
        assertEq(recNonce, 2, "Recovery must increment monotonic nonce");

        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 1000e18);
        (,,,, uint256 newDebt) = vault.getPosition(positionId);
        assertEq(newDebt, 5500e18);
    }

    function testStaleBreachStateBorrowRejectionUntilExplicitEvaluation() public {
        vm.startPrank(alice);
        bytes32 positionId = vault.openPosition(ALICE_SALT, mockWeth, 2e18);
        vault.recordBorrow(positionId, mockUsdc, 4500e18);
        vm.stopPrank();

        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 2500e8);

        (bool isBreached,,) = vault.evaluatePositionRisk(positionId);
        assertTrue(isBreached);
        assertTrue(riskController.isPositionBreached(positionId));

        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 3000e8);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionInBreachedState.selector, positionId));
        vault.recordBorrow(positionId, mockUsdc, 100e18);

        assertTrue(riskController.isPositionBreached(positionId));

        (bool recovered, uint256 recLtv, uint256 recNonce) = vault.evaluatePositionRisk(positionId);
        assertFalse(recovered);
        assertEq(recLtv, 7500);
        assertEq(recNonce, 2);
        assertFalse(riskController.isPositionBreached(positionId));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVault.PositionUnsafeOrBreached.selector, positionId, 8333, 8000)
        );
        vault.recordBorrow(positionId, mockUsdc, 500e18);

        vm.prank(alice);
        vault.recordBorrow(positionId, mockUsdc, 200e18);
        (,,,, uint256 finalDebt) = vault.getPosition(positionId);
        assertEq(finalDebt, 4700e18);
    }

    function testExtremeValuationMathDoesNotOverflow() public {
        bytes32 whaleSalt = keccak256("extreme-salt");
        address whale = address(0xEEEE);

        vm.prank(whale);
        bytes32 extremePos = vault.openPosition(whaleSalt, mockWeth, 1e30);

        address mockMegaToken = address(0x9999);
        vm.prank(owner);
        oracle.setAssetPrice(mockMegaToken, 1e20);

        vm.prank(whale);
        vault.depositCollateral(extremePos, mockWeth, 1e25);

        (bool isBreached, uint256 ltv,) = vault.evaluatePositionRisk(extremePos);
        assertFalse(isBreached);
        assertEq(ltv, 0);
    }

    function testRevertWhenZeroPositionIdOrZeroSaltUsed() public {
        vm.prank(alice);
        vm.expectRevert(CrossGuardIdentity.InvalidSalt.selector);
        vault.openPosition(bytes32(0), mockWeth, 1e18);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.InvalidPositionId.selector);
        vault.depositCollateral(bytes32(0), mockWeth, 1e18);

        vm.prank(alice);
        vm.expectRevert(CollateralVault.InvalidPositionId.selector);
        vault.recordBorrow(bytes32(0), mockUsdc, 100e18);

        vm.expectRevert(CollateralVault.InvalidPositionId.selector);
        vault.evaluatePositionRisk(bytes32(0));
    }
}

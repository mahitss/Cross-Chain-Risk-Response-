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
        address newRiskController = address(0x888);

        vm.startPrank(owner);
        vault.setValuationSource(newOracle);
        assertEq(address(vault.valuationSource()), newOracle);

        vault.setRiskController(newRiskController);
        assertEq(address(vault.riskController()), newRiskController);

        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        vault.setValuationSource(address(0));

        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        vault.setRiskController(address(0));
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setValuationSource(newOracle);
    }

    function testConstructorZeroAddressRevert() public {
        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        new CollateralVault(owner, address(0), address(riskController));

        vm.expectRevert(CollateralVault.ZeroAddress.selector);
        new CollateralVault(owner, address(oracle), address(0));
    }
}

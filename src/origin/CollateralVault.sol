// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {ITestValuationSource} from "../interfaces/ITestValuationSource.sol";
import {IRiskController} from "../interfaces/IRiskController.sol";

/// @title CollateralVault
/// @notice Controlled test vault managing user collateral and loan positions on Base Sepolia.
/// @dev Token Decimal Convention:
///      - All collateral and debt asset balances are represented in 18 decimals (1e18).
///      - All valuation oracle asset prices are represented in 8 decimals (1e8, Chainlink convention).
///      - Products are scaled cleanly by 1e18 using 512-bit intermediate math to avoid intermediate overflow.
contract CollateralVault is ICollateralVault, Ownable {
    error ZeroAmount();
    error ZeroAddress();
    error UnauthorizedUser(address caller, address positionOwner);
    error PositionNotInitialized();
    error AssetMismatch(address provided, address expected);
    error PositionInBreachedState(bytes32 positionId);
    error PositionUnsafeOrBreached(bytes32 positionId, uint256 projectedLtvBps, uint256 thresholdBps);
    error PositionUncollateralized(bytes32 positionId);

    struct Position {
        address user;
        address collateralAsset;
        uint256 collateralAmount;
        address debtAsset;
        uint256 debtAmount;
    }

    ITestValuationSource public valuationSource;
    IRiskController public riskController;

    mapping(bytes32 => Position) private _positions;
    mapping(bytes32 => address) public override positionCollateralAsset;
    mapping(bytes32 => address) public override positionDebtAsset;

    constructor(address initialOwner, address _valuationSource, address _riskController) Ownable(initialOwner) {
        if (_valuationSource == address(0) || _riskController == address(0)) {
            revert ZeroAddress();
        }
        valuationSource = ITestValuationSource(_valuationSource);
        riskController = IRiskController(_riskController);
    }

    /// @notice Updates the valuation oracle address.
    function setValuationSource(address _newOracle) external onlyOwner {
        if (_newOracle == address(0)) revert ZeroAddress();
        valuationSource = ITestValuationSource(_newOracle);
    }

    /// @notice Updates the risk controller address.
    function setRiskController(address _newController) external onlyOwner {
        if (_newController == address(0)) revert ZeroAddress();
        riskController = IRiskController(_newController);
    }

    /// @notice Deposits collateral into a position.
    /// @dev Enforces exactly one collateral asset per position for MVP.
    function depositCollateral(bytes32 positionId, address asset, uint256 amount) external override {
        if (amount == 0) revert ZeroAmount();
        if (asset == address(0)) revert ZeroAddress();

        Position storage pos = _positions[positionId];
        if (pos.user == address(0)) {
            pos.user = msg.sender;
            pos.collateralAsset = asset;
            positionCollateralAsset[positionId] = asset;
        } else {
            if (pos.user != msg.sender && msg.sender != owner()) {
                revert UnauthorizedUser(msg.sender, pos.user);
            }
            address expectedAsset = positionCollateralAsset[positionId];
            if (expectedAsset != asset) {
                revert AssetMismatch(asset, expectedAsset);
            }
        }

        pos.collateralAmount += amount;
        emit CollateralDeposited(positionId, pos.user, asset, amount);
    }

    /// @notice Records new borrowing against a position with origin-side safety checks.
    /// @dev Rejects debt increases if position has zero collateral, is already breached,
    ///      or if the projected borrow would exceed the risk threshold.
    function recordBorrow(bytes32 positionId, address asset, uint256 amount) external override {
        if (amount == 0) revert ZeroAmount();
        if (asset == address(0)) revert ZeroAddress();

        Position storage pos = _positions[positionId];
        if (pos.user == address(0)) revert PositionNotInitialized();
        if (pos.user != msg.sender && msg.sender != owner()) {
            revert UnauthorizedUser(msg.sender, pos.user);
        }

        address expectedAsset = positionDebtAsset[positionId];
        if (expectedAsset == address(0)) {
            positionDebtAsset[positionId] = asset;
            pos.debtAsset = asset;
        } else if (expectedAsset != asset) {
            revert AssetMismatch(asset, expectedAsset);
        }

        // 1. Position must not be in an active breached state
        if (riskController.isPositionBreached(positionId)) {
            revert PositionInBreachedState(positionId);
        }

        // 2. Position must have non-zero collateral to borrow
        if (pos.collateralAmount == 0) {
            revert PositionUncollateralized(positionId);
        }

        // 3. Compute valuations under current oracle pricing with full precision
        uint256 collateralPrice = valuationSource.getAssetPrice(pos.collateralAsset);
        uint256 debtPrice = valuationSource.getAssetPrice(asset);

        uint256 collateralValueUsd = _computeValuationUsd(pos.collateralAmount, collateralPrice);
        uint256 projectedDebtAmount = pos.debtAmount + amount;
        uint256 projectedDebtValueUsd = _computeValuationUsd(projectedDebtAmount, debtPrice);

        // 4. Prevent unsafe debt increase at origin
        uint256 projectedLtv = riskController.calculateLtvBps(collateralValueUsd, projectedDebtValueUsd);
        uint256 threshold = riskController.riskThresholdBps();
        if (projectedLtv >= threshold) {
            revert PositionUnsafeOrBreached(positionId, projectedLtv, threshold);
        }

        pos.debtAmount = projectedDebtAmount;
        emit BorrowRecorded(positionId, pos.user, asset, amount);
    }

    /// @notice Evaluates position health and triggers RiskBreach (or RiskResolved) via RiskController.
    /// @dev Uses single canonical RiskController evaluation to guarantee identical LTV and breach state in all events.
    function evaluatePositionRisk(bytes32 positionId)
        external
        override
        returns (bool isBreached, uint256 ltvBps, uint256 nonce)
    {
        Position storage pos = _positions[positionId];
        if (pos.user == address(0)) revert PositionNotInitialized();

        uint256 collateralPrice = pos.collateralAmount > 0 ? valuationSource.getAssetPrice(pos.collateralAsset) : 0;
        uint256 debtPrice = pos.debtAmount > 0 ? valuationSource.getAssetPrice(pos.debtAsset) : 0;

        uint256 collateralValueUsd = _computeValuationUsd(pos.collateralAmount, collateralPrice);
        uint256 debtValueUsd = _computeValuationUsd(pos.debtAmount, debtPrice);

        (isBreached, ltvBps, nonce) = riskController.assessRisk(positionId, pos.user, collateralValueUsd, debtValueUsd);

        emit PositionEvaluated(positionId, collateralValueUsd, debtValueUsd, ltvBps, nonce, isBreached);
    }

    /// @dev Computes full-precision USD valuation in 8 decimals: (amount * price) / 1e18.
    ///      amount: 18 decimals, price: 8 decimals.
    ///      If quotient exceeds type(uint256).max, deterministically returns type(uint256).max.
    function _computeValuationUsd(uint256 amount, uint256 price) internal pure returns (uint256) {
        if (amount == 0 || price == 0) return 0;

        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(amount, price, not(0))
            prod0 := mul(amount, price)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        if (prod1 >= 1e18) {
            return type(uint256).max;
        }

        return Math.mulDiv(amount, price, 1e18);
    }

    /// @notice Returns position details.
    function getPosition(bytes32 positionId)
        external
        view
        override
        returns (address user, address collateralAsset, uint256 collateralAmount, address debtAsset, uint256 debtAmount)
    {
        Position storage pos = _positions[positionId];
        return (pos.user, pos.collateralAsset, pos.collateralAmount, pos.debtAsset, pos.debtAmount);
    }
}

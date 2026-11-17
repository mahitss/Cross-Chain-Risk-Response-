// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {ITestValuationSource} from "../interfaces/ITestValuationSource.sol";
import {IRiskController} from "../interfaces/IRiskController.sol";

/// @title CollateralVault
/// @notice Controlled test vault managing user collateral and loan positions on Base Sepolia.
contract CollateralVault is ICollateralVault, Ownable {
    error ZeroAmount();
    error ZeroAddress();
    error UnauthorizedUser(address caller, address positionOwner);
    error PositionNotInitialized();

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

    constructor(
        address initialOwner,
        address _valuationSource,
        address _riskController
    ) Ownable(initialOwner) {
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
    function depositCollateral(
        bytes32 positionId,
        address asset,
        uint256 amount
    ) external override {
        if (amount == 0) revert ZeroAmount();
        if (asset == address(0)) revert ZeroAddress();

        Position storage pos = _positions[positionId];
        if (pos.user == address(0)) {
            pos.user = msg.sender;
            pos.collateralAsset = asset;
        } else {
            if (pos.user != msg.sender && msg.sender != owner()) {
                revert UnauthorizedUser(msg.sender, pos.user);
            }
        }

        pos.collateralAmount += amount;
        emit CollateralDeposited(positionId, pos.user, asset, amount);
    }

    /// @notice Records new borrowing against a position.
    function recordBorrow(
        bytes32 positionId,
        address asset,
        uint256 amount
    ) external override {
        if (amount == 0) revert ZeroAmount();
        if (asset == address(0)) revert ZeroAddress();

        Position storage pos = _positions[positionId];
        if (pos.user == address(0)) revert PositionNotInitialized();
        if (pos.user != msg.sender && msg.sender != owner()) {
            revert UnauthorizedUser(msg.sender, pos.user);
        }

        pos.debtAsset = asset;
        pos.debtAmount += amount;
        emit BorrowRecorded(positionId, pos.user, asset, amount);
    }

    /// @notice Evaluates the current health of a position and triggers RiskBreach via RiskController if unhealthy.
    function evaluatePositionRisk(bytes32 positionId) external override returns (bool isBreached, uint256 ltvBps) {
        Position storage pos = _positions[positionId];
        if (pos.user == address(0)) revert PositionNotInitialized();

        uint256 collateralPrice = valuationSource.getAssetPrice(pos.collateralAsset);
        uint256 debtPrice = pos.debtAmount > 0 ? valuationSource.getAssetPrice(pos.debtAsset) : 0;

        // Compute raw product (scaled by 1e26) to preserve precision without divide-before-multiply
        uint256 rawCollateralProduct = pos.collateralAmount * collateralPrice;
        uint256 rawDebtProduct = pos.debtAmount * debtPrice;

        uint256 calculatedLtv = 0;
        if (rawCollateralProduct > 0) {
            calculatedLtv = (rawDebtProduct * 10_000) / rawCollateralProduct;
        } else if (rawDebtProduct > 0) {
            calculatedLtv = 10_000;
        }

        uint256 collateralValueUsd = rawCollateralProduct / 1e18;
        uint256 debtValueUsd = rawDebtProduct / 1e18;

        bool projectedBreached = calculatedLtv >= riskController.riskThresholdBps();
        emit PositionEvaluated(positionId, collateralValueUsd, debtValueUsd, calculatedLtv, projectedBreached);

        (isBreached, ltvBps) = riskController.assessRisk(positionId, pos.user, collateralValueUsd, debtValueUsd);
    }

    /// @notice Returns position details.
    function getPosition(bytes32 positionId) external view override returns (
        address user,
        address collateralAsset,
        uint256 collateralAmount,
        address debtAsset,
        uint256 debtAmount
    ) {
        Position storage pos = _positions[positionId];
        return (pos.user, pos.collateralAsset, pos.collateralAmount, pos.debtAsset, pos.debtAmount);
    }
}

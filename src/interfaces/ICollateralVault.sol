// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

/// @title ICollateralVault
/// @notice Controlled test vault tracking user collateral and debt positions.
/// @dev Collateral and debt token amounts are expected in 18 decimals (1e18).
///      Valuation oracle prices are expected in 8 decimals (1e8).
interface ICollateralVault {
    event CollateralDeposited(bytes32 indexed positionId, address indexed user, address indexed asset, uint256 amount);
    event BorrowRecorded(bytes32 indexed positionId, address indexed user, address indexed asset, uint256 amount);
    event PositionEvaluated(
        bytes32 indexed positionId,
        uint256 collateralValueUsd,
        uint256 debtValueUsd,
        uint256 ltvBps,
        uint256 nonce,
        bool isBreached
    );

    function depositCollateral(bytes32 positionId, address asset, uint256 amount) external;
    function recordBorrow(bytes32 positionId, address asset, uint256 amount) external;
    function evaluatePositionRisk(bytes32 positionId) external returns (bool isBreached, uint256 ltvBps, uint256 nonce);
    function getPosition(bytes32 positionId)
        external
        view
        returns (address user, address collateralAsset, uint256 collateralAmount, address debtAsset, uint256 debtAmount);
    function positionCollateralAsset(bytes32 positionId) external view returns (address);
    function positionDebtAsset(bytes32 positionId) external view returns (address);
}

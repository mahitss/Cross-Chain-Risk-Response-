// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

/// @title ICollateralVault
/// @notice Controlled test vault tracking user collateral and debt positions.
interface ICollateralVault {
    event CollateralDeposited(bytes32 indexed positionId, address indexed user, address indexed asset, uint256 amount);
    event BorrowRecorded(bytes32 indexed positionId, address indexed user, address indexed asset, uint256 amount);
    event PositionEvaluated(bytes32 indexed positionId, uint256 collateralValueUsd, uint256 debtValueUsd, uint256 ltvBps, bool isBreached);

    function depositCollateral(bytes32 positionId, address asset, uint256 amount) external;
    function recordBorrow(bytes32 positionId, address asset, uint256 amount) external;
    function evaluatePositionRisk(bytes32 positionId) external returns (bool isBreached, uint256 ltvBps);
    function getPosition(bytes32 positionId) external view returns (
        address user,
        address collateralAsset,
        uint256 collateralAmount,
        address debtAsset,
        uint256 debtAmount
    );
}

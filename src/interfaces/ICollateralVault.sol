// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {CrossGuardIdentity} from "../libraries/CrossGuardIdentity.sol";

/// @title ICollateralVault
/// @notice Controlled test vault managing user collateral and debt positions with canonical identity derivation.
/// @dev Collateral and debt token amounts are expected in 18 decimals (1e18).
///      Valuation oracle prices are expected in 8 decimals (1e8).
interface ICollateralVault {
    event PositionOpened(
        bytes32 indexed positionId, address indexed user, bytes32 indexed salt, address collateralAsset, uint256 amount
    );
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

    function openPosition(bytes32 salt, address asset, uint256 amount) external returns (bytes32 positionId);
    function depositCollateral(bytes32 positionId, address asset, uint256 amount) external;
    function recordBorrow(bytes32 positionId, address asset, uint256 amount) external;
    function evaluatePositionRisk(bytes32 positionId) external returns (bool isBreached, uint256 ltvBps, uint256 nonce);
    function computePositionId(address originUser, bytes32 salt) external view returns (bytes32);
    function getPositionIdentity(bytes32 positionId) external view returns (CrossGuardIdentity.OriginIdentity memory);
    function getPosition(bytes32 positionId)
        external
        view
        returns (address user, address collateralAsset, uint256 collateralAmount, address debtAsset, uint256 debtAmount);
    function positionCollateralAsset(bytes32 positionId) external view returns (address);
    function positionDebtAsset(bytes32 positionId) external view returns (address);
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {CrossGuardIdentity} from "../libraries/CrossGuardIdentity.sol";

/// @title IRiskController
/// @notice Evaluates collateralization health and emits versioned identity-bound risk events with monotonic nonces.
/// @dev Decimal Conventions:
///      - Token Balances: 18 decimals (1e18)
///      - Oracle Asset Prices: 8 decimals (1e8)
///      - Valuation USD: 8 decimals (1e8)
///      - LTV Scale: Basis points (10,000 = 100.00%)
interface IRiskController {
    event PositionIdentityRegistered(
        bytes32 indexed positionId,
        uint256 originChainId,
        address originRiskController,
        address indexed originVault,
        address indexed originUser,
        bytes32 salt
    );

    /// @dev M007.1 Identity Protocol V1 RiskBreach event (192 bytes fixed non-indexed ABI payload).
    event RiskBreach(
        bytes32 indexed positionId,
        address indexed user,
        uint256 indexed nonce,
        uint8 identityVersion,
        address originVault,
        bytes32 positionSalt,
        uint256 currentLtvBps,
        uint256 thresholdLtvBps,
        uint256 timestamp
    );

    /// @dev M007.1 Identity Protocol V1 RiskResolved event (192 bytes fixed non-indexed ABI payload).
    event RiskResolved(
        bytes32 indexed positionId,
        address indexed user,
        uint256 indexed nonce,
        uint8 identityVersion,
        address originVault,
        bytes32 positionSalt,
        uint256 currentLtvBps,
        uint256 thresholdLtvBps,
        uint256 timestamp
    );

    event RiskThresholdUpdated(uint256 oldThresholdBps, uint256 newThresholdBps);
    event AuthorizedVaultUpdated(address indexed vault, bool authorized);

    function setRiskThreshold(uint256 newThresholdBps) external;
    function registerPositionIdentity(bytes32 positionId, address originUser, bytes32 salt) external;
    function assessRisk(bytes32 positionId, address user, uint256 collateralValueUsd, uint256 debtValueUsd)
        external
        returns (bool isBreached, uint256 currentLtvBps, uint256 nonce);
    function calculateLtvBps(uint256 collateralValueUsd, uint256 debtValueUsd) external pure returns (uint256);
    function computePositionId(address originVault, address originUser, bytes32 salt) external view returns (bytes32);
    function getPositionIdentity(bytes32 positionId) external view returns (CrossGuardIdentity.OriginIdentity memory);
    function positionIdentityRegistered(bytes32 positionId) external view returns (bool);
    function riskThresholdBps() external view returns (uint256);
    function positionNonce(bytes32 positionId) external view returns (uint256);
    function isPositionBreached(bytes32 positionId) external view returns (bool);
}

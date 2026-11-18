// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

/// @title IRiskController
/// @notice Evaluates collateralization health and emits risk condition events with monotonic source nonces.
interface IRiskController {
    event RiskBreach(
        bytes32 indexed positionId,
        address indexed user,
        uint256 indexed nonce,
        uint256 currentLtvBps,
        uint256 thresholdLtvBps,
        uint256 timestamp
    );

    event RiskThresholdUpdated(uint256 oldThresholdBps, uint256 newThresholdBps);
    event AuthorizedVaultUpdated(address indexed vault, bool authorized);

    function setRiskThreshold(uint256 newThresholdBps) external;
    function assessRisk(bytes32 positionId, address user, uint256 collateralValueUsd, uint256 debtValueUsd)
        external
        returns (bool isBreached, uint256 currentLtvBps, uint256 nonce);
    function riskThresholdBps() external view returns (uint256);
    function positionNonce(bytes32 positionId) external view returns (uint256);
}

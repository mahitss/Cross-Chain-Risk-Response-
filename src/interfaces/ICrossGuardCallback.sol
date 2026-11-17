// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

/// @title ICrossGuardCallback
/// @notice Interface for destination cross-chain risk callback receiver.
interface ICrossGuardCallback {
    event RiskBreachHandled(bytes32 indexed positionId, address indexed rvmSender, uint256 riskLevel, uint256 timestamp);

    function handleRiskBreach(
        address rvmSender,
        bytes32 positionId,
        uint256 riskLevel,
        uint256 timestamp
    ) external;
}

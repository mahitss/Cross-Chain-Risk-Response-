// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

/// @title IBorrowingController
/// @notice Lending facility controller enforcing position borrowing state restrictions, replay protection, and access control.
interface IBorrowingController {
    event PositionRegistered(bytes32 indexed positionId, address indexed owner);
    event BorrowingPaused(bytes32 indexed positionId, uint256 indexed nonce, uint256 riskLevel, uint256 timestamp);
    event EmergencyBorrowingPaused(bytes32 indexed positionId);
    event BorrowingResumed(bytes32 indexed positionId);
    event RiskBreachResolved(bytes32 indexed positionId, uint256 indexed nonce, uint256 riskLevel, uint256 timestamp);
    event EmergencyBorrowingResumed(
        bytes32 indexed positionId, address indexed admin, string reason, uint256 timestamp
    );
    event BorrowExecuted(bytes32 indexed positionId, address indexed borrower, uint256 amount);

    function registerPosition(bytes32 positionId) external;
    function registerPositionFor(bytes32 positionId, address positionOwner) external;
    function pauseBorrowing(bytes32 positionId, uint256 nonce, uint256 riskLevel, uint256 timestamp) external;
    function emergencyPauseBorrowing(bytes32 positionId) external;
    function resumeBorrowing(bytes32 positionId) external;
    function resolveBorrowing(bytes32 positionId, uint256 nonce, uint256 riskLevel, uint256 timestamp) external;
    function emergencyResumeBorrowing(bytes32 positionId, string calldata reason) external;
    function borrow(bytes32 positionId, uint256 amount) external;
    function isBorrowingPaused(bytes32 positionId) external view returns (bool);
    function pausedByRiskBreach(bytes32 positionId) external view returns (bool);
    function lastProcessedNonce(bytes32 positionId) external view returns (uint256);
    function lastRiskBreachTimestamp(bytes32 positionId) external view returns (uint256);
    function positionOwners(bytes32 positionId) external view returns (address);
}

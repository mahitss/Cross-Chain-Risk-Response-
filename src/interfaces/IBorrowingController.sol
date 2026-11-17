// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

/// @title IBorrowingController
/// @notice Lending facility controller enforcing borrowing state restrictions.
interface IBorrowingController {
    event BorrowingPaused(bytes32 indexed positionId, uint256 riskLevel, uint256 timestamp);
    event BorrowingResumed(bytes32 indexed positionId);
    event BorrowExecuted(bytes32 indexed positionId, address indexed borrower, uint256 amount);

    function pauseBorrowing(bytes32 positionId, uint256 riskLevel, uint256 timestamp) external;
    function resumeBorrowing(bytes32 positionId) external;
    function borrow(bytes32 positionId, uint256 amount) external;
    function isBorrowingPaused(bytes32 positionId) external view returns (bool);
    function lastRiskBreachTimestamp(bytes32 positionId) external view returns (uint256);
}

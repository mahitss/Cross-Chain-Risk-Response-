// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBorrowingController} from "../interfaces/IBorrowingController.sol";

/// @title BorrowingController
/// @notice Destination lending controller on Unichain Sepolia enforcing position borrowing pauses.
contract BorrowingController is IBorrowingController, Ownable {
    error UnauthorizedCallback(address caller);
    error BorrowingIsPaused(bytes32 positionId);
    error StaleRiskBreach(uint256 incomingTimestamp, uint256 lastRecordedTimestamp);
    error ZeroAmount();
    error ZeroAddress();

    event CallbackAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    address public callbackAdapter;
    mapping(bytes32 => bool) public override isBorrowingPaused;
    mapping(bytes32 => uint256) public override lastRiskBreachTimestamp;
    mapping(bytes32 => uint256) public positionBorrowDebt;
    mapping(bytes32 => address) public positionBorrowers;

    modifier onlyCallbackAdapter() {
        if (msg.sender != callbackAdapter && msg.sender != owner()) {
            revert UnauthorizedCallback(msg.sender);
        }
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Sets the authorized callback adapter.
    function setCallbackAdapter(address _callbackAdapter) external onlyOwner {
        if (_callbackAdapter == address(0)) revert ZeroAddress();
        address oldAdapter = callbackAdapter;
        callbackAdapter = _callbackAdapter;
        emit CallbackAdapterUpdated(oldAdapter, _callbackAdapter);
    }

    /// @notice Pauses additional borrowing for a position upon cross-chain risk condition confirmation.
    /// @dev Idempotent: repeated calls update the timestamp without reverting if position is already paused.
    function pauseBorrowing(
        bytes32 positionId,
        uint256 riskLevel,
        uint256 timestamp
    ) external override onlyCallbackAdapter {
        if (timestamp < lastRiskBreachTimestamp[positionId]) {
            revert StaleRiskBreach(timestamp, lastRiskBreachTimestamp[positionId]);
        }

        isBorrowingPaused[positionId] = true;
        lastRiskBreachTimestamp[positionId] = timestamp;

        emit BorrowingPaused(positionId, riskLevel, timestamp);
    }

    /// @notice Unpauses borrowing for a position (administrative or collateral remediation recovery).
    function resumeBorrowing(bytes32 positionId) external override onlyOwner {
        isBorrowingPaused[positionId] = false;
        emit BorrowingResumed(positionId);
    }

    /// @notice Simulates borrowing action on Unichain Sepolia.
    function borrow(bytes32 positionId, uint256 amount) external override {
        if (isBorrowingPaused[positionId]) {
            revert BorrowingIsPaused(positionId);
        }
        if (amount == 0) {
            revert ZeroAmount();
        }

        if (positionBorrowers[positionId] == address(0)) {
            positionBorrowers[positionId] = msg.sender;
        }

        positionBorrowDebt[positionId] += amount;
        emit BorrowExecuted(positionId, msg.sender, amount);
    }
}

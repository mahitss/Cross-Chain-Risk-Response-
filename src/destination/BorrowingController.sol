// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBorrowingController} from "../interfaces/IBorrowingController.sol";

/// @title BorrowingController
/// @notice Destination lending controller on Unichain Sepolia enforcing position borrowing pauses,
///         trusted ownership mapping, replay protection via nonces, and separate emergency controls.
contract BorrowingController is IBorrowingController, Ownable {
    error UnauthorizedCallback(address caller);
    error UnauthorizedBorrower(address caller, address expectedOwner);
    error InvalidPositionId();
    error UnregisteredPosition(bytes32 positionId);
    error PositionAlreadyRegistered(bytes32 positionId);
    error BorrowingIsPaused(bytes32 positionId);
    error InvalidNonce(uint256 incomingNonce, uint256 lastProcessedNonce);
    error ZeroAmount();
    error ZeroAddress();
    error CannotBypassActiveRiskBreach(bytes32 positionId);
    error PositionNotPaused(bytes32 positionId);
    error EmptyEmergencyReason();

    event CallbackAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    address public callbackAdapter;
    mapping(bytes32 => address) public override positionOwners;
    mapping(bytes32 => bool) public override isBorrowingPaused;
    mapping(bytes32 => bool) public override pausedByRiskBreach;
    mapping(bytes32 => uint256) public override lastProcessedNonce;
    mapping(bytes32 => uint256) public override lastRiskBreachTimestamp;
    mapping(bytes32 => uint256) public positionBorrowDebt;

    modifier onlyCallbackAdapter() {
        if (msg.sender != callbackAdapter) {
            revert UnauthorizedCallback(msg.sender);
        }
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Sets the authorized cross-chain callback adapter.
    function setCallbackAdapter(address _callbackAdapter) external onlyOwner {
        if (_callbackAdapter == address(0)) revert ZeroAddress();
        address oldAdapter = callbackAdapter;
        callbackAdapter = _callbackAdapter;
        emit CallbackAdapterUpdated(oldAdapter, _callbackAdapter);
    }

    /// @notice Registers a position to msg.sender as the trusted position owner.
    function registerPosition(bytes32 positionId) external override {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        if (positionOwners[positionId] != address(0)) {
            revert PositionAlreadyRegistered(positionId);
        }
        positionOwners[positionId] = msg.sender;
        emit PositionRegistered(positionId, msg.sender);
    }

    /// @notice Administratively registers a position to a specified owner.
    function registerPositionFor(bytes32 positionId, address positionOwner) external override onlyOwner {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        if (positionOwner == address(0)) revert ZeroAddress();
        if (positionOwners[positionId] != address(0)) {
            revert PositionAlreadyRegistered(positionId);
        }
        positionOwners[positionId] = positionOwner;
        emit PositionRegistered(positionId, positionOwner);
    }

    /// @notice Pauses borrowing for a position upon receiving an authenticated cross-chain risk callback.
    /// @dev Strictly callable by the callback adapter only. Rejects duplicate and out-of-order nonces.
    function pauseBorrowing(bytes32 positionId, uint256 nonce, uint256 riskLevel, uint256 timestamp)
        external
        override
        onlyCallbackAdapter
    {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        uint256 lastNonce = lastProcessedNonce[positionId];
        if (nonce <= lastNonce) {
            revert InvalidNonce(nonce, lastNonce);
        }

        lastProcessedNonce[positionId] = nonce;
        lastRiskBreachTimestamp[positionId] = timestamp;
        isBorrowingPaused[positionId] = true;
        pausedByRiskBreach[positionId] = true;

        emit BorrowingPaused(positionId, nonce, riskLevel, timestamp);
    }

    /// @notice Resumes borrowing for a position upon receiving an authenticated cross-chain risk resolution callback.
    /// @dev Strictly callable by the callback adapter only. Rejects duplicate and out-of-order nonces.
    function resolveBorrowing(bytes32 positionId, uint256 nonce, uint256 riskLevel, uint256 timestamp)
        external
        override
        onlyCallbackAdapter
    {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        uint256 lastNonce = lastProcessedNonce[positionId];
        if (nonce <= lastNonce) {
            revert InvalidNonce(nonce, lastNonce);
        }
        if (!isBorrowingPaused[positionId]) {
            revert PositionNotPaused(positionId);
        }

        lastProcessedNonce[positionId] = nonce;
        isBorrowingPaused[positionId] = false;
        pausedByRiskBreach[positionId] = false;

        emit RiskBreachResolved(positionId, nonce, riskLevel, timestamp);
        emit BorrowingResumed(positionId);
    }

    /// @notice Separate administrative emergency circuit breaker to pause borrowing.
    function emergencyPauseBorrowing(bytes32 positionId) external override onlyOwner {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        isBorrowingPaused[positionId] = true;
        emit EmergencyBorrowingPaused(positionId);
    }

    /// @notice Resumes borrowing for an administratively paused position.
    /// @dev Strictly reverts if the position was paused due to an active risk breach,
    ///      preventing ordinary owner actions from silently bypassing unresolved risk conditions.
    function resumeBorrowing(bytes32 positionId) external override onlyOwner {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        if (pausedByRiskBreach[positionId]) {
            revert CannotBypassActiveRiskBreach(positionId);
        }
        if (!isBorrowingPaused[positionId]) {
            revert PositionNotPaused(positionId);
        }
        isBorrowingPaused[positionId] = false;
        emit BorrowingResumed(positionId);
    }

    /// @notice Emergency administrative override to resume borrowing with an explicit reason and audit event.
    /// @dev Used only when cross-chain relay is permanently unavailable and remediation has been attested.
    function emergencyResumeBorrowing(bytes32 positionId, string calldata reason) external override onlyOwner {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        if (bytes(reason).length == 0) revert EmptyEmergencyReason();
        if (!isBorrowingPaused[positionId]) revert PositionNotPaused(positionId);

        isBorrowingPaused[positionId] = false;
        pausedByRiskBreach[positionId] = false;

        emit EmergencyBorrowingResumed(positionId, msg.sender, reason, block.timestamp);
        emit BorrowingResumed(positionId);
    }

    /// @notice Executes borrowing for a position.
    /// @dev Enforces position registration, position owner authorization, and pause state.
    function borrow(bytes32 positionId, uint256 amount) external override {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        address posOwner = positionOwners[positionId];
        if (posOwner == address(0)) {
            revert UnregisteredPosition(positionId);
        }
        if (msg.sender != posOwner) {
            revert UnauthorizedBorrower(msg.sender, posOwner);
        }
        if (isBorrowingPaused[positionId]) {
            revert BorrowingIsPaused(positionId);
        }
        if (amount == 0) {
            revert ZeroAmount();
        }

        positionBorrowDebt[positionId] += amount;
        emit BorrowExecuted(positionId, msg.sender, amount);
    }
}

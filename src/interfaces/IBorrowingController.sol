// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {CrossGuardIdentity} from "../libraries/CrossGuardIdentity.sol";

/// @title IBorrowingController
/// @notice Destination lending controller enforcing authenticated position ownership, EIP-712/ERC-1271 delegation,
///         origin identity binding, replay protection, and pause separation.
interface IBorrowingController {
    event PositionRegistered(
        bytes32 indexed positionId, address indexed originUser, address indexed destinationOwner, bytes32 identityHash
    );
    event PositionIdentityInitialized(
        bytes32 indexed positionId, address indexed originUser, bytes32 identityHash, uint8 identityVersion
    );
    event PositionAuthorizationConsumed(
        bytes32 indexed positionId, address indexed originUser, address indexed destinationOwner, uint256 sigNonce
    );
    event BorrowingPaused(bytes32 indexed positionId, uint256 indexed nonce, uint256 riskLevel, uint256 timestamp);
    event EmergencyBorrowingPaused(bytes32 indexed positionId);
    event BorrowingResumed(bytes32 indexed positionId);
    event RiskBreachResolved(bytes32 indexed positionId, uint256 indexed nonce, uint256 riskLevel, uint256 timestamp);
    event EmergencyBorrowingResumed(
        bytes32 indexed positionId, address indexed admin, string reason, uint256 timestamp
    );
    event BorrowExecuted(bytes32 indexed positionId, address indexed borrower, uint256 amount);

    function registerPosition(bytes32 salt) external returns (bytes32 positionId);
    function registerPositionWithAuthorization(
        CrossGuardIdentity.OriginIdentity calldata identity,
        address destinationOwner,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bytes32 positionId);
    function pauseBorrowing(CrossGuardIdentity.RiskCallbackMessage calldata message) external;
    function resolveBorrowing(CrossGuardIdentity.RiskCallbackMessage calldata message) external;
    function emergencyPauseBorrowing(bytes32 positionId) external;
    function resumeBorrowing(bytes32 positionId) external;
    function emergencyResumeBorrowing(bytes32 positionId, string calldata reason) external;
    function borrow(bytes32 positionId, uint256 amount) external;

    function trustedOriginChainId() external view returns (uint256);
    function trustedOriginRiskController() external view returns (address);
    function trustedOriginVault() external view returns (address);
    function computePositionId(address originUser, bytes32 salt) external view returns (bytes32);
    function computeAuthorizePositionDigest(
        CrossGuardIdentity.OriginIdentity calldata identity,
        address destinationOwner,
        uint256 sigNonce,
        uint256 deadline
    ) external view returns (bytes32);
    function isBorrowingPaused(bytes32 positionId) external view returns (bool);
    function pausedByRiskBreach(bytes32 positionId) external view returns (bool);
    function pausedByAdmin(bytes32 positionId) external view returns (bool);
    function lastProcessedNonce(bytes32 positionId) external view returns (uint256);
    function lastRiskBreachTimestamp(bytes32 positionId) external view returns (uint256);
    function positionOwners(bytes32 positionId) external view returns (address);
    function originUsers(bytes32 positionId) external view returns (address);
    function originIdentityHashes(bytes32 positionId) external view returns (bytes32);
    function positionIdentityVersion(bytes32 positionId) external view returns (uint8);
    function sigNonces(address originUser) external view returns (uint256);
}

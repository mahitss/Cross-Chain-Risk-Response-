// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {CrossGuardIdentity} from "../libraries/CrossGuardIdentity.sol";

/// @title ICrossGuardCallback
/// @notice Interface for destination cross-chain risk callback receiver with Reactive and canonical identity validation.
interface ICrossGuardCallback {
    event RiskBreachHandled(
        bytes32 indexed positionId,
        address indexed rvmSender,
        address indexed originUser,
        uint256 nonce,
        uint256 riskLevel,
        uint256 timestamp
    );

    event RiskResolvedHandled(
        bytes32 indexed positionId,
        address indexed rvmSender,
        address indexed originUser,
        uint256 nonce,
        uint256 riskLevel,
        uint256 timestamp
    );

    function handleRiskBreach(address rvmSender, CrossGuardIdentity.RiskCallbackMessage calldata message) external;

    function handleRiskResolved(address rvmSender, CrossGuardIdentity.RiskCallbackMessage calldata message) external;
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBorrowingController} from "../interfaces/IBorrowingController.sol";
import {ICrossGuardCallback} from "../interfaces/ICrossGuardCallback.sol";

/// @title CrossGuardCallback
/// @notice Destination callback receiver deployed on Unichain Sepolia, invoked via Reactive Callback Proxy.
///         Enforces dual-layer authentication: official Callback Proxy sender check and authenticated ReactVM ID check.
contract CrossGuardCallback is ICrossGuardCallback, AbstractCallback, Ownable {
    error ZeroAddress();
    error UnauthorizedReactiveSender(address receivedSender, address expectedSender);
    error UnauthorizedRvmSender(address receivedSender, address expectedSender);
    error UnconfiguredReactiveSender();

    address public immutable callbackProxy;
    address public borrowingController;
    address public authorizedReactiveSender;

    event AuthorizedReactiveSenderUpdated(address oldSender, address newSender);
    event BorrowingControllerUpdated(address oldController, address newController);

    constructor(
        address initialOwner,
        address _callbackProxy,
        address _borrowingController,
        address _authorizedReactiveSender
    ) AbstractCallback(_callbackProxy) Ownable(initialOwner) {
        if (
            _callbackProxy == address(0) || _borrowingController == address(0)
                || _authorizedReactiveSender == address(0)
        ) {
            revert ZeroAddress();
        }
        borrowingController = _borrowingController;
        authorizedReactiveSender = _authorizedReactiveSender;
        callbackProxy = _callbackProxy;
        emit AuthorizedReactiveSenderUpdated(address(0), _authorizedReactiveSender);
    }

    /// @notice Updates the authorized Reactive Contract address.
    function setAuthorizedReactiveSender(address _newSender) external onlyOwner {
        if (_newSender == address(0)) revert ZeroAddress();
        address oldSender = authorizedReactiveSender;
        authorizedReactiveSender = _newSender;
        emit AuthorizedReactiveSenderUpdated(oldSender, _newSender);
    }

    /// @notice Updates the target BorrowingController contract address.
    function setBorrowingController(address _newController) external onlyOwner {
        if (_newController == address(0)) revert ZeroAddress();
        address oldController = borrowingController;
        borrowingController = _newController;
        emit BorrowingControllerUpdated(oldController, _newController);
    }

    /// @notice Receives verified cross-chain callback from the Reactive Network via Callback Proxy.
    /// @dev msg.sender is authenticated via `authorizedSenderOnly` to be the official Callback Proxy.
    ///      reactiveSender is injected into the first 160 bits by the Reactive Network relayer (matching deployed Reactive contract address).
    function handleRiskBreach(
        address reactiveSender,
        bytes32 positionId,
        uint256 nonce,
        uint256 riskLevel,
        uint256 timestamp
    ) external override authorizedSenderOnly {
        if (authorizedReactiveSender == address(0)) {
            revert UnconfiguredReactiveSender();
        }
        if (reactiveSender != authorizedReactiveSender) {
            revert UnauthorizedReactiveSender(reactiveSender, authorizedReactiveSender);
        }

        emit RiskBreachHandled(positionId, reactiveSender, nonce, riskLevel, timestamp);
        IBorrowingController(borrowingController).pauseBorrowing(positionId, nonce, riskLevel, timestamp);
    }

    /// @notice Receives verified cross-chain recovery callback from the Reactive Network via Callback Proxy.
    function handleRiskResolved(
        address reactiveSender,
        bytes32 positionId,
        uint256 nonce,
        uint256 riskLevel,
        uint256 timestamp
    ) external override authorizedSenderOnly {
        if (authorizedReactiveSender == address(0)) {
            revert UnconfiguredReactiveSender();
        }
        if (reactiveSender != authorizedReactiveSender) {
            revert UnauthorizedReactiveSender(reactiveSender, authorizedReactiveSender);
        }

        emit RiskResolvedHandled(positionId, reactiveSender, nonce, riskLevel, timestamp);
        IBorrowingController(borrowingController).resolveBorrowing(positionId, nonce, riskLevel, timestamp);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBorrowingController} from "../interfaces/IBorrowingController.sol";
import {ICrossGuardCallback} from "../interfaces/ICrossGuardCallback.sol";
import {CrossGuardIdentity} from "../libraries/CrossGuardIdentity.sol";

/// @title CrossGuardCallback
/// @notice Destination callback receiver deployed on Unichain Sepolia (1301), invoked via Reactive Callback Proxy.
///         Enforces Callback Proxy caller auth, deployed CrossGuardReactive sender auth,
///         and canonical origin identity recomputation before forwarding to BorrowingController.
contract CrossGuardCallback is ICrossGuardCallback, AbstractCallback, Ownable {
    error ZeroAddress();
    error InvalidPositionId();
    error UnauthorizedReactiveSender(address receivedSender, address expectedSender);
    error UnauthorizedRvmSender(address receivedSender, address expectedSender);
    error UnconfiguredReactiveSender();
    error InvalidIdentityVersion(uint8 version);
    error PositionIdMismatch(bytes32 providedPositionId, bytes32 derivedPositionId);

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

    /// @notice Receives verified cross-chain RiskBreach callback via Unichain Callback Proxy.
    /// @dev reactiveSender is injected by Callback Proxy (matching deployed CrossGuardReactive address)
    ///      and is strictly distinct from message.originUser.
    function handleRiskBreach(address reactiveSender, CrossGuardIdentity.RiskCallbackMessage calldata message)
        external
        override
        authorizedSenderOnly
    {
        _validateCallbackAuthentication(reactiveSender, message);

        emit RiskBreachHandled(
            message.positionId, reactiveSender, message.originUser, message.nonce, message.riskLevel, message.timestamp
        );
        IBorrowingController(borrowingController).pauseBorrowing(message);
    }

    /// @notice Receives verified cross-chain RiskResolved callback via Unichain Callback Proxy.
    function handleRiskResolved(address reactiveSender, CrossGuardIdentity.RiskCallbackMessage calldata message)
        external
        override
        authorizedSenderOnly
    {
        _validateCallbackAuthentication(reactiveSender, message);

        emit RiskResolvedHandled(
            message.positionId, reactiveSender, message.originUser, message.nonce, message.riskLevel, message.timestamp
        );
        IBorrowingController(borrowingController).resolveBorrowing(message);
    }

    function _validateCallbackAuthentication(
        address reactiveSender,
        CrossGuardIdentity.RiskCallbackMessage calldata message
    ) internal view {
        if (authorizedReactiveSender == address(0)) {
            revert UnconfiguredReactiveSender();
        }
        if (reactiveSender != authorizedReactiveSender) {
            revert UnauthorizedReactiveSender(reactiveSender, authorizedReactiveSender);
        }
        if (message.identityVersion != CrossGuardIdentity.IDENTITY_VERSION) {
            revert InvalidIdentityVersion(message.identityVersion);
        }
        if (message.positionId == bytes32(0)) {
            revert InvalidPositionId();
        }

        bytes32 derivedPositionId = CrossGuardIdentity.computePositionId(
            message.originChainId, message.originRiskController, message.originVault, message.originUser, message.salt
        );
        if (derivedPositionId != message.positionId) {
            revert PositionIdMismatch(message.positionId, derivedPositionId);
        }
    }
}

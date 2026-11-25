// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IBorrowingController} from "../interfaces/IBorrowingController.sol";
import {CrossGuardIdentity} from "../libraries/CrossGuardIdentity.sol";

/// @title BorrowingController
/// @notice Destination lending controller on Unichain Sepolia (1301) enforcing canonical cross-chain
///         position identity binding, EIP-712 / ERC-1271 owner delegation, explicit default-owner policy,
///         replay protection via nonces, and pause orthogonality.
/// @dev Default-Owner Policy:
///      - Before any callback, a user may claim their own same-wallet position via `registerPosition(salt)`
///        (`originUser == msg.sender == destinationOwner`) or delegate any wallet on Unichain Sepolia via
///        `registerPositionWithAuthorization(...)` signed by `originUser` (EOA ECDSA or ERC-1271).
///      - If an authenticated `RiskBreach` callback (`pauseBorrowing`) arrives for an unregistered position,
///        origin identity is bound and `positionOwners[positionId]` defaults strictly to `message.originUser`.
///      - An unregistered `RiskResolved` callback (`resolveBorrowing`) verifies canonical identity and initializes
///        only origin identity metadata while keeping `positionOwners[positionId] == address(0)` so a resolution
///        event can never grant ownership or overwrite an existing owner.
contract BorrowingController is IBorrowingController, EIP712, Ownable {
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
    error UntrustedOriginDomain(uint256 chainId, address riskController, address vault);
    error PositionIdMismatch(bytes32 providedPositionId, bytes32 derivedPositionId);
    error PositionIdentityConflict(bytes32 positionId, address existingOriginUser, address incomingOriginUser);
    error AuthorizationExpired(uint256 deadline, uint256 currentTimestamp);
    error InvalidAuthorizationSignature();
    error InvalidIdentityVersion(uint8 version);
    error IdentityNotConfigured();

    event CallbackAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    bytes32 public constant AUTHORIZE_POSITION_TYPEHASH = keccak256(
        "AuthorizePosition(bytes32 positionId,uint256 originChainId,address originRiskController,address originVault,address originUser,bytes32 salt,address destinationOwner,uint256 nonce,uint256 deadline)"
    );
    uint8 public constant IDENTITY_VERSION = CrossGuardIdentity.IDENTITY_VERSION;
    bytes32 public constant IDENTITY_DOMAIN = CrossGuardIdentity.POSITION_IDENTITY_DOMAIN;

    uint256 public immutable override trustedOriginChainId;
    address public immutable override trustedOriginRiskController;
    address public immutable override trustedOriginVault;

    address public callbackAdapter;
    mapping(bytes32 => address) public override positionOwners;
    mapping(bytes32 => address) public override originUsers;
    mapping(bytes32 => bytes32) public override originIdentityHashes;
    mapping(bytes32 => uint8) public override positionIdentityVersion;
    mapping(address => uint256) public override sigNonces;

    mapping(bytes32 => bool) public override isBorrowingPaused;
    mapping(bytes32 => bool) public override pausedByRiskBreach;
    mapping(bytes32 => bool) public override pausedByAdmin;
    mapping(bytes32 => uint256) public override lastProcessedNonce;
    mapping(bytes32 => uint256) public override lastRiskBreachTimestamp;
    mapping(bytes32 => uint256) public positionBorrowDebt;

    modifier onlyCallbackAdapter() {
        if (msg.sender != callbackAdapter) {
            revert UnauthorizedCallback(msg.sender);
        }
        _;
    }

    constructor(
        address initialOwner,
        uint256 _trustedOriginChainId,
        address _trustedOriginRiskController,
        address _trustedOriginVault
    ) EIP712("CrossGuardBorrowingController", "1") Ownable(initialOwner) {
        if (_trustedOriginChainId == 0) revert CrossGuardIdentity.InvalidOriginChainId();
        if (_trustedOriginRiskController == address(0) || _trustedOriginVault == address(0)) {
            revert ZeroAddress();
        }
        trustedOriginChainId = _trustedOriginChainId;
        trustedOriginRiskController = _trustedOriginRiskController;
        trustedOriginVault = _trustedOriginVault;
    }

    /// @notice Sets the authorized cross-chain callback adapter.
    function setCallbackAdapter(address _callbackAdapter) external onlyOwner {
        if (_callbackAdapter == address(0)) revert ZeroAddress();
        address oldAdapter = callbackAdapter;
        callbackAdapter = _callbackAdapter;
        emit CallbackAdapterUpdated(oldAdapter, _callbackAdapter);
    }

    /// @notice Read-only canonical PositionID computation using the trusted origin domain.
    function computePositionId(address originUser, bytes32 salt) external view override returns (bytes32) {
        return CrossGuardIdentity.computePositionId(
            trustedOriginChainId, trustedOriginRiskController, trustedOriginVault, originUser, salt
        );
    }

    /// @notice Read-only helper returning the exact EIP-712 digest expected for delegated registration.
    function computeAuthorizePositionDigest(
        CrossGuardIdentity.OriginIdentity calldata identity,
        address destinationOwner,
        uint256 sigNonce,
        uint256 deadline
    ) public view override returns (bytes32) {
        bytes32 positionId = CrossGuardIdentity.computePositionId(
            identity.originChainId,
            identity.originRiskController,
            identity.originVault,
            identity.originUser,
            identity.salt
        );
        bytes32 structHash = keccak256(
            abi.encode(
                AUTHORIZE_POSITION_TYPEHASH,
                positionId,
                identity.originChainId,
                identity.originRiskController,
                identity.originVault,
                identity.originUser,
                identity.salt,
                destinationOwner,
                sigNonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    /// @notice Same-wallet origin-user registration (`originUser == msg.sender == destinationOwner`).
    /// @dev Prevents squatting because msg.sender itself forms the canonical positionId preimage.
    function registerPosition(bytes32 salt) external override returns (bytes32 positionId) {
        _requireTrustedOriginConfigured();
        positionId = CrossGuardIdentity.computePositionId(
            trustedOriginChainId, trustedOriginRiskController, trustedOriginVault, msg.sender, salt
        );
        _bindExplicitRegistration(positionId, msg.sender, msg.sender);
    }

    /// @notice Registers a position for an explicitly authorized destinationOwner via EIP-712 / ERC-1271 signature
    ///         signed by the originUser. Relayer-submittable without allowing owner substitution.
    function registerPositionWithAuthorization(
        CrossGuardIdentity.OriginIdentity calldata identity,
        address destinationOwner,
        uint256 deadline,
        bytes calldata signature
    ) external override returns (bytes32 positionId) {
        _requireTrustedOriginConfigured();
        if (destinationOwner == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert AuthorizationExpired(deadline, block.timestamp);
        if (
            identity.originChainId != trustedOriginChainId
                || identity.originRiskController != trustedOriginRiskController
                || identity.originVault != trustedOriginVault
        ) {
            revert UntrustedOriginDomain(identity.originChainId, identity.originRiskController, identity.originVault);
        }

        positionId = CrossGuardIdentity.computePositionId(
            identity.originChainId,
            identity.originRiskController,
            identity.originVault,
            identity.originUser,
            identity.salt
        );

        uint256 currentNonce = sigNonces[identity.originUser];
        bytes32 digest = computeAuthorizePositionDigest(identity, destinationOwner, currentNonce, deadline);

        if (!SignatureChecker.isValidSignatureNow(identity.originUser, digest, signature)) {
            revert InvalidAuthorizationSignature();
        }

        sigNonces[identity.originUser] = currentNonce + 1;
        _bindExplicitRegistration(positionId, identity.originUser, destinationOwner);
        emit PositionAuthorizationConsumed(positionId, identity.originUser, destinationOwner, currentNonce);
    }

    /// @notice Pauses borrowing for a position upon receiving an authenticated identity-bound risk breach callback.
    function pauseBorrowing(CrossGuardIdentity.RiskCallbackMessage calldata message)
        external
        override
        onlyCallbackAdapter
    {
        bytes32 positionId = _validateCallbackIdentity(message);

        uint256 lastNonce = lastProcessedNonce[positionId];
        if (message.nonce <= lastNonce) {
            revert InvalidNonce(message.nonce, lastNonce);
        }

        _reconcileCallbackIdentity(positionId, message.originUser, true);

        lastProcessedNonce[positionId] = message.nonce;
        lastRiskBreachTimestamp[positionId] = message.timestamp;
        isBorrowingPaused[positionId] = true;
        pausedByRiskBreach[positionId] = true;

        emit BorrowingPaused(positionId, message.nonce, message.riskLevel, message.timestamp);
    }

    /// @notice Resumes borrowing for a position upon receiving an authenticated identity-bound risk resolution callback.
    /// @dev Preserves existing destination owners and never grants ownership on unregistered positions.
    function resolveBorrowing(CrossGuardIdentity.RiskCallbackMessage calldata message)
        external
        override
        onlyCallbackAdapter
    {
        bytes32 positionId = _validateCallbackIdentity(message);

        uint256 lastNonce = lastProcessedNonce[positionId];
        if (message.nonce <= lastNonce) {
            revert InvalidNonce(message.nonce, lastNonce);
        }

        _reconcileCallbackIdentity(positionId, message.originUser, false);

        lastProcessedNonce[positionId] = message.nonce;
        pausedByRiskBreach[positionId] = false;

        if (!pausedByAdmin[positionId]) {
            if (isBorrowingPaused[positionId]) {
                isBorrowingPaused[positionId] = false;
                emit BorrowingResumed(positionId);
            }
        }

        emit RiskBreachResolved(positionId, message.nonce, message.riskLevel, message.timestamp);
    }

    /// @notice Separate administrative emergency circuit breaker to pause borrowing.
    function emergencyPauseBorrowing(bytes32 positionId) external override onlyOwner {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        pausedByAdmin[positionId] = true;
        isBorrowingPaused[positionId] = true;
        emit EmergencyBorrowingPaused(positionId);
    }

    /// @notice Resumes borrowing for an administratively paused position (cannot bypass active risk breaches).
    function resumeBorrowing(bytes32 positionId) external override onlyOwner {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        if (pausedByRiskBreach[positionId]) {
            revert CannotBypassActiveRiskBreach(positionId);
        }
        if (!pausedByAdmin[positionId]) {
            revert PositionNotPaused(positionId);
        }
        pausedByAdmin[positionId] = false;
        isBorrowingPaused[positionId] = false;
        emit BorrowingResumed(positionId);
    }

    /// @notice Emergency administrative override to resume borrowing with explicit audit justification.
    function emergencyResumeBorrowing(bytes32 positionId, string calldata reason) external override onlyOwner {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        if (bytes(reason).length == 0) revert EmptyEmergencyReason();
        if (!isBorrowingPaused[positionId]) revert PositionNotPaused(positionId);

        isBorrowingPaused[positionId] = false;
        pausedByRiskBreach[positionId] = false;
        pausedByAdmin[positionId] = false;

        emit EmergencyBorrowingResumed(positionId, msg.sender, reason, block.timestamp);
        emit BorrowingResumed(positionId);
    }

    /// @notice Executes borrowing strictly by the registered destination owner while unpaused.
    function borrow(bytes32 positionId, uint256 amount) external override {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        address posOwner = positionOwners[positionId];
        if (posOwner == address(0) || positionIdentityVersion[positionId] == 0) {
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

    function _requireTrustedOriginConfigured() internal view {
        if (trustedOriginChainId == 0 || trustedOriginRiskController == address(0) || trustedOriginVault == address(0))
        {
            revert IdentityNotConfigured();
        }
    }

    function _bindExplicitRegistration(bytes32 positionId, address originUser, address destinationOwner) internal {
        if (positionOwners[positionId] != address(0)) {
            revert PositionAlreadyRegistered(positionId);
        }

        uint8 existingVer = positionIdentityVersion[positionId];
        if (existingVer != 0) {
            // Position origin identity was previously initialized (e.g., via out-of-order RiskResolved);
            // strictly verify exact canonical origin identity match before binding owner.
            if (originIdentityHashes[positionId] != positionId || originUsers[positionId] != originUser) {
                revert PositionIdentityConflict(positionId, originUsers[positionId], originUser);
            }
        } else {
            originUsers[positionId] = originUser;
            originIdentityHashes[positionId] = positionId;
            positionIdentityVersion[positionId] = IDENTITY_VERSION;
            emit PositionIdentityInitialized(positionId, originUser, positionId, IDENTITY_VERSION);
        }

        positionOwners[positionId] = destinationOwner;
        emit PositionRegistered(positionId, originUser, destinationOwner, positionId);
    }

    function _validateCallbackIdentity(CrossGuardIdentity.RiskCallbackMessage calldata message)
        internal
        view
        returns (bytes32 positionId)
    {
        _requireTrustedOriginConfigured();
        if (message.identityVersion != IDENTITY_VERSION) {
            revert InvalidIdentityVersion(message.identityVersion);
        }
        if (message.positionId == bytes32(0)) {
            revert InvalidPositionId();
        }
        if (
            message.originChainId != trustedOriginChainId || message.originRiskController != trustedOriginRiskController
                || message.originVault != trustedOriginVault
        ) {
            revert UntrustedOriginDomain(message.originChainId, message.originRiskController, message.originVault);
        }

        bytes32 derivedId = CrossGuardIdentity.computePositionId(
            message.originChainId, message.originRiskController, message.originVault, message.originUser, message.salt
        );
        if (derivedId != message.positionId) {
            revert PositionIdMismatch(message.positionId, derivedId);
        }

        return message.positionId;
    }

    function _reconcileCallbackIdentity(bytes32 positionId, address incomingOriginUser, bool allowDefaultOwnerBinding)
        internal
    {
        uint8 existingVer = positionIdentityVersion[positionId];
        if (existingVer == 0) {
            originUsers[positionId] = incomingOriginUser;
            originIdentityHashes[positionId] = positionId;
            positionIdentityVersion[positionId] = IDENTITY_VERSION;
            emit PositionIdentityInitialized(positionId, incomingOriginUser, positionId, IDENTITY_VERSION);

            if (allowDefaultOwnerBinding) {
                positionOwners[positionId] = incomingOriginUser;
                emit PositionRegistered(positionId, incomingOriginUser, incomingOriginUser, positionId);
            }
        } else {
            if (
                existingVer != IDENTITY_VERSION || originIdentityHashes[positionId] != positionId
                    || originUsers[positionId] != incomingOriginUser
            ) {
                revert PositionIdentityConflict(positionId, originUsers[positionId], incomingOriginUser);
            }

            if (allowDefaultOwnerBinding && positionOwners[positionId] == address(0)) {
                positionOwners[positionId] = incomingOriginUser;
                emit PositionRegistered(positionId, incomingOriginUser, incomingOriginUser, positionId);
            }
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "../interfaces/ISystemContract.sol";
import {ICrossGuardCallback} from "../interfaces/ICrossGuardCallback.sol";
import {CrossGuardIdentity} from "../libraries/CrossGuardIdentity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CrossGuardReactive
/// @notice Autonomous Reactive Contract deployed on Reactive Lasna (5318007).
///         Intercepts M007.1 versioned identity-bound RiskBreach and RiskResolved events on Base Sepolia (84532),
///         independently recomputes canonical positionId before dispatch, carries full origin identity in callbacks,
///         and preserves M006 durable pending dispatch and bounded recovery semantics.
contract CrossGuardReactive is IReactive, Ownable {
    error ZeroAddress();
    error UnauthorizedCaller(address caller);
    error UnsupportedChainId(uint256 chainId);
    error InvalidGasLimit(uint64 gasLimit);
    error InvalidPositionId();
    error NoCallbackPayloadStored(bytes32 positionId);
    error NonceMismatch(uint256 expectedNonce, uint256 actualNonce);
    error RetryLimitExceeded(bytes32 positionId, uint8 currentRetries, uint8 maxRetries);
    error DestinationNotConfigured();
    error InvalidReasonCode();
    error DispatchNotPending();
    error CallbackNotRequested();
    error InvalidCallbackType();

    address public constant OMNI_SYSTEM_CONTRACT = 0x8888888888888888888888888888888888888888;
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint64 public constant MIN_CALLBACK_GAS_LIMIT = 100_000;
    uint8 public constant MAX_RETRIES = 3;
    uint8 public constant IDENTITY_VERSION = CrossGuardIdentity.IDENTITY_VERSION;
    bytes32 public constant IDENTITY_DOMAIN = CrossGuardIdentity.POSITION_IDENTITY_DOMAIN;

    enum CallbackType {
        NONE,
        BREACH,
        RESOLVED
    }

    enum DispatchStatus {
        NONE,
        PENDING_DISPATCH,
        REQUESTED
    }

    struct CallbackState {
        uint256 nonce;
        CallbackType eventType;
        bytes payload;
        uint8 retryCount;
        DispatchStatus status;
    }

    bytes32 public constant RISK_BREACH_TOPIC_0 =
        keccak256("RiskBreach(bytes32,address,uint256,uint8,address,bytes32,uint256,uint256,uint256)");
    bytes32 public constant RISK_RESOLVED_TOPIC_0 =
        keccak256("RiskResolved(bytes32,address,uint256,uint8,address,bytes32,uint256,uint256,uint256)");

    ISystemContract public systemContract;
    uint256 public originChainId;
    address public originRiskController;
    address public originCollateralVault;
    uint256 public destinationChainId;
    address public destinationCallback;
    uint64 public callbackGasLimit;

    uint256 public reactCount;
    mapping(bytes32 => uint256) public latestOriginNonce;
    mapping(bytes32 => CallbackState) public latestCallback;

    event DestinationConfigUpdated(uint256 chainId, address callbackContract, uint64 gasLimit);
    event ReactiveBreachProcessed(
        bytes32 indexed positionId, uint256 indexed nonce, uint256 riskLevel, uint256 timestamp
    );
    event ReactiveResolvedProcessed(
        bytes32 indexed positionId, uint256 indexed nonce, uint256 riskLevel, uint256 timestamp
    );
    event ReactiveEventRejected(
        bytes32 indexed topic0, bytes32 indexed positionId, uint256 indexed nonce, string reason
    );
    event StaleOriginEventIgnored(bytes32 indexed positionId, uint256 receivedNonce, uint256 latestNonce);
    event CallbackDispatchDeferred(
        bytes32 indexed positionId, uint256 indexed nonce, CallbackType indexed eventType, string reason
    );
    event CallbackDispatchSubmitted(bytes32 indexed positionId, uint256 indexed nonce, CallbackType indexed eventType);
    event PendingCallbackSuperseded(bytes32 indexed positionId, uint256 indexed oldNonce, uint256 indexed newNonce);
    event CallbackRetryRequested(
        bytes32 indexed positionId, uint256 indexed nonce, uint8 retryAttempt, bytes32 reasonCode
    );

    modifier onlySystem() {
        if (msg.sender != address(systemContract)) {
            revert UnauthorizedCaller(msg.sender);
        }
        _;
    }

    constructor(
        address initialOwner,
        address _systemContract,
        uint256 _originChainId,
        address _originRiskController,
        address _originCollateralVault,
        uint256 _destChainId,
        address _destCallback,
        uint64 _gasLimit
    ) Ownable(initialOwner) {
        if (_originRiskController == address(0) || _originCollateralVault == address(0)) {
            revert ZeroAddress();
        }
        if (_originChainId != BASE_SEPOLIA_CHAIN_ID) {
            revert UnsupportedChainId(_originChainId);
        }

        if (_destCallback != address(0)) {
            if (_destChainId != UNICHAIN_SEPOLIA_CHAIN_ID) {
                revert UnsupportedChainId(_destChainId);
            }
            if (_gasLimit < MIN_CALLBACK_GAS_LIMIT) {
                revert InvalidGasLimit(_gasLimit);
            }
        } else {
            if (_destChainId != 0 && _destChainId != UNICHAIN_SEPOLIA_CHAIN_ID) {
                revert UnsupportedChainId(_destChainId);
            }
            if (_gasLimit != 0 && _gasLimit < MIN_CALLBACK_GAS_LIMIT) {
                revert InvalidGasLimit(_gasLimit);
            }
        }

        address sysAddr = _systemContract == address(0) ? OMNI_SYSTEM_CONTRACT : _systemContract;
        systemContract = ISystemContract(payable(sysAddr));

        originChainId = _originChainId;
        originRiskController = _originRiskController;
        originCollateralVault = _originCollateralVault;
        destinationChainId = _destCallback == address(0) ? 0 : _destChainId;
        destinationCallback = _destCallback;
        callbackGasLimit = _destCallback == address(0) ? 0 : _gasLimit;

        systemContract.subscribe(
            _originChainId,
            _originRiskController,
            uint256(RISK_BREACH_TOPIC_0),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        systemContract.subscribe(
            _originChainId,
            _originRiskController,
            uint256(RISK_RESOLVED_TOPIC_0),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Read-only canonical PositionID helper using configured origin domain.
    function computeCanonicalPositionId(address originUser, bytes32 salt) external view returns (bytes32) {
        return CrossGuardIdentity.computePositionId(
            originChainId, originRiskController, originCollateralVault, originUser, salt
        );
    }

    /// @notice Updates destination callback configuration strictly within MVP supported topology.
    function setDestinationConfig(uint256 _destChainId, address _destCallback, uint64 _gasLimit) external onlyOwner {
        if (_destCallback == address(0)) revert ZeroAddress();
        if (_destChainId != UNICHAIN_SEPOLIA_CHAIN_ID) revert UnsupportedChainId(_destChainId);
        if (_gasLimit < MIN_CALLBACK_GAS_LIMIT) revert InvalidGasLimit(_gasLimit);

        destinationChainId = _destChainId;
        destinationCallback = _destCallback;
        callbackGasLimit = _gasLimit;

        emit DestinationConfigUpdated(_destChainId, _destCallback, _gasLimit);
    }

    /// @notice Core reactive execution entry point called strictly by the Reactive Network Omni System Contract.
    function react(LogRecord calldata log) external override onlySystem {
        reactCount++;

        bytes32 topic0 = bytes32(log.topic_0);
        bytes32 positionId = bytes32(log.topic_1);
        uint256 nonce = log.topic_3;

        // 1. Authenticated Origin Chain ID validation
        if (log.chain_id != originChainId) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "WRONG_CHAIN_ID");
            return;
        }

        // 2. Authenticated Origin Emitter validation
        if (log._contract != originRiskController) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "WRONG_EMITTER");
            return;
        }

        // 3. Versioned Topic 0 validation
        bool isBreach = (topic0 == RISK_BREACH_TOPIC_0);
        bool isResolved = (topic0 == RISK_RESOLVED_TOPIC_0);
        if (!isBreach && !isResolved) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "WRONG_EVENT_TOPIC");
            return;
        }

        // 4. Indexed Position ID validation
        if (positionId == bytes32(0)) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "ZERO_POSITION_ID");
            return;
        }

        // 5. Indexed Origin User validation (clean 20-byte ABI padding, non-zero)
        // forge-lint: disable-next-line(unsafe-typecast)
        address originUser = address(uint160(log.topic_2));
        if ((log.topic_2 >> 160) != 0 || originUser == address(0)) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "INVALID_INDEXED_USER");
            return;
        }

        // 6. Indexed Nonce validation
        if (nonce == 0) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "ZERO_NONCE");
            return;
        }

        // 7. Exact Event Data Length: 6 ABI words = 192 bytes
        //    (uint8 identityVersion, address originVault, bytes32 positionSalt, uint256 ltvBps, uint256 thresholdBps, uint256 timestamp)
        bytes calldata rawData = log.data;
        if (rawData.length != 192) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "INVALID_DATA_LENGTH");
            return;
        }

        // 8. Canonical upper-bit checks for uint8 version and address originVault
        uint256 versionWord;
        uint256 vaultWord;
        assembly {
            versionWord := calldataload(rawData.offset)
            vaultWord := calldataload(add(rawData.offset, 32))
        }
        if ((versionWord >> 8) != 0 || (vaultWord >> 160) != 0) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "MALFORMED_EVENT_DATA");
            return;
        }

        (
            uint8 idVersion,
            address evVault,
            bytes32 salt,
            uint256 currentLtvBps,
            uint256 riskThresholdBps,
            uint256 timestamp
        ) = abi.decode(rawData, (uint8, address, bytes32, uint256, uint256, uint256));

        // 9. Identity version & configured vault & salt checks
        if (idVersion != IDENTITY_VERSION) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "UNSUPPORTED_IDENTITY_VERSION");
            return;
        }
        if (evVault == address(0) || evVault != originCollateralVault) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "UNAUTHORIZED_ORIGIN_VAULT");
            return;
        }
        if (salt == bytes32(0)) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "INVALID_SALT");
            return;
        }

        // 10. Canonical PositionID derivation check from authenticated source metadata + event evidence
        (bool idValid, bytes32 expectedPositionId) =
            CrossGuardIdentity.tryComputePositionId(log.chain_id, log._contract, evVault, originUser, salt);
        if (!idValid || expectedPositionId != positionId) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "POSITION_ID_MISMATCH");
            return;
        }

        // 11. Threshold, timestamp, and risk evaluation semantics
        if (riskThresholdBps == 0 || riskThresholdBps > 10_000) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "INVALID_THRESHOLD");
            return;
        }
        if (timestamp == 0) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "INVALID_TIMESTAMP");
            return;
        }
        if (isBreach) {
            if (currentLtvBps < riskThresholdBps) {
                emit ReactiveEventRejected(topic0, positionId, nonce, "BREACH_BELOW_THRESHOLD");
                return;
            }
        } else {
            if (currentLtvBps >= riskThresholdBps) {
                emit ReactiveEventRejected(topic0, positionId, nonce, "RESOLVED_NOT_BELOW_THRESHOLD");
                return;
            }
        }

        // 12. Monotonic Nonce Ordering Guard
        if (nonce <= latestOriginNonce[positionId]) {
            emit StaleOriginEventIgnored(positionId, nonce, latestOriginNonce[positionId]);
            emit ReactiveEventRejected(topic0, positionId, nonce, "STALE_OR_DUPLICATE_NONCE");
            return;
        }

        // 13. Check supersede status
        CallbackState storage existing = latestCallback[positionId];
        if (existing.status == DispatchStatus.PENDING_DISPATCH) {
            emit PendingCallbackSuperseded(positionId, existing.nonce, nonce);
        }

        // 14. Build identity-bearing destination callback payload (first arg reserved for proxy rvmSender injection)
        CallbackType cType = isBreach ? CallbackType.BREACH : CallbackType.RESOLVED;
        CrossGuardIdentity.RiskCallbackMessage memory msgData = CrossGuardIdentity.RiskCallbackMessage({
            identityVersion: idVersion,
            originChainId: log.chain_id,
            originRiskController: log._contract,
            originVault: evVault,
            originUser: originUser,
            positionId: positionId,
            salt: salt,
            nonce: nonce,
            riskLevel: currentLtvBps,
            timestamp: timestamp
        });
        bytes memory payload = isBreach
            ? abi.encodeCall(ICrossGuardCallback.handleRiskBreach, (address(0), msgData))
            : abi.encodeCall(ICrossGuardCallback.handleRiskResolved, (address(0), msgData));

        latestOriginNonce[positionId] = nonce;
        latestCallback[positionId] = CallbackState({
            nonce: nonce, eventType: cType, payload: payload, retryCount: 0, status: DispatchStatus.PENDING_DISPATCH
        });

        bool isDestConfigured =
            (destinationCallback != address(0) && destinationChainId == UNICHAIN_SEPOLIA_CHAIN_ID
                && callbackGasLimit >= MIN_CALLBACK_GAS_LIMIT);

        if (!isDestConfigured) {
            emit CallbackDispatchDeferred(positionId, nonce, cType, "DESTINATION_NOT_CONFIGURED");
            return;
        }

        latestCallback[positionId].status = DispatchStatus.REQUESTED;

        if (isBreach) {
            emit ReactiveBreachProcessed(positionId, nonce, currentLtvBps, timestamp);
        } else {
            emit ReactiveResolvedProcessed(positionId, nonce, currentLtvBps, timestamp);
        }

        systemContract.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: destinationCallback,
                gasLimit: callbackGasLimit,
                payload: payload
            })
        );
    }

    /// @notice Allows owner to dispatch a valid pending origin event whose initial dispatch was deferred.
    function dispatchPendingCallback(bytes32 positionId, uint256 expectedNonce) external onlyOwner {
        if (positionId == bytes32(0)) revert InvalidPositionId();

        CallbackState storage state = latestCallback[positionId];
        if (state.nonce == 0 || state.payload.length == 0) revert NoCallbackPayloadStored(positionId);
        if (state.nonce != expectedNonce) revert NonceMismatch(expectedNonce, state.nonce);
        if (state.eventType != CallbackType.BREACH && state.eventType != CallbackType.RESOLVED) {
            revert InvalidCallbackType();
        }
        if (state.status != DispatchStatus.PENDING_DISPATCH) revert DispatchNotPending();

        if (
            destinationCallback == address(0) || destinationChainId != UNICHAIN_SEPOLIA_CHAIN_ID
                || callbackGasLimit < MIN_CALLBACK_GAS_LIMIT
        ) {
            revert DestinationNotConfigured();
        }

        state.status = DispatchStatus.REQUESTED;

        emit CallbackDispatchSubmitted(positionId, state.nonce, state.eventType);

        systemContract.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: destinationCallback,
                gasLimit: callbackGasLimit,
                payload: state.payload
            })
        );
    }

    /// @notice Allows owner to retry a confirmed failed callback preserving exact original identity and payload.
    function retryFailedCallback(bytes32 positionId, uint256 expectedNonce, bytes32 reasonCode) external onlyOwner {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        if (reasonCode == bytes32(0)) revert InvalidReasonCode();

        CallbackState storage state = latestCallback[positionId];
        if (state.nonce == 0 || state.payload.length == 0) revert NoCallbackPayloadStored(positionId);
        if (state.nonce != expectedNonce) revert NonceMismatch(expectedNonce, state.nonce);
        if (state.eventType != CallbackType.BREACH && state.eventType != CallbackType.RESOLVED) {
            revert InvalidCallbackType();
        }
        if (state.status != DispatchStatus.REQUESTED) revert CallbackNotRequested();
        if (state.retryCount >= MAX_RETRIES) revert RetryLimitExceeded(positionId, state.retryCount, MAX_RETRIES);

        if (
            destinationCallback == address(0) || destinationChainId != UNICHAIN_SEPOLIA_CHAIN_ID
                || callbackGasLimit < MIN_CALLBACK_GAS_LIMIT
        ) {
            revert DestinationNotConfigured();
        }

        state.retryCount++;

        emit CallbackRetryRequested(positionId, state.nonce, state.retryCount, reasonCode);

        systemContract.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: destinationCallback,
                gasLimit: callbackGasLimit,
                payload: state.payload
            })
        );
    }

    /// @notice Returns the latest stored callback state for a position.
    function getLatestCallback(bytes32 positionId)
        external
        view
        returns (uint256 nonce, CallbackType eventType, bytes memory payload, uint8 retryCount, DispatchStatus status)
    {
        CallbackState memory state = latestCallback[positionId];
        return (state.nonce, state.eventType, state.payload, state.retryCount, state.status);
    }

    /// @notice Allows owner to withdraw any accidentally sent native tokens.
    function withdraw(address payable recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        (bool success,) = recipient.call{value: amount}("");
        require(success, "Withdraw failed");
    }

    /// @notice Required IPayer interface stub (no-op for modern Omni).
    function pay(uint256) external pure override {
        revert("Not implemented");
    }

    /// @notice Allows contract to receive funds if needed for execution reserves.
    receive() external payable {}
}

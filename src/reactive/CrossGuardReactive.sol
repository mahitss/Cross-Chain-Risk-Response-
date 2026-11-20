// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "../interfaces/ISystemContract.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CrossGuardReactive
/// @notice Autonomous Reactive Contract deployed on Reactive Lasna (5318007).
///         Uses current Reactive Omni system interface (0x8888888888888888888888888888888888888888)
///         to intercept RiskBreach and RiskResolved events on Base Sepolia (84532) and request callbacks
///         to Unichain Sepolia (1301).
///         Enforces single authoritative risk policy from origin, strict event payload integrity,
///         and supported-chain topology allowlisting.
contract CrossGuardReactive is IReactive, Ownable {
    error ZeroAddress();
    error UnauthorizedCaller(address caller);
    error UnsupportedChainId(uint256 chainId);
    error InvalidGasLimit(uint64 gasLimit);

    address public constant OMNI_SYSTEM_CONTRACT = 0x8888888888888888888888888888888888888888;
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    bytes32 public constant RISK_BREACH_TOPIC_0 =
        keccak256("RiskBreach(bytes32,address,uint256,uint256,uint256,uint256)");
    bytes32 public constant RISK_RESOLVED_TOPIC_0 =
        keccak256("RiskResolved(bytes32,address,uint256,uint256,uint256,uint256)");

    ISystemContract public systemContract;
    uint256 public originChainId;
    address public originRiskController;
    uint256 public destinationChainId;
    address public destinationCallback;
    uint64 public callbackGasLimit;

    uint256 public reactCount;

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
        uint256 _destChainId,
        address _destCallback,
        uint64 _gasLimit
    ) Ownable(initialOwner) {
        if (_originRiskController == address(0)) {
            revert ZeroAddress();
        }
        if (_originChainId != BASE_SEPOLIA_CHAIN_ID) {
            revert UnsupportedChainId(_originChainId);
        }

        if (_destCallback != address(0)) {
            if (_destChainId != UNICHAIN_SEPOLIA_CHAIN_ID) {
                revert UnsupportedChainId(_destChainId);
            }
            if (_gasLimit == 0) {
                revert InvalidGasLimit(0);
            }
        } else {
            // Stage 1 of two-stage deployment: destCallback is address(0)
            if (_destChainId != 0 && _destChainId != UNICHAIN_SEPOLIA_CHAIN_ID) {
                revert UnsupportedChainId(_destChainId);
            }
        }

        address sysAddr = _systemContract == address(0) ? OMNI_SYSTEM_CONTRACT : _systemContract;
        systemContract = ISystemContract(payable(sysAddr));

        originChainId = _originChainId;
        originRiskController = _originRiskController;
        destinationChainId = _destCallback == address(0) ? 0 : _destChainId;
        destinationCallback = _destCallback;
        callbackGasLimit = _destCallback == address(0) ? 0 : _gasLimit;

        // 1. Subscribe to RiskBreach events on origin
        systemContract.subscribe(
            _originChainId,
            _originRiskController,
            uint256(RISK_BREACH_TOPIC_0),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        // 2. Subscribe to RiskResolved events on origin
        systemContract.subscribe(
            _originChainId,
            _originRiskController,
            uint256(RISK_RESOLVED_TOPIC_0),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Updates destination callback configuration strictly within MVP supported topology.
    function setDestinationConfig(uint256 _destChainId, address _destCallback, uint64 _gasLimit) external onlyOwner {
        if (_destCallback == address(0)) revert ZeroAddress();
        if (_destChainId != UNICHAIN_SEPOLIA_CHAIN_ID) revert UnsupportedChainId(_destChainId);
        if (_gasLimit == 0) revert InvalidGasLimit(0);

        destinationChainId = _destChainId;
        destinationCallback = _destCallback;
        callbackGasLimit = _gasLimit;

        emit DestinationConfigUpdated(_destChainId, _destCallback, _gasLimit);
    }

    /// @notice Core reactive execution entry point called strictly by the Reactive Network Omni System Contract.
    /// @param log Event log data intercepted from origin chain.
    function react(LogRecord calldata log) external override onlySystem {
        reactCount++;

        bytes32 topic0 = bytes32(log.topic_0);
        bytes32 positionId = bytes32(log.topic_1);
        uint256 nonce = log.topic_3;

        // 1. Origin Chain ID validation
        if (log.chain_id != originChainId) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "WRONG_CHAIN_ID");
            return;
        }

        // 2. Origin Emitter validation
        if (log._contract != originRiskController) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "WRONG_EMITTER");
            return;
        }

        // 3. Destination Configuration check (fail-closed if unconfigured)
        if (
            destinationCallback == address(0) || destinationChainId != UNICHAIN_SEPOLIA_CHAIN_ID
                || callbackGasLimit == 0
        ) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "DESTINATION_NOT_CONFIGURED");
            return;
        }

        // 4. Topic 0 validation (must be either RiskBreach or RiskResolved)
        bool isBreach = (topic0 == RISK_BREACH_TOPIC_0);
        bool isResolved = (topic0 == RISK_RESOLVED_TOPIC_0);

        if (!isBreach && !isResolved) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "WRONG_EVENT_TOPIC");
            return;
        }

        // 5. Indexed Position ID validation
        if (positionId == bytes32(0)) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "ZERO_POSITION_ID");
            return;
        }

        // 6. Indexed User Address validation (upper 12 bytes must be 0, address non-zero)
        // forge-lint: disable-next-line(unsafe-typecast)
        if ((log.topic_2 >> 160) != 0 || address(uint160(log.topic_2)) == address(0)) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "INVALID_INDEXED_USER");
            return;
        }

        // 7. Indexed Nonce validation (RiskController nonces start at 1)
        if (nonce == 0) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "ZERO_NONCE");
            return;
        }

        // 8. Event Data Length validation: exactly 3 ABI-encoded uint256 words = 96 bytes
        // (currentLtvBps, riskThresholdBps, timestamp)
        if (log.data.length != 96) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "INVALID_DATA_LENGTH");
            return;
        }

        (uint256 currentLtvBps, uint256 riskThresholdBps, uint256 timestamp) =
            abi.decode(log.data, (uint256, uint256, uint256));

        // 9. Threshold range validation (1 bps to 10,000 bps)
        if (riskThresholdBps == 0 || riskThresholdBps > 10_000) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "INVALID_THRESHOLD");
            return;
        }

        // 10. Timestamp validation
        if (timestamp == 0) {
            emit ReactiveEventRejected(topic0, positionId, nonce, "INVALID_TIMESTAMP");
            return;
        }

        // 11. Semantic validation of risk evaluation
        if (isBreach) {
            // For a breach, current LTV must be >= threshold
            if (currentLtvBps < riskThresholdBps) {
                emit ReactiveEventRejected(topic0, positionId, nonce, "BREACH_BELOW_THRESHOLD");
                return;
            }

            bytes memory payload = abi.encodeWithSignature(
                "handleRiskBreach(address,bytes32,uint256,uint256,uint256)",
                address(0),
                positionId,
                nonce,
                currentLtvBps,
                timestamp
            );

            emit ReactiveBreachProcessed(positionId, nonce, currentLtvBps, timestamp);

            systemContract.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: destinationChainId,
                    recipient: destinationCallback,
                    gasLimit: callbackGasLimit,
                    payload: payload
                })
            );
        } else {
            // For resolution, current LTV must be < threshold
            if (currentLtvBps >= riskThresholdBps) {
                emit ReactiveEventRejected(topic0, positionId, nonce, "RESOLVED_NOT_BELOW_THRESHOLD");
                return;
            }

            bytes memory payload = abi.encodeWithSignature(
                "handleRiskResolved(address,bytes32,uint256,uint256,uint256)",
                address(0),
                positionId,
                nonce,
                currentLtvBps,
                timestamp
            );

            emit ReactiveResolvedProcessed(positionId, nonce, currentLtvBps, timestamp);

            systemContract.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: destinationChainId,
                    recipient: destinationCallback,
                    gasLimit: callbackGasLimit,
                    payload: payload
                })
            );
        }
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

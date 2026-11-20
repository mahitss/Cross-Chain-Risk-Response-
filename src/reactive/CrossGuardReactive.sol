// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "../interfaces/ISystemContract.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CrossGuardReactive
/// @notice Autonomous Reactive Contract deployed on Reactive Lasna (5318007).
///         Uses current Reactive Omni system interface (0x8888888888888888888888888888888888888888)
///         to detect RiskBreach on Base Sepolia (84532) and request callback to Unichain Sepolia (1301).
///         The origin RiskController is the sole authoritative policy engine for risk decisions.
contract CrossGuardReactive is IReactive, Ownable {
    error ZeroAddress();
    error UnauthorizedCaller(address caller);
    error InvalidChainId(uint256 chainId);
    error InvalidGasLimit(uint64 gasLimit);

    address public constant OMNI_SYSTEM_CONTRACT = 0x8888888888888888888888888888888888888888;
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

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
        if (_originChainId == 0) {
            revert InvalidChainId(0);
        }
        if (_destCallback != address(0)) {
            if (_destChainId == 0) {
                revert InvalidChainId(0);
            }
            if (_gasLimit == 0) {
                revert InvalidGasLimit(0);
            }
        }

        address sysAddr = _systemContract == address(0) ? OMNI_SYSTEM_CONTRACT : _systemContract;
        systemContract = ISystemContract(payable(sysAddr));

        originChainId = _originChainId;
        originRiskController = _originRiskController;
        destinationChainId = _destChainId;
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

    /// @notice Updates destination callback configuration.
    function setDestinationConfig(uint256 _destChainId, address _destCallback, uint64 _gasLimit) external onlyOwner {
        if (_destCallback == address(0)) revert ZeroAddress();
        if (_destChainId == 0) revert InvalidChainId(0);
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

        // 1. Verify origin chain and emitter contract
        if (log.chain_id != originChainId || log._contract != originRiskController) {
            return;
        }

        // 2. Ensure destination callback is configured
        if (destinationCallback == address(0) || destinationChainId == 0 || callbackGasLimit == 0) {
            return;
        }

        bytes32 positionId = bytes32(log.topic_1);
        uint256 nonce = log.topic_3;

        // 3. Handle RiskBreach event
        if (log.topic_0 == uint256(RISK_BREACH_TOPIC_0)) {
            (uint256 currentLtvBps,, uint256 timestamp) = abi.decode(log.data, (uint256, uint256, uint256));

            // Origin RiskController is the sole authority for threshold breach decisions.
            // Valid origin RiskBreach events are dispatched unconditionally to destination.

            // Build destination callback payload for pause
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
        }
        // 4. Handle RiskResolved event
        else if (log.topic_0 == uint256(RISK_RESOLVED_TOPIC_0)) {
            (uint256 currentLtvBps,, uint256 timestamp) = abi.decode(log.data, (uint256, uint256, uint256));

            // Build destination callback payload for resolution
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

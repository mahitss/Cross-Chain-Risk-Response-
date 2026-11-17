// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CrossGuardReactive
/// @notice Autonomous Reactive Contract deployed on Reactive Lasna (5318007).
///         Detects RiskBreach on Base Sepolia (84532) and dispatches callback to Unichain Sepolia (1301).
contract CrossGuardReactive is IReactive, AbstractReactive, Ownable {
    error ZeroAddress();
    error UnauthorizedCaller(address caller);
    error InvalidChainId(uint256 chainId);

    bytes32 public constant RISK_BREACH_TOPIC_0 = keccak256("RiskBreach(bytes32,address,uint256,uint256,uint256)");

    uint256 public originChainId;
    address public originRiskController;
    uint256 public destinationChainId;
    address public destinationCallback;
    uint64 public callbackGasLimit;
    uint256 public minRiskThresholdBps;

    uint256 public reactCount;

    event DestinationConfigUpdated(uint256 chainId, address callbackContract, uint64 gasLimit);
    event MinRiskThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event ReactiveBreachProcessed(bytes32 indexed positionId, uint256 riskLevel, uint256 timestamp);

    modifier vmOrServiceOnly() {
        if (address(SERVICE_ADDR).code.length > 0) {
            if (msg.sender != address(SERVICE_ADDR) && msg.sender != address(vendor)) {
                revert UnauthorizedCaller(msg.sender);
            }
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
        uint64 _gasLimit,
        uint256 _minRiskThresholdBps
    ) Ownable(initialOwner) {
        if (_originRiskController == address(0) || _destCallback == address(0)) {
            revert ZeroAddress();
        }
        if (_originChainId == 0 || _destChainId == 0) {
            revert InvalidChainId(0);
        }

        originChainId = _originChainId;
        originRiskController = _originRiskController;
        destinationChainId = _destChainId;
        destinationCallback = _destCallback;
        callbackGasLimit = _gasLimit > 0 ? _gasLimit : 300_000;
        minRiskThresholdBps = _minRiskThresholdBps;

        // If a specific system contract address is provided, override default SERVICE_ADDR
        if (_systemContract != address(0)) {
            service = ISystemContract(payable(_systemContract));
            vendor = service;
            addAuthorizedSender(_systemContract);
        }

        // Subscribe on top-level network (or local mock environment)
        if (address(service).code.length > 0) {
            service.subscribe(
                _originChainId,
                _originRiskController,
                uint256(RISK_BREACH_TOPIC_0),
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    /// @notice Updates destination callback configuration.
    function setDestinationConfig(
        uint256 _destChainId,
        address _destCallback,
        uint64 _gasLimit
    ) external onlyOwner {
        if (_destCallback == address(0)) revert ZeroAddress();
        if (_destChainId == 0) revert InvalidChainId(0);

        destinationChainId = _destChainId;
        destinationCallback = _destCallback;
        callbackGasLimit = _gasLimit;

        emit DestinationConfigUpdated(_destChainId, _destCallback, _gasLimit);
    }

    /// @notice Updates minimum risk threshold filter.
    function setMinRiskThresholdBps(uint256 _newThresholdBps) external onlyOwner {
        uint256 old = minRiskThresholdBps;
        minRiskThresholdBps = _newThresholdBps;
        emit MinRiskThresholdUpdated(old, _newThresholdBps);
    }

    /// @notice Core reactive execution entry point called by the Reactive Network runtime.
    /// @param log Event log data intercepted from origin chain.
    function react(LogRecord calldata log) external override vmOrServiceOnly {
        reactCount++;

        // 1. Verify origin chain and emitter contract
        if (log.chain_id != originChainId || log._contract != originRiskController) {
            return;
        }

        // 2. Verify event topic
        if (log.topic_0 != uint256(RISK_BREACH_TOPIC_0)) {
            return;
        }

        // 3. Extract indexed positionId and event parameters
        bytes32 positionId = bytes32(log.topic_1);
        (uint256 currentLtvBps, , uint256 timestamp) = abi.decode(log.data, (uint256, uint256, uint256));

        // 4. Verify risk threshold
        if (currentLtvBps < minRiskThresholdBps) {
            return;
        }

        // 5. Build destination callback payload
        // The first argument `address(0)` is replaced by Reactive Network with the deployer RVM ID
        bytes memory payload = abi.encodeWithSignature(
            "handleRiskBreach(address,bytes32,uint256,uint256)",
            address(0),
            positionId,
            currentLtvBps,
            timestamp
        );

        emit ReactiveBreachProcessed(positionId, currentLtvBps, timestamp);

        // 6. Emit cross-chain Callback
        emit Callback(destinationChainId, destinationCallback, callbackGasLimit, payload);
    }
}

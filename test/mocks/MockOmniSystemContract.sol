// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {ISystemContract} from "../../src/interfaces/ISystemContract.sol";

/// @title MockOmniSystemContract
/// @notice Simulates the Reactive Omni System Contract (0x8888888888888888888888888888888888888888)
///         handling both subscription registry and requestCallbackV_1_0 tracking.
contract MockOmniSystemContract is ISystemContract {
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    struct Subscription {
        uint256 chainId;
        address contractAddr;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        address subscriber;
    }

    Subscription[] public subscriptions;
    CallbackConfiguration_V_1_0[] public requestedCallbacks;

    event CallbackRequestedV1(uint256 indexed chainId, address indexed recipient, uint64 gasLimit, bytes payload);

    function subscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external override {
        subscriptions.push(
            Subscription({
                chainId: chain_id,
                contractAddr: _contract,
                topic0: topic_0,
                topic1: topic_1,
                topic2: topic_2,
                topic3: topic_3,
                subscriber: msg.sender
            })
        );
    }

    function unsubscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external override {
        uint256 len = subscriptions.length;
        for (uint256 i = 0; i < len; i++) {
            Subscription storage sub = subscriptions[i];
            if (
                sub.subscriber == msg.sender && sub.chainId == chain_id && sub.contractAddr == _contract
                    && sub.topic0 == topic_0 && sub.topic1 == topic_1 && sub.topic2 == topic_2 && sub.topic3 == topic_3
            ) {
                subscriptions[i] = subscriptions[len - 1];
                subscriptions.pop();
                return;
            }
        }
        revert("MockOmniSystemContract: subscription not found");
    }

    function requestCallback(CallbackVersion, bytes memory config_) external override {
        CallbackConfiguration_V_1_0 memory cfg = abi.decode(config_, (CallbackConfiguration_V_1_0));
        requestedCallbacks.push(cfg);
        emit CallbackRequestedV1(cfg.chainId, cfg.recipient, cfg.gasLimit, cfg.payload);
    }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external virtual override {
        requestedCallbacks.push(config_);
        emit CallbackRequestedV1(config_.chainId, config_.recipient, config_.gasLimit, config_.payload);
    }

    function requestedCallbackCount() external view returns (uint256) {
        return requestedCallbacks.length;
    }

    function getLastRequestedCallback() external view returns (CallbackConfiguration_V_1_0 memory) {
        require(requestedCallbacks.length > 0, "No callbacks requested");
        return requestedCallbacks[requestedCallbacks.length - 1];
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}

    function getMatchingSubscribers(
        uint256 chainId,
        address contractAddr,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external view returns (address[] memory) {
        uint256 len = subscriptions.length;
        uint256 count = 0;
        for (uint256 i = 0; i < len; i++) {
            if (_matches(subscriptions[i], chainId, contractAddr, topic0, topic1, topic2, topic3)) {
                count++;
            }
        }

        address[] memory result = new address[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < len; i++) {
            if (_matches(subscriptions[i], chainId, contractAddr, topic0, topic1, topic2, topic3)) {
                result[idx++] = subscriptions[i].subscriber;
            }
        }
        return result;
    }

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function _matches(
        Subscription storage sub,
        uint256 chainId,
        address contractAddr,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) internal view returns (bool) {
        if (sub.chainId != 0 && sub.chainId != chainId) return false;
        if (sub.contractAddr != address(0) && sub.contractAddr != contractAddr) return false;
        if (sub.topic0 != REACTIVE_IGNORE && sub.topic0 != topic0) return false;
        if (sub.topic1 != REACTIVE_IGNORE && sub.topic1 != topic1) return false;
        if (sub.topic2 != REACTIVE_IGNORE && sub.topic2 != topic2) return false;
        if (sub.topic3 != REACTIVE_IGNORE && sub.topic3 != topic3) return false;
        return true;
    }
}

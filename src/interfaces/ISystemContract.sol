// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

/// @title ISystemContract
/// @notice Official Reactive Network Omni System Contract interface at 0x8888888888888888888888888888888888888888.
interface ISystemContract {
    enum CallbackVersion {
        V_1_0
    }

    struct CallbackConfiguration_V_1_0 {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    /// @notice Subscribes to events matching criteria on an origin chain.
    function subscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;

    /// @notice Removes an active subscription matching the criteria.
    function unsubscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;

    /// @notice Dispatches an authenticated cross-chain callback via Omni System Contract.
    function requestCallback(CallbackVersion version_, bytes memory config_) external;

    /// @notice Dispatches an authenticated cross-chain callback using version 1.0 configuration.
    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external;
}

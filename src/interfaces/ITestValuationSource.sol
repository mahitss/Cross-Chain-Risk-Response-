// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

/// @title ITestValuationSource
/// @notice Interface for mock pricing oracle used in test lending facilities.
interface ITestValuationSource {
    event PriceUpdated(address indexed asset, uint256 oldPrice, uint256 newPrice, uint256 timestamp);

    function setAssetPrice(address asset, uint256 price) external;
    function getAssetPrice(address asset) external view returns (uint256);
}

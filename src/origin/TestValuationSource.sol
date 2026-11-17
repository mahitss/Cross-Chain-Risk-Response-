// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ITestValuationSource} from "../interfaces/ITestValuationSource.sol";

/// @title TestValuationSource
/// @notice Configurable test valuation oracle for simulating market volatility and liquidations.
contract TestValuationSource is ITestValuationSource, Ownable {
    error ZeroPrice();
    error AssetPriceNotSet(address asset);

    mapping(address => uint256) private _prices;

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Sets or updates the mock price for an asset.
    /// @param asset Asset address (e.g. mock collateral token).
    /// @param price Asset price in USD (scaled to 1e8).
    function setAssetPrice(address asset, uint256 price) external override onlyOwner {
        if (price == 0) revert ZeroPrice();
        uint256 oldPrice = _prices[asset];
        _prices[asset] = price;
        emit PriceUpdated(asset, oldPrice, price, block.timestamp);
    }

    /// @notice Returns the recorded price for an asset.
    /// @param asset Asset address.
    function getAssetPrice(address asset) external view override returns (uint256) {
        uint256 price = _prices[asset];
        if (price == 0) revert AssetPriceNotSet(asset);
        return price;
    }
}

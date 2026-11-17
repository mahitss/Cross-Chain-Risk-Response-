// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRiskController} from "../interfaces/IRiskController.sol";

/// @title RiskController
/// @notice Evaluates loan-to-value (LTV) health metrics and triggers canonical RiskBreach events on Base Sepolia.
contract RiskController is IRiskController, Ownable {
    error UnauthorizedVault(address caller);
    error InvalidThreshold(uint256 thresholdBps);

    event AuthorizedVaultUpdated(address indexed vault, bool authorized);
    uint256 public constant BPS_SCALE = 10_000;
    uint256 public override riskThresholdBps;

    mapping(address => bool) public authorizedVaults;

    modifier onlyAuthorizedVault() {
        if (!authorizedVaults[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedVault(msg.sender);
        }
        _;
    }

    constructor(address initialOwner, uint256 initialThresholdBps) Ownable(initialOwner) {
        if (initialThresholdBps == 0 || initialThresholdBps > BPS_SCALE) {
            revert InvalidThreshold(initialThresholdBps);
        }
        riskThresholdBps = initialThresholdBps;
    }

    /// @notice Configures authorized caller vault contracts.
    function setAuthorizedVault(address vault, bool authorized) external onlyOwner {
        authorizedVaults[vault] = authorized;
        emit AuthorizedVaultUpdated(vault, authorized);
    }

    /// @notice Updates the maximum safe risk threshold.
    /// @param newThresholdBps New threshold in basis points (e.g. 8000 = 80%).
    function setRiskThreshold(uint256 newThresholdBps) external override onlyOwner {
        if (newThresholdBps == 0 || newThresholdBps > BPS_SCALE) {
            revert InvalidThreshold(newThresholdBps);
        }
        uint256 oldThreshold = riskThresholdBps;
        riskThresholdBps = newThresholdBps;
        emit RiskThresholdUpdated(oldThreshold, newThresholdBps);
    }

    /// @notice Evaluates position risk and emits RiskBreach if LTV exceeds policy threshold.
    function assessRisk(
        bytes32 positionId,
        address user,
        uint256 collateralValueUsd,
        uint256 debtValueUsd
    ) external override onlyAuthorizedVault returns (bool isBreached, uint256 currentLtvBps) {
        if (collateralValueUsd == 0) {
            currentLtvBps = debtValueUsd > 0 ? BPS_SCALE : 0;
        } else {
            currentLtvBps = (debtValueUsd * BPS_SCALE) / collateralValueUsd;
        }

        if (currentLtvBps >= riskThresholdBps) {
            isBreached = true;
            emit RiskBreach(positionId, user, currentLtvBps, riskThresholdBps, block.timestamp);
        } else {
            isBreached = false;
        }
    }
}

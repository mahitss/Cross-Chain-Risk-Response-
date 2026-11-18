// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRiskController} from "../interfaces/IRiskController.sol";

/// @title RiskController
/// @notice Evaluates loan-to-value (LTV) health metrics and triggers canonical RiskBreach events on Base Sepolia.
contract RiskController is IRiskController, Ownable {
    error UnauthorizedVault(address caller);
    error InvalidThreshold(uint256 thresholdBps);

    uint256 public constant BPS_SCALE = 10_000;
    uint256 public constant MIN_VALID_THRESHOLD_BPS = 1;
    uint256 public constant MAX_VALID_THRESHOLD_BPS = 10_000;

    uint256 public override riskThresholdBps;
    mapping(bytes32 => uint256) public override positionNonce;
    mapping(address => bool) public authorizedVaults;

    modifier onlyAuthorizedVault() {
        if (!authorizedVaults[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedVault(msg.sender);
        }
        _;
    }

    constructor(address initialOwner, uint256 initialThresholdBps) Ownable(initialOwner) {
        if (initialThresholdBps < MIN_VALID_THRESHOLD_BPS || initialThresholdBps > MAX_VALID_THRESHOLD_BPS) {
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
    /// @param newThresholdBps New threshold in basis points (1 - 10,000).
    function setRiskThreshold(uint256 newThresholdBps) external override onlyOwner {
        if (newThresholdBps < MIN_VALID_THRESHOLD_BPS || newThresholdBps > MAX_VALID_THRESHOLD_BPS) {
            revert InvalidThreshold(newThresholdBps);
        }
        uint256 oldThreshold = riskThresholdBps;
        riskThresholdBps = newThresholdBps;
        emit RiskThresholdUpdated(oldThreshold, newThresholdBps);
    }

    /// @notice Evaluates position risk and emits RiskBreach with monotonic nonce if LTV exceeds policy threshold.
    function assessRisk(bytes32 positionId, address user, uint256 collateralValueUsd, uint256 debtValueUsd)
        external
        override
        onlyAuthorizedVault
        returns (bool isBreached, uint256 currentLtvBps, uint256 nonce)
    {
        if (collateralValueUsd == 0) {
            currentLtvBps = debtValueUsd > 0 ? BPS_SCALE : 0;
        } else {
            currentLtvBps = (debtValueUsd * BPS_SCALE) / collateralValueUsd;
        }

        if (currentLtvBps >= riskThresholdBps) {
            isBreached = true;
            nonce = ++positionNonce[positionId];
            emit RiskBreach(positionId, user, nonce, currentLtvBps, riskThresholdBps, block.timestamp);
        } else {
            isBreached = false;
            nonce = positionNonce[positionId];
        }
    }
}

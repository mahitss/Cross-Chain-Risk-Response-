// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRiskController} from "../interfaces/IRiskController.sol";

/// @title RiskController
/// @notice Evaluates loan-to-value (LTV) health metrics and triggers canonical RiskBreach and RiskResolved events on Base Sepolia.
/// @dev Canonical Fixed-Point Calculation & Decimal Conventions:
///      - Token Balances: 18 decimals (1e18)
///      - Oracle Asset Prices: 8 decimals (1e8)
///      - Position Valuations (USD): 8 decimals (1e8)
///      - LTV Scale: Basis points (10,000 = 100.00%)
///      - Zero Collateral & Zero Debt: LTV = 0 bps (Healthy)
///      - Zero Collateral & Positive Debt: LTV = 10,000 bps (Max risk / Breached)
///      - Positive Collateral & Zero Debt: LTV = 0 bps (Healthy)
///      - Full 512-bit intermediate math: (debtValueUsd * BPS_SCALE) / collateralValueUsd
///      - Unrepresentable quotients (> type(uint256).max) deterministically return type(uint256).max.
contract RiskController is IRiskController, Ownable {
    error ZeroAddress();
    error UnauthorizedVault(address caller);
    error InvalidThreshold(uint256 thresholdBps);

    uint256 public constant BPS_SCALE = 10_000;
    uint256 public constant MIN_VALID_THRESHOLD_BPS = 1;
    uint256 public constant MAX_VALID_THRESHOLD_BPS = 10_000;

    uint256 public override riskThresholdBps;
    mapping(bytes32 => uint256) public override positionNonce;
    mapping(bytes32 => bool) public override isPositionBreached;
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
        if (vault == address(0)) revert ZeroAddress();
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

    /// @notice Canonical fixed-point LTV calculation in basis points (10,000 = 100%).
    /// @dev Full-precision 512-bit calculation: (debtValueUsd * BPS_SCALE) / collateralValueUsd.
    ///      Quotients exceeding type(uint256).max deterministically return type(uint256).max.
    /// @param collateralValueUsd Position collateral valuation in USD (8 decimals).
    /// @param debtValueUsd Position debt valuation in USD (8 decimals).
    /// @return Calculated LTV in basis points.
    function calculateLtvBps(uint256 collateralValueUsd, uint256 debtValueUsd) public pure override returns (uint256) {
        if (debtValueUsd == 0) {
            return 0;
        }
        if (collateralValueUsd == 0) {
            return BPS_SCALE;
        }

        // Full-precision 512-bit product [prod1, prod0] = debtValueUsd * BPS_SCALE
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(debtValueUsd, BPS_SCALE, not(0))
            prod0 := mul(debtValueUsd, BPS_SCALE)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        // If quotient exceeds type(uint256).max, deterministically cap at type(uint256).max
        if (prod1 >= collateralValueUsd) {
            return type(uint256).max;
        }

        // Exact 512 by 256 division
        return Math.mulDiv(debtValueUsd, BPS_SCALE, collateralValueUsd);
    }

    /// @notice Evaluates position risk and emits RiskBreach (or RiskResolved on recovery) with monotonic nonce.
    /// @dev Only authorized vaults or owner can trigger risk assessment.
    function assessRisk(bytes32 positionId, address user, uint256 collateralValueUsd, uint256 debtValueUsd)
        external
        override
        onlyAuthorizedVault
        returns (bool isBreached, uint256 currentLtvBps, uint256 nonce)
    {
        currentLtvBps = calculateLtvBps(collateralValueUsd, debtValueUsd);

        if (currentLtvBps >= riskThresholdBps) {
            isBreached = true;
            isPositionBreached[positionId] = true;
            nonce = ++positionNonce[positionId];
            emit RiskBreach(positionId, user, nonce, currentLtvBps, riskThresholdBps, block.timestamp);
        } else {
            isBreached = false;
            if (isPositionBreached[positionId]) {
                // State Transition: Breached -> Healthy (Recovery lifecycle)
                isPositionBreached[positionId] = false;
                nonce = ++positionNonce[positionId];
                emit RiskResolved(positionId, user, nonce, currentLtvBps, riskThresholdBps, block.timestamp);
            } else {
                nonce = positionNonce[positionId];
            }
        }
    }
}

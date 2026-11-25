// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRiskController} from "../interfaces/IRiskController.sol";
import {CrossGuardIdentity} from "../libraries/CrossGuardIdentity.sol";

/// @title RiskController
/// @notice Evaluates loan-to-value (LTV) health metrics and emits versioned identity-bound
///         RiskBreach and RiskResolved events on Base Sepolia (84532).
/// @dev Canonical Fixed-Point Calculation & Decimal Conventions:
///      - Token Balances: 18 decimals (1e18)
///      - Oracle Asset Prices: 8 decimals (1e8)
///      - Position Valuations (USD): 8 decimals (1e8)
///      - LTV Scale: Basis points (10,000 = 100.00%)
///      - Full 512-bit intermediate math: (debtValueUsd * BPS_SCALE) / collateralValueUsd
contract RiskController is IRiskController, Ownable {
    error ZeroAddress();
    error InvalidPositionId();
    error UnauthorizedVault(address caller);
    error InvalidThreshold(uint256 thresholdBps);
    error PositionIdMismatch(bytes32 providedPositionId, bytes32 expectedPositionId);
    error PositionIdentityAlreadyRegistered(bytes32 positionId);
    error PositionIdentityNotRegistered(bytes32 positionId);
    error VaultIdentityMismatch(address callerVault, address registeredVault);
    error OriginUserMismatch(address providedUser, address registeredUser);
    error InvalidOriginIdentityDomain();

    uint256 public constant BPS_SCALE = 10_000;
    uint256 public constant MIN_VALID_THRESHOLD_BPS = 1;
    uint256 public constant MAX_VALID_THRESHOLD_BPS = 10_000;
    uint8 public constant IDENTITY_VERSION = CrossGuardIdentity.IDENTITY_VERSION;
    bytes32 public constant IDENTITY_DOMAIN = CrossGuardIdentity.POSITION_IDENTITY_DOMAIN;

    uint256 public override riskThresholdBps;
    mapping(bytes32 => uint256) public override positionNonce;
    mapping(bytes32 => bool) public override isPositionBreached;
    mapping(address => bool) public authorizedVaults;
    mapping(bytes32 => bool) public override positionIdentityRegistered;
    mapping(bytes32 => CrossGuardIdentity.OriginIdentity) private _positionIdentities;

    modifier onlyAuthorizedVault() {
        if (!authorizedVaults[msg.sender]) {
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

    /// @notice Registers immutable canonical origin position identity for an initialized vault position.
    /// @dev Callable strictly by authorized vaults. Identity cannot be changed once committed and
    ///      never resets or mutates existing risk nonces.
    function registerPositionIdentity(bytes32 positionId, address originUser, bytes32 salt)
        external
        override
        onlyAuthorizedVault
    {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        if (positionIdentityRegistered[positionId]) {
            revert PositionIdentityAlreadyRegistered(positionId);
        }

        bytes32 expectedId =
            CrossGuardIdentity.computePositionId(block.chainid, address(this), msg.sender, originUser, salt);
        if (expectedId != positionId) {
            revert PositionIdMismatch(positionId, expectedId);
        }

        _positionIdentities[positionId] = CrossGuardIdentity.OriginIdentity({
            originChainId: block.chainid,
            originRiskController: address(this),
            originVault: msg.sender,
            originUser: originUser,
            salt: salt
        });
        positionIdentityRegistered[positionId] = true;

        emit PositionIdentityRegistered(positionId, block.chainid, address(this), msg.sender, originUser, salt);
    }

    /// @notice Evaluates position risk and emits versioned identity-bound RiskBreach or RiskResolved events.
    /// @dev Strictly validates that calling vault and user match immutable canonical position identity.
    function assessRisk(bytes32 positionId, address user, uint256 collateralValueUsd, uint256 debtValueUsd)
        external
        override
        onlyAuthorizedVault
        returns (bool isBreached, uint256 currentLtvBps, uint256 nonce)
    {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        if (!positionIdentityRegistered[positionId]) {
            revert PositionIdentityNotRegistered(positionId);
        }

        CrossGuardIdentity.OriginIdentity storage id = _positionIdentities[positionId];
        if (id.originVault != msg.sender) {
            revert VaultIdentityMismatch(msg.sender, id.originVault);
        }
        if (id.originUser != user) {
            revert OriginUserMismatch(user, id.originUser);
        }
        if (id.originChainId != block.chainid || id.originRiskController != address(this)) {
            revert InvalidOriginIdentityDomain();
        }
        if (
            CrossGuardIdentity.computePositionId(
                    id.originChainId, id.originRiskController, id.originVault, id.originUser, id.salt
                ) != positionId
        ) {
            revert InvalidPositionId();
        }

        currentLtvBps = calculateLtvBps(collateralValueUsd, debtValueUsd);

        if (currentLtvBps >= riskThresholdBps) {
            isBreached = true;
            if (!isPositionBreached[positionId]) {
                isPositionBreached[positionId] = true;
                nonce = ++positionNonce[positionId];
                emit RiskBreach(
                    positionId,
                    user,
                    nonce,
                    IDENTITY_VERSION,
                    id.originVault,
                    id.salt,
                    currentLtvBps,
                    riskThresholdBps,
                    block.timestamp
                );
            } else {
                nonce = positionNonce[positionId];
            }
        } else {
            isBreached = false;
            if (isPositionBreached[positionId]) {
                isPositionBreached[positionId] = false;
                nonce = ++positionNonce[positionId];
                emit RiskResolved(
                    positionId,
                    user,
                    nonce,
                    IDENTITY_VERSION,
                    id.originVault,
                    id.salt,
                    currentLtvBps,
                    riskThresholdBps,
                    block.timestamp
                );
            } else {
                nonce = positionNonce[positionId];
            }
        }
    }

    /// @notice Read-only canonical PositionID derivation helper for this RiskController domain.
    function computePositionId(address originVault, address originUser, bytes32 salt)
        external
        view
        override
        returns (bytes32)
    {
        return CrossGuardIdentity.computePositionId(block.chainid, address(this), originVault, originUser, salt);
    }

    /// @notice Returns the stored immutable origin identity tuple for a registered position.
    function getPositionIdentity(bytes32 positionId)
        external
        view
        override
        returns (CrossGuardIdentity.OriginIdentity memory)
    {
        return _positionIdentities[positionId];
    }

    /// @notice Canonical fixed-point LTV calculation in basis points (10,000 = 100%).
    function calculateLtvBps(uint256 collateralValueUsd, uint256 debtValueUsd) public pure override returns (uint256) {
        if (debtValueUsd == 0) {
            return 0;
        }
        if (collateralValueUsd == 0) {
            return BPS_SCALE;
        }

        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(debtValueUsd, BPS_SCALE, not(0))
            prod0 := mul(debtValueUsd, BPS_SCALE)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        if (prod1 >= collateralValueUsd) {
            return type(uint256).max;
        }

        return Math.mulDiv(debtValueUsd, BPS_SCALE, collateralValueUsd);
    }
}

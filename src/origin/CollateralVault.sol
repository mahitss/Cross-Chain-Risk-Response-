// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {ITestValuationSource} from "../interfaces/ITestValuationSource.sol";
import {IRiskController} from "../interfaces/IRiskController.sol";
import {CrossGuardIdentity} from "../libraries/CrossGuardIdentity.sol";

/// @title CollateralVault
/// @notice Controlled test vault managing user collateral and loan positions on Base Sepolia (84532)
///         with canonical domain-separated position identity derivation.
/// @dev Eliminates arbitrary positionId squatting: new positions can only be initialized via
///      openPosition(salt, asset, amount), which binds positionId to msg.sender and this vault's domain.
contract CollateralVault is ICollateralVault, Ownable {
    error ZeroAmount();
    error ZeroAddress();
    error InvalidPositionId();
    error UnauthorizedUser(address caller, address positionOwner);
    error PositionAlreadyExists(bytes32 positionId);
    error PositionNotInitialized();
    error AssetMismatch(address provided, address expected);
    error PositionInBreachedState(bytes32 positionId);
    error PositionUnsafeOrBreached(bytes32 positionId, uint256 projectedLtvBps, uint256 thresholdBps);
    error PositionUncollateralized(bytes32 positionId);

    struct Position {
        address user;
        address collateralAsset;
        uint256 collateralAmount;
        address debtAsset;
        uint256 debtAmount;
    }

    event ValuationSourceUpdated(address indexed oldOracle, address indexed newOracle);

    uint8 public constant IDENTITY_VERSION = CrossGuardIdentity.IDENTITY_VERSION;
    bytes32 public constant IDENTITY_DOMAIN = CrossGuardIdentity.POSITION_IDENTITY_DOMAIN;

    ITestValuationSource public valuationSource;
    /// @notice Authoritative risk controller, configured immutably at deployment to preserve breach state continuity.
    IRiskController public immutable riskController;

    mapping(bytes32 => Position) private _positions;
    mapping(bytes32 => CrossGuardIdentity.OriginIdentity) private _positionIdentities;
    mapping(bytes32 => address) public override positionCollateralAsset;
    mapping(bytes32 => address) public override positionDebtAsset;

    constructor(address initialOwner, address _valuationSource, address _riskController) Ownable(initialOwner) {
        if (_valuationSource == address(0) || _riskController == address(0)) {
            revert ZeroAddress();
        }
        valuationSource = ITestValuationSource(_valuationSource);
        riskController = IRiskController(_riskController);
    }

    /// @notice Updates the valuation oracle address.
    function setValuationSource(address _newOracle) external onlyOwner {
        if (_newOracle == address(0)) revert ZeroAddress();
        address oldOracle = address(valuationSource);
        valuationSource = ITestValuationSource(_newOracle);
        emit ValuationSourceUpdated(oldOracle, _newOracle);
    }

    /// @notice Read-only helper calculating canonical position ID before position creation.
    function computePositionId(address originUser, bytes32 salt) public view override returns (bytes32) {
        return
            CrossGuardIdentity.computePositionId(
                block.chainid, address(riskController), address(this), originUser, salt
            );
    }

    /// @notice Creates a new position whose canonical positionId is deterministically derived from
    ///         (DOMAIN, chainid, riskController, vault, msg.sender, salt), preventing arbitrary ID claiming.
    function openPosition(bytes32 salt, address asset, uint256 amount) external override returns (bytes32 positionId) {
        if (amount == 0) revert ZeroAmount();
        if (asset == address(0)) revert ZeroAddress();

        positionId = CrossGuardIdentity.computePositionId(
            block.chainid, address(riskController), address(this), msg.sender, salt
        );

        Position storage pos = _positions[positionId];
        if (pos.user != address(0)) {
            revert PositionAlreadyExists(positionId);
        }

        pos.user = msg.sender;
        pos.collateralAsset = asset;
        pos.collateralAmount = amount;
        positionCollateralAsset[positionId] = asset;

        _positionIdentities[positionId] = CrossGuardIdentity.OriginIdentity({
            originChainId: block.chainid,
            originRiskController: address(riskController),
            originVault: address(this),
            originUser: msg.sender,
            salt: salt
        });

        riskController.registerPositionIdentity(positionId, msg.sender, salt);

        emit PositionOpened(positionId, msg.sender, salt, asset, amount);
        emit CollateralDeposited(positionId, msg.sender, asset, amount);
    }

    /// @notice Adds collateral into an already initialized canonical position owned by msg.sender.
    /// @dev Does NOT create positions or allow claiming unregistered position IDs.
    function depositCollateral(bytes32 positionId, address asset, uint256 amount) external override {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        if (amount == 0) revert ZeroAmount();
        if (asset == address(0)) revert ZeroAddress();

        Position storage pos = _positions[positionId];
        if (pos.user == address(0)) revert PositionNotInitialized();
        if (pos.user != msg.sender) {
            revert UnauthorizedUser(msg.sender, pos.user);
        }

        address expectedAsset = positionCollateralAsset[positionId];
        if (expectedAsset != asset) {
            revert AssetMismatch(asset, expectedAsset);
        }

        pos.collateralAmount += amount;
        emit CollateralDeposited(positionId, pos.user, asset, amount);
    }

    /// @notice Records new borrowing against a canonical position owned by msg.sender.
    function recordBorrow(bytes32 positionId, address asset, uint256 amount) external override {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        if (amount == 0) revert ZeroAmount();
        if (asset == address(0)) revert ZeroAddress();

        Position storage pos = _positions[positionId];
        if (pos.user == address(0)) revert PositionNotInitialized();
        if (pos.user != msg.sender) {
            revert UnauthorizedUser(msg.sender, pos.user);
        }

        address expectedAsset = positionDebtAsset[positionId];
        if (expectedAsset == address(0)) {
            positionDebtAsset[positionId] = asset;
            pos.debtAsset = asset;
        } else if (expectedAsset != asset) {
            revert AssetMismatch(asset, expectedAsset);
        }

        if (riskController.isPositionBreached(positionId)) {
            revert PositionInBreachedState(positionId);
        }

        if (pos.collateralAmount == 0) {
            revert PositionUncollateralized(positionId);
        }

        uint256 collateralPrice = valuationSource.getAssetPrice(pos.collateralAsset);
        uint256 debtPrice = valuationSource.getAssetPrice(asset);

        uint256 collateralValueUsd = _computeValuationUsd(pos.collateralAmount, collateralPrice);
        uint256 projectedDebtAmount = pos.debtAmount + amount;
        uint256 projectedDebtValueUsd = _computeValuationUsd(projectedDebtAmount, debtPrice);

        uint256 projectedLtv = riskController.calculateLtvBps(collateralValueUsd, projectedDebtValueUsd);
        uint256 threshold = riskController.riskThresholdBps();
        if (projectedLtv >= threshold) {
            revert PositionUnsafeOrBreached(positionId, projectedLtv, threshold);
        }

        pos.debtAmount = projectedDebtAmount;
        emit BorrowRecorded(positionId, pos.user, asset, amount);
    }

    /// @notice Evaluates position health and triggers identity-attested RiskBreach / RiskResolved via RiskController.
    function evaluatePositionRisk(bytes32 positionId)
        external
        override
        returns (bool isBreached, uint256 ltvBps, uint256 nonce)
    {
        if (positionId == bytes32(0)) revert InvalidPositionId();
        Position storage pos = _positions[positionId];
        if (pos.user == address(0)) revert PositionNotInitialized();

        CrossGuardIdentity.OriginIdentity storage id = _positionIdentities[positionId];
        if (
            CrossGuardIdentity.computePositionId(
                    id.originChainId, id.originRiskController, id.originVault, id.originUser, id.salt
                ) != positionId
        ) {
            revert InvalidPositionId();
        }

        uint256 collateralPrice = pos.collateralAmount > 0 ? valuationSource.getAssetPrice(pos.collateralAsset) : 0;
        uint256 debtPrice = pos.debtAmount > 0 ? valuationSource.getAssetPrice(pos.debtAsset) : 0;

        uint256 collateralValueUsd = _computeValuationUsd(pos.collateralAmount, collateralPrice);
        uint256 debtValueUsd = _computeValuationUsd(pos.debtAmount, debtPrice);

        (isBreached, ltvBps, nonce) = riskController.assessRisk(positionId, pos.user, collateralValueUsd, debtValueUsd);

        emit PositionEvaluated(positionId, collateralValueUsd, debtValueUsd, ltvBps, nonce, isBreached);
    }

    /// @dev Computes full-precision USD valuation in 8 decimals: (amount * price) / 1e18.
    function _computeValuationUsd(uint256 amount, uint256 price) internal pure returns (uint256) {
        if (amount == 0 || price == 0) return 0;

        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(amount, price, not(0))
            prod0 := mul(amount, price)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        if (prod1 >= 1e18) {
            return type(uint256).max;
        }

        return Math.mulDiv(amount, price, 1e18);
    }

    /// @notice Returns the immutable stored origin identity tuple for a position.
    function getPositionIdentity(bytes32 positionId)
        external
        view
        override
        returns (CrossGuardIdentity.OriginIdentity memory)
    {
        return _positionIdentities[positionId];
    }

    /// @notice Returns position financial details.
    function getPosition(bytes32 positionId)
        external
        view
        override
        returns (address user, address collateralAsset, uint256 collateralAmount, address debtAsset, uint256 debtAmount)
    {
        Position storage pos = _positions[positionId];
        return (pos.user, pos.collateralAsset, pos.collateralAmount, pos.debtAsset, pos.debtAmount);
    }
}

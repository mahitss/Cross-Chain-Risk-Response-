// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

/// @title CrossGuardIdentity
/// @notice Shared canonical position identity derivation and validation library for CrossGuard M007.1.
/// @dev PositionID = keccak256(abi.encode(POSITION_IDENTITY_DOMAIN, originChainId, originRiskController, originVault, originUser, salt)).
library CrossGuardIdentity {
    uint8 internal constant IDENTITY_VERSION = 1;
    bytes32 internal constant POSITION_IDENTITY_DOMAIN = keccak256("CROSSGUARD_POSITION_IDENTITY_V1");

    error ZeroAddress();
    error InvalidOriginChainId();
    error InvalidSalt();
    error InvalidPositionId();
    error InvalidIdentityVersion(uint8 version);

    struct OriginIdentity {
        uint256 originChainId;
        address originRiskController;
        address originVault;
        address originUser;
        bytes32 salt;
    }

    struct RiskCallbackMessage {
        uint8 identityVersion;
        uint256 originChainId;
        address originRiskController;
        address originVault;
        address originUser;
        bytes32 positionId;
        bytes32 salt;
        uint256 nonce;
        uint256 riskLevel;
        uint256 timestamp;
    }

    /// @notice Validates that all fields in an origin identity tuple are strictly well-formed and non-zero.
    function validateIdentityFields(
        uint256 originChainId,
        address originRiskController,
        address originVault,
        address originUser,
        bytes32 salt
    ) internal pure {
        if (originChainId == 0) revert InvalidOriginChainId();
        if (originRiskController == address(0) || originVault == address(0) || originUser == address(0)) {
            revert ZeroAddress();
        }
        if (salt == bytes32(0)) revert InvalidSalt();
    }

    /// @notice Deterministically computes the domain-separated canonical PositionID.
    function computePositionId(
        uint256 originChainId,
        address originRiskController,
        address originVault,
        address originUser,
        bytes32 salt
    ) internal pure returns (bytes32) {
        validateIdentityFields(originChainId, originRiskController, originVault, originUser, salt);
        return keccak256(
            abi.encode(POSITION_IDENTITY_DOMAIN, originChainId, originRiskController, originVault, originUser, salt)
        );
    }

    /// @notice Non-reverting canonical validation check used by permissive/event-rejection paths (e.g. Reactive react()).
    function tryComputePositionId(
        uint256 originChainId,
        address originRiskController,
        address originVault,
        address originUser,
        bytes32 salt
    ) internal pure returns (bool valid, bytes32 positionId) {
        if (
            originChainId == 0 || originRiskController == address(0) || originVault == address(0)
                || originUser == address(0) || salt == bytes32(0)
        ) {
            return (false, bytes32(0));
        }
        return (
            true,
            keccak256(
                abi.encode(POSITION_IDENTITY_DOMAIN, originChainId, originRiskController, originVault, originUser, salt)
            )
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {MockCallbackProxy} from "reactive-test-lib/mock/MockCallbackProxy.sol";
import {MockOmniSystemContract} from "../mocks/MockOmniSystemContract.sol";
import {CrossGuardIdentity} from "../../src/libraries/CrossGuardIdentity.sol";
import {ISystemContract} from "../../src/interfaces/ISystemContract.sol";
import {IRiskController} from "../../src/interfaces/IRiskController.sol";
import {TestValuationSource} from "../../src/origin/TestValuationSource.sol";
import {RiskController} from "../../src/origin/RiskController.sol";
import {CollateralVault} from "../../src/origin/CollateralVault.sol";
import {CrossGuardReactive} from "../../src/reactive/CrossGuardReactive.sol";
import {CrossGuardCallback} from "../../src/destination/CrossGuardCallback.sol";
import {BorrowingController} from "../../src/destination/BorrowingController.sol";

/// @dev Minimal ERC-1271 smart-contract wallet stub for testing delegated destination ownership from contract accounts.
contract MockERC1271Wallet is IERC1271 {
    address public immutable signer;

    constructor(address _signer) {
        signer = _signer;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }
}

/// @dev Helper stub to prove RiskController rejects cross-vault spoofing even by another authorized vault.
contract MaliciousVaultStub {
    RiskController public immutable riskController;

    constructor(RiskController _riskController) {
        riskController = _riskController;
    }

    function forwardAssessRisk(bytes32 positionId, address user, uint256 colVal, uint256 debtVal) external {
        riskController.assessRisk(positionId, user, colVal, debtVal);
    }

    function forwardRegisterIdentity(bytes32 positionId, address originUser, bytes32 salt) external {
        riskController.registerPositionIdentity(positionId, originUser, salt);
    }
}

/// @title M007IdentitySecurityTest
/// @notice Comprehensive adversarial test suite for M007.1 cross-chain canonical identity,
///         anti-squatting, EIP-712 / ERC-1271 owner delegation, default-owner policy, and callback identity binding.
contract M007IdentitySecurityTest is Test {
    uint256 constant ORIGIN_CHAIN_ID = 84532;
    uint256 constant DEST_CHAIN_ID = 1301;
    uint64 constant CALLBACK_GAS_LIMIT = 300_000;
    uint256 constant RISK_THRESHOLD_BPS = 8000;
    uint256 constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    address owner = address(0xAA);
    uint256 alicePk = 0xA11CE;
    uint256 attackerPk = 0xBEEF;
    uint256 smartWalletSignerPk = 0x51A7;

    address alice;
    address attacker;
    address smartWalletSigner;
    address destSmartWallet = address(0xD001);
    address relayer = address(0x9999);
    address mockWeth = address(0x1111);
    address mockUsdc = address(0x2222);

    bytes32 constant SALT_1 = keccak256("m007-salt-1");
    bytes32 constant SALT_2 = keccak256("m007-salt-2");

    TestValuationSource oracle;
    RiskController riskController;
    CollateralVault vault;
    MockOmniSystemContract omniSys;
    MockCallbackProxy callbackProxy;
    CrossGuardReactive reactiveContract;
    CrossGuardCallback crossGuardCallback;
    BorrowingController borrowingController;

    bytes32 alicePosId;
    bytes32 alicePosId2;

    event ReactiveEventRejected(
        bytes32 indexed topic0, bytes32 indexed positionId, uint256 indexed nonce, string reason
    );

    function setUp() public {
        alice = vm.addr(alicePk);
        attacker = vm.addr(attackerPk);
        smartWalletSigner = vm.addr(smartWalletSignerPk);

        vm.chainId(ORIGIN_CHAIN_ID);
        vm.startPrank(owner);
        oracle = new TestValuationSource(owner);
        oracle.setAssetPrice(mockWeth, 3000e8);
        oracle.setAssetPrice(mockUsdc, 1e8);

        riskController = new RiskController(owner, RISK_THRESHOLD_BPS);
        vault = new CollateralVault(owner, address(oracle), address(riskController));
        riskController.setAuthorizedVault(address(vault), true);

        omniSys = new MockOmniSystemContract();
        callbackProxy = new MockCallbackProxy();

        borrowingController = new BorrowingController(owner, ORIGIN_CHAIN_ID, address(riskController), address(vault));
        reactiveContract = new CrossGuardReactive(
            owner,
            address(omniSys),
            ORIGIN_CHAIN_ID,
            address(riskController),
            address(vault),
            DEST_CHAIN_ID,
            address(0),
            0
        );
        crossGuardCallback = new CrossGuardCallback(
            owner, address(callbackProxy), address(borrowingController), address(reactiveContract)
        );
        borrowingController.setCallbackAdapter(address(crossGuardCallback));
        reactiveContract.setDestinationConfig(DEST_CHAIN_ID, address(crossGuardCallback), CALLBACK_GAS_LIMIT);
        vm.stopPrank();

        alicePosId = CrossGuardIdentity.computePositionId(
            ORIGIN_CHAIN_ID, address(riskController), address(vault), alice, SALT_1
        );
        alicePosId2 = CrossGuardIdentity.computePositionId(
            ORIGIN_CHAIN_ID, address(riskController), address(vault), alice, SALT_2
        );
    }

    function _signAuthorization(
        BorrowingController targetController,
        uint256 signerPk,
        address originUser,
        bytes32 salt,
        address destOwner,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (CrossGuardIdentity.OriginIdentity memory id, bytes memory signature) {
        id = CrossGuardIdentity.OriginIdentity({
                originChainId: ORIGIN_CHAIN_ID,
                originRiskController: address(riskController),
                originVault: address(vault),
                originUser: originUser,
                salt: salt
            });
        bytes32 digest = targetController.computeAuthorizePositionDigest(id, destOwner, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _makeLog(
        bytes32 topic0,
        bytes32 posId,
        address userAddr,
        uint256 nonce,
        address evVault,
        bytes32 salt,
        uint8 idVersion,
        uint256 ltv
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(topic0),
            topic_1: uint256(posId),
            topic_2: uint256(uint160(userAddr)),
            topic_3: nonce,
            data: abi.encode(idVersion, evVault, salt, ltv, RISK_THRESHOLD_BPS, block.timestamp + 1),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function testOriginFrontRunningAndPositionSquattingPrevented() public {
        vm.chainId(ORIGIN_CHAIN_ID);

        // Attacker attempts to pre-claim Alice's canonical salt
        vm.prank(attacker);
        bytes32 attackerPosId = vault.openPosition(SALT_1, mockWeth, 10e18);
        assertTrue(attackerPosId != alicePosId);

        // Alice still opens her own canonical position cleanly with the same salt
        vm.prank(alice);
        bytes32 createdAliceId = vault.openPosition(SALT_1, mockWeth, 5e18);
        assertEq(createdAliceId, alicePosId);

        // Distinct salt produces distinct isolated canonical position for Alice
        vm.prank(alice);
        bytes32 createdAliceId2 = vault.openPosition(SALT_2, mockWeth, 2e18);
        assertEq(createdAliceId2, alicePosId2);
        assertTrue(createdAliceId2 != createdAliceId);
    }

    function testOriginLegacyDepositAndBorrowCannotInitializeArbitraryId() public {
        vm.chainId(ORIGIN_CHAIN_ID);
        bytes32 forgedId = keccak256("forged-arbitrary-id");

        vm.startPrank(attacker);
        vm.expectRevert(CollateralVault.PositionNotInitialized.selector);
        vault.depositCollateral(forgedId, mockWeth, 1e18);

        vm.expectRevert(CollateralVault.PositionNotInitialized.selector);
        vault.recordBorrow(forgedId, mockUsdc, 100e18);

        vm.expectRevert(CollateralVault.PositionNotInitialized.selector);
        vault.depositCollateral(alicePosId, mockWeth, 1e18);
        vm.stopPrank();

        vm.prank(alice);
        vault.openPosition(SALT_1, mockWeth, 2e18);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.UnauthorizedUser.selector, attacker, alice));
        vault.depositCollateral(alicePosId, mockWeth, 1e18);

        vm.expectRevert(abi.encodeWithSelector(CollateralVault.UnauthorizedUser.selector, attacker, alice));
        vault.recordBorrow(alicePosId, mockUsdc, 100e18);
        vm.stopPrank();
    }

    function testOriginRejectsZeroSaltAndDuplicatePositionId() public {
        vm.chainId(ORIGIN_CHAIN_ID);

        vm.startPrank(alice);
        vm.expectRevert(CrossGuardIdentity.InvalidSalt.selector);
        vault.openPosition(bytes32(0), mockWeth, 1e18);

        vault.openPosition(SALT_1, mockWeth, 1e18);

        vm.expectRevert(abi.encodeWithSelector(CollateralVault.PositionAlreadyExists.selector, alicePosId));
        vault.openPosition(SALT_1, mockWeth, 1e18);
        vm.stopPrank();
    }

    function testRiskControllerRejectsUnauthorizedCallerEvenOwner() public {
        vm.chainId(ORIGIN_CHAIN_ID);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RiskController.UnauthorizedVault.selector, attacker));
        riskController.registerPositionIdentity(alicePosId, alice, SALT_1);

        vm.expectRevert(abi.encodeWithSelector(RiskController.UnauthorizedVault.selector, attacker));
        riskController.assessRisk(alicePosId, alice, 1000e8, 500e8);
        vm.stopPrank();

        // Owner privilege cannot bypass vault authorization in RiskController
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(RiskController.UnauthorizedVault.selector, owner));
        riskController.registerPositionIdentity(alicePosId, alice, SALT_1);

        vm.expectRevert(abi.encodeWithSelector(RiskController.UnauthorizedVault.selector, owner));
        riskController.assessRisk(alicePosId, alice, 1000e8, 500e8);
        vm.stopPrank();
    }

    function testRiskControllerEnforcesOriginVaultAndUserIdentityBinding() public {
        vm.chainId(ORIGIN_CHAIN_ID);

        vm.prank(alice);
        vault.openPosition(SALT_1, mockWeth, 2e18);

        MaliciousVaultStub secondVault = new MaliciousVaultStub(riskController);
        vm.prank(owner);
        riskController.setAuthorizedVault(address(secondVault), true);

        // Authorized second vault cannot assessRisk on unregistered ID
        bytes32 unknownId = keccak256("unknown");
        vm.expectRevert(abi.encodeWithSelector(RiskController.PositionIdentityNotRegistered.selector, unknownId));
        secondVault.forwardAssessRisk(unknownId, alice, 1000e8, 500e8);

        // Authorized second vault cannot register an ID derived for first vault (existing OR uninitialized)
        vm.expectRevert(abi.encodeWithSelector(RiskController.PositionIdentityAlreadyRegistered.selector, alicePosId));
        secondVault.forwardRegisterIdentity(alicePosId, alice, SALT_1);

        bytes32 expectedSecondVaultId2 = CrossGuardIdentity.computePositionId(
            ORIGIN_CHAIN_ID, address(riskController), address(secondVault), alice, SALT_2
        );
        vm.expectRevert(
            abi.encodeWithSelector(RiskController.PositionIdMismatch.selector, alicePosId2, expectedSecondVaultId2)
        );
        secondVault.forwardRegisterIdentity(alicePosId2, alice, SALT_2);

        // Authorized second vault cannot assessRisk on position belonging to first vault
        vm.expectRevert(
            abi.encodeWithSelector(RiskController.VaultIdentityMismatch.selector, address(secondVault), address(vault))
        );
        secondVault.forwardAssessRisk(alicePosId, alice, 1000e8, 900e8);

        // Even real vault cannot re-register existing position identity or assess with wrong user
        vm.startPrank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(RiskController.PositionIdentityAlreadyRegistered.selector, alicePosId));
        riskController.registerPositionIdentity(alicePosId, alice, SALT_1);

        vm.expectRevert(abi.encodeWithSelector(RiskController.OriginUserMismatch.selector, attacker, alice));
        riskController.assessRisk(alicePosId, attacker, 1000e8, 900e8);
        vm.stopPrank();
    }

    function testDestinationSameWalletRegistrationPreventsSquatting() public {
        vm.chainId(DEST_CHAIN_ID);

        // Legacy arbitrary-ID registration selectors no longer exist
        (bool okLegacySelf,) = address(borrowingController)
            .call(abi.encodeWithSignature("registerPosition(bytes32,address)", alicePosId, attacker));
        assertFalse(okLegacySelf);
        (bool okLegacyFor,) = address(borrowingController)
            .call(abi.encodeWithSignature("registerPositionFor(bytes32,address)", alicePosId, attacker));
        assertFalse(okLegacyFor);

        // Attacker calling registerPosition(SALT_1) only derives attacker's own canonical ID
        vm.prank(attacker);
        bytes32 attackerDestId = borrowingController.registerPosition(SALT_1);
        assertTrue(attackerDestId != alicePosId);
        assertEq(borrowingController.positionOwners(alicePosId), address(0));

        // Alice still claims her canonical position cleanly
        vm.prank(alice);
        bytes32 aliceDestId = borrowingController.registerPosition(SALT_1);
        assertEq(aliceDestId, alicePosId);
        assertEq(borrowingController.positionOwners(alicePosId), alice);
        assertEq(borrowingController.originUsers(alicePosId), alice);
        assertEq(borrowingController.originIdentityHashes(alicePosId), alicePosId);
        assertEq(borrowingController.positionIdentityVersion(alicePosId), CrossGuardIdentity.IDENTITY_VERSION);
    }

    function testEip712DelegatedRegistrationViaRelayerAndBorrowingIsolation() public {
        vm.chainId(DEST_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;

        (CrossGuardIdentity.OriginIdentity memory id, bytes memory sig) =
            _signAuthorization(borrowingController, alicePk, alice, SALT_1, destSmartWallet, 0, deadline);

        // Untrusted third-party relayer submits Alice's delegation cleanly
        vm.prank(relayer);
        bytes32 posId = borrowingController.registerPositionWithAuthorization(id, destSmartWallet, deadline, sig);
        assertEq(posId, alicePosId);
        assertEq(borrowingController.positionOwners(posId), destSmartWallet);
        assertEq(borrowingController.originUsers(posId), alice);
        assertEq(borrowingController.sigNonces(alice), 1);

        // Authorized destination wallet borrows
        vm.prank(destSmartWallet);
        borrowingController.borrow(posId, 250e18);
        assertEq(borrowingController.positionBorrowDebt(posId), 250e18);

        // Origin wallet and attacker cannot borrow on destination once delegated
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BorrowingController.UnauthorizedBorrower.selector, alice, destSmartWallet)
        );
        borrowingController.borrow(posId, 10e18);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(BorrowingController.UnauthorizedBorrower.selector, attacker, destSmartWallet)
        );
        borrowingController.borrow(posId, 10e18);
    }

    function testEip712ReplayExpiredWrongSignerOwnerSubstitutionDomainAndMalleability() public {
        vm.chainId(DEST_CHAIN_ID);
        uint256 deadline = 3601; // Constant literal avoids solc via_ir rematerializing block.timestamp across vm.warp

        // 1. Zero destinationOwner rejected
        (CrossGuardIdentity.OriginIdentity memory id0, bytes memory sigForSmart) =
            _signAuthorization(borrowingController, alicePk, alice, SALT_1, destSmartWallet, 0, deadline);
        vm.expectRevert(BorrowingController.ZeroAddress.selector);
        borrowingController.registerPositionWithAuthorization(id0, address(0), deadline, sigForSmart);

        // 2. Owner substitution rejected (Alice signed for destSmartWallet, attacker substitutes attacker)
        vm.expectRevert(BorrowingController.InvalidAuthorizationSignature.selector);
        borrowingController.registerPositionWithAuthorization(id0, attacker, deadline, sigForSmart);

        // 3. Wrong signer rejected
        (CrossGuardIdentity.OriginIdentity memory idWrong, bytes memory sigAttacker) =
            _signAuthorization(borrowingController, attackerPk, alice, SALT_1, destSmartWallet, 0, deadline);
        vm.expectRevert(BorrowingController.InvalidAuthorizationSignature.selector);
        borrowingController.registerPositionWithAuthorization(idWrong, destSmartWallet, deadline, sigAttacker);

        // 4. Untrusted origin domain fields rejected
        CrossGuardIdentity.OriginIdentity memory badChain = CrossGuardIdentity.OriginIdentity({
            originChainId: 1,
            originRiskController: address(riskController),
            originVault: address(vault),
            originUser: alice,
            salt: SALT_1
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                BorrowingController.UntrustedOriginDomain.selector, 1, address(riskController), address(vault)
            )
        );
        borrowingController.registerPositionWithAuthorization(badChain, destSmartWallet, deadline, sigForSmart);

        CrossGuardIdentity.OriginIdentity memory badController = CrossGuardIdentity.OriginIdentity({
            originChainId: ORIGIN_CHAIN_ID,
            originRiskController: attacker,
            originVault: address(vault),
            originUser: alice,
            salt: SALT_1
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                BorrowingController.UntrustedOriginDomain.selector, ORIGIN_CHAIN_ID, attacker, address(vault)
            )
        );
        borrowingController.registerPositionWithAuthorization(badController, destSmartWallet, deadline, sigForSmart);

        CrossGuardIdentity.OriginIdentity memory badVault = CrossGuardIdentity.OriginIdentity({
            originChainId: ORIGIN_CHAIN_ID,
            originRiskController: address(riskController),
            originVault: attacker,
            originUser: alice,
            salt: SALT_1
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                BorrowingController.UntrustedOriginDomain.selector, ORIGIN_CHAIN_ID, address(riskController), attacker
            )
        );
        borrowingController.registerPositionWithAuthorization(badVault, destSmartWallet, deadline, sigForSmart);

        // 5. Cross-chain EIP-712 domain mismatch rejected (signed on chain 9999, submitted on 1301)
        vm.chainId(9999);
        (, bytes memory wrongChainSig) =
            _signAuthorization(borrowingController, alicePk, alice, SALT_1, destSmartWallet, 0, deadline);
        vm.chainId(DEST_CHAIN_ID);
        vm.expectRevert(BorrowingController.InvalidAuthorizationSignature.selector);
        borrowingController.registerPositionWithAuthorization(id0, destSmartWallet, deadline, wrongChainSig);

        // 6. Cross-contract EIP-712 domain mismatch rejected (signed against second BorrowingController)
        BorrowingController otherController =
            new BorrowingController(owner, ORIGIN_CHAIN_ID, address(riskController), address(vault));
        (, bytes memory otherContractSig) =
            _signAuthorization(otherController, alicePk, alice, SALT_1, destSmartWallet, 0, deadline);
        vm.expectRevert(BorrowingController.InvalidAuthorizationSignature.selector);
        borrowingController.registerPositionWithAuthorization(id0, destSmartWallet, deadline, otherContractSig);

        // 7. Signature malleability (high-s / flipped v) rejected
        bytes32 digest = borrowingController.computeAuthorizePositionDigest(id0, destSmartWallet, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        bytes32 malleableS = bytes32(SECP256K1_N - uint256(s));
        uint8 malleableV = v == 27 ? 28 : 27;
        bytes memory malleableSig = abi.encodePacked(r, malleableS, malleableV);
        vm.expectRevert(BorrowingController.InvalidAuthorizationSignature.selector);
        borrowingController.registerPositionWithAuthorization(id0, destSmartWallet, deadline, malleableSig);

        // 8. Expired signature rejected
        vm.warp(deadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(BorrowingController.AuthorizationExpired.selector, deadline, deadline + 1)
        );
        borrowingController.registerPositionWithAuthorization(id0, destSmartWallet, deadline, sigForSmart);

        // 9. Valid execution succeeds and consumes nonce, blocking replay even for SALT_2
        uint256 freshDeadline = block.timestamp + 1 hours;
        (CrossGuardIdentity.OriginIdentity memory idValid, bytes memory sigValid) =
            _signAuthorization(borrowingController, alicePk, alice, SALT_1, destSmartWallet, 0, freshDeadline);
        borrowingController.registerPositionWithAuthorization(idValid, destSmartWallet, freshDeadline, sigValid);
        assertEq(borrowingController.sigNonces(alice), 1);

        // Exact replay fails on incremented sigNonce
        vm.expectRevert(BorrowingController.InvalidAuthorizationSignature.selector);
        borrowingController.registerPositionWithAuthorization(idValid, destSmartWallet, freshDeadline, sigValid);

        // Using stale nonce 0 on SALT_2 also fails
        (CrossGuardIdentity.OriginIdentity memory idSalt2Stale, bytes memory sigSalt2Stale) =
            _signAuthorization(borrowingController, alicePk, alice, SALT_2, destSmartWallet, 0, freshDeadline);
        vm.expectRevert(BorrowingController.InvalidAuthorizationSignature.selector);
        borrowingController.registerPositionWithAuthorization(
            idSalt2Stale, destSmartWallet, freshDeadline, sigSalt2Stale
        );
    }

    function testErc1271SmartContractWalletDelegatedRegistration() public {
        vm.chainId(DEST_CHAIN_ID);
        MockERC1271Wallet originSmartWallet = new MockERC1271Wallet(smartWalletSigner);
        uint256 deadline = block.timestamp + 1 hours;

        (CrossGuardIdentity.OriginIdentity memory idBad, bytes memory badSig) = _signAuthorization(
            borrowingController, attackerPk, address(originSmartWallet), SALT_1, destSmartWallet, 0, deadline
        );
        vm.expectRevert(BorrowingController.InvalidAuthorizationSignature.selector);
        borrowingController.registerPositionWithAuthorization(idBad, destSmartWallet, deadline, badSig);

        (CrossGuardIdentity.OriginIdentity memory idGood, bytes memory goodSig) = _signAuthorization(
            borrowingController, smartWalletSignerPk, address(originSmartWallet), SALT_1, destSmartWallet, 0, deadline
        );
        vm.prank(relayer);
        bytes32 posId =
            borrowingController.registerPositionWithAuthorization(idGood, destSmartWallet, deadline, goodSig);

        bytes32 expectedId = CrossGuardIdentity.computePositionId(
            ORIGIN_CHAIN_ID, address(riskController), address(vault), address(originSmartWallet), SALT_1
        );
        assertEq(posId, expectedId);
        assertEq(borrowingController.positionOwners(posId), destSmartWallet);
        assertEq(borrowingController.originUsers(posId), address(originSmartWallet));
        assertEq(borrowingController.sigNonces(address(originSmartWallet)), 1);

        vm.prank(destSmartWallet);
        borrowingController.borrow(posId, 50e18);
        assertEq(borrowingController.positionBorrowDebt(posId), 50e18);
    }

    function testReactiveRejectsSpoofedOriginVaultVersionUpperBitsSaltAndIdentityMismatch() public {
        bytes32 topicBreach = reactiveContract.RISK_BREACH_TOPIC_0();

        // 1. Spoofed origin vault address in event data
        IReactive.LogRecord memory spoofVaultLog =
            _makeLog(topicBreach, alicePosId, alice, 1, attacker, SALT_1, CrossGuardIdentity.IDENTITY_VERSION, 8500);
        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(topicBreach, alicePosId, 1, "UNAUTHORIZED_ORIGIN_VAULT");
        vm.prank(address(omniSys));
        reactiveContract.react(spoofVaultLog);
        assertEq(reactiveContract.latestOriginNonce(alicePosId), 0);

        // 2. Unsupported identity version (2)
        IReactive.LogRecord memory badVerLog =
            _makeLog(topicBreach, alicePosId, alice, 1, address(vault), SALT_1, 2, 8500);
        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(topicBreach, alicePosId, 1, "UNSUPPORTED_IDENTITY_VERSION");
        vm.prank(address(omniSys));
        reactiveContract.react(badVerLog);

        // 3. Non-canonical upper bits on identityVersion word
        IReactive.LogRecord memory dirtyVerLog =
            _makeLog(topicBreach, alicePosId, alice, 1, address(vault), SALT_1, 1, 8500);
        dirtyVerLog.data = abi.encode(
            uint256(1) | (uint256(1) << 8),
            address(vault),
            SALT_1,
            uint256(8500),
            RISK_THRESHOLD_BPS,
            block.timestamp + 1
        );
        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(topicBreach, alicePosId, 1, "MALFORMED_EVENT_DATA");
        vm.prank(address(omniSys));
        reactiveContract.react(dirtyVerLog);

        // 4. Non-canonical upper bits on originVault word
        IReactive.LogRecord memory dirtyVaultWord =
            _makeLog(topicBreach, alicePosId, alice, 1, address(vault), SALT_1, 1, 8500);
        dirtyVaultWord.data = abi.encode(
            uint256(1),
            uint256(uint160(address(vault))) | (uint256(1) << 160),
            SALT_1,
            uint256(8500),
            RISK_THRESHOLD_BPS,
            block.timestamp + 1
        );
        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(topicBreach, alicePosId, 1, "MALFORMED_EVENT_DATA");
        vm.prank(address(omniSys));
        reactiveContract.react(dirtyVaultWord);

        // 5. Zero salt
        IReactive.LogRecord memory zeroSaltLog =
            _makeLog(topicBreach, alicePosId, alice, 1, address(vault), bytes32(0), 1, 8500);
        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(topicBreach, alicePosId, 1, "INVALID_SALT");
        vm.prank(address(omniSys));
        reactiveContract.react(zeroSaltLog);

        // 6. PositionID preimage mismatch (wrong user in topic_2 or wrong salt)
        IReactive.LogRecord memory wrongUserLog =
            _makeLog(topicBreach, alicePosId, attacker, 1, address(vault), SALT_1, 1, 8500);
        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(topicBreach, alicePosId, 1, "POSITION_ID_MISMATCH");
        vm.prank(address(omniSys));
        reactiveContract.react(wrongUserLog);

        IReactive.LogRecord memory wrongSaltLog =
            _makeLog(topicBreach, alicePosId, alice, 1, address(vault), SALT_2, 1, 8500);
        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(topicBreach, alicePosId, 1, "POSITION_ID_MISMATCH");
        vm.prank(address(omniSys));
        reactiveContract.react(wrongSaltLog);

        // 7. Legacy 96-byte payload rejected
        IReactive.LogRecord memory legacyLenLog =
            _makeLog(topicBreach, alicePosId, alice, 1, address(vault), SALT_1, 1, 8500);
        legacyLenLog.data = abi.encode(uint256(8500), RISK_THRESHOLD_BPS, block.timestamp + 1);
        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(topicBreach, alicePosId, 1, "INVALID_DATA_LENGTH");
        vm.prank(address(omniSys));
        reactiveContract.react(legacyLenLog);

        // 8. Wrong emitter (CollateralVault instead of RiskController)
        IReactive.LogRecord memory wrongEmitterLog =
            _makeLog(topicBreach, alicePosId, alice, 1, address(vault), SALT_1, 1, 8500);
        wrongEmitterLog._contract = address(vault);
        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(topicBreach, alicePosId, 1, "WRONG_EMITTER");
        vm.prank(address(omniSys));
        reactiveContract.react(wrongEmitterLog);

        assertEq(reactiveContract.latestOriginNonce(alicePosId), 0);
        assertEq(omniSys.requestedCallbackCount(), 0);
    }

    function testCallbackAndDestinationRejectIdentitySubstitutionAndForgedSender() public {
        vm.chainId(DEST_CHAIN_ID);

        CrossGuardIdentity.RiskCallbackMessage memory validMsg = CrossGuardIdentity.RiskCallbackMessage({
            identityVersion: CrossGuardIdentity.IDENTITY_VERSION,
            originChainId: ORIGIN_CHAIN_ID,
            originRiskController: address(riskController),
            originVault: address(vault),
            originUser: alice,
            positionId: alicePosId,
            salt: SALT_1,
            nonce: 1,
            riskLevel: 8500,
            timestamp: block.timestamp
        });

        // 1. Direct non-proxy caller fails
        vm.prank(attacker);
        vm.expectRevert();
        crossGuardCallback.handleRiskBreach(address(reactiveContract), validMsg);

        // 2. CallbackProxy injecting wrong reactiveSender fails (including alice herself)
        bytes memory badSenderPayload = abi.encodeCall(crossGuardCallback.handleRiskBreach, (address(0), validMsg));
        (bool okForged,) =
            callbackProxy.executeCallback(address(crossGuardCallback), badSenderPayload, CALLBACK_GAS_LIMIT, alice);
        assertFalse(okForged);

        // 3. Callback rejects bad version / zero positionId / mismatched preimage even from authorizedReactiveSender
        CrossGuardIdentity.RiskCallbackMessage memory badVerMsg = CrossGuardIdentity.RiskCallbackMessage({
            identityVersion: 9,
            originChainId: ORIGIN_CHAIN_ID,
            originRiskController: address(riskController),
            originVault: address(vault),
            originUser: alice,
            positionId: alicePosId,
            salt: SALT_1,
            nonce: 1,
            riskLevel: 8500,
            timestamp: block.timestamp
        });
        (bool okBadVer,) = callbackProxy.executeCallback(
            address(crossGuardCallback),
            abi.encodeCall(crossGuardCallback.handleRiskBreach, (address(0), badVerMsg)),
            CALLBACK_GAS_LIMIT,
            address(reactiveContract)
        );
        assertFalse(okBadVer);

        CrossGuardIdentity.RiskCallbackMessage memory mismatchMsg = CrossGuardIdentity.RiskCallbackMessage({
            identityVersion: CrossGuardIdentity.IDENTITY_VERSION,
            originChainId: ORIGIN_CHAIN_ID,
            originRiskController: address(riskController),
            originVault: address(vault),
            originUser: alice,
            positionId: alicePosId2,
            salt: SALT_1,
            nonce: 1,
            riskLevel: 8500,
            timestamp: block.timestamp
        });
        (bool okMismatch,) = callbackProxy.executeCallback(
            address(crossGuardCallback),
            abi.encodeCall(crossGuardCallback.handleRiskBreach, (address(0), mismatchMsg)),
            CALLBACK_GAS_LIMIT,
            address(reactiveContract)
        );
        assertFalse(okMismatch);

        // 4. BorrowingController independently rejects wrong trustedOrigin domain fields even from callbackAdapter
        vm.startPrank(address(crossGuardCallback));

        CrossGuardIdentity.RiskCallbackMessage memory spoofVaultMsg = CrossGuardIdentity.RiskCallbackMessage({
            identityVersion: CrossGuardIdentity.IDENTITY_VERSION,
            originChainId: ORIGIN_CHAIN_ID,
            originRiskController: address(riskController),
            originVault: attacker,
            originUser: alice,
            positionId: CrossGuardIdentity.computePositionId(
                ORIGIN_CHAIN_ID, address(riskController), attacker, alice, SALT_1
            ),
            salt: SALT_1,
            nonce: 1,
            riskLevel: 8500,
            timestamp: block.timestamp
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                BorrowingController.UntrustedOriginDomain.selector, ORIGIN_CHAIN_ID, address(riskController), attacker
            )
        );
        borrowingController.pauseBorrowing(spoofVaultMsg);

        CrossGuardIdentity.RiskCallbackMessage memory spoofControllerMsg = CrossGuardIdentity.RiskCallbackMessage({
            identityVersion: CrossGuardIdentity.IDENTITY_VERSION,
            originChainId: ORIGIN_CHAIN_ID,
            originRiskController: attacker,
            originVault: address(vault),
            originUser: alice,
            positionId: CrossGuardIdentity.computePositionId(ORIGIN_CHAIN_ID, attacker, address(vault), alice, SALT_1),
            salt: SALT_1,
            nonce: 1,
            riskLevel: 8500,
            timestamp: block.timestamp
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                BorrowingController.UntrustedOriginDomain.selector, ORIGIN_CHAIN_ID, attacker, address(vault)
            )
        );
        borrowingController.resolveBorrowing(spoofControllerMsg);

        CrossGuardIdentity.RiskCallbackMessage memory spoofChainMsg = CrossGuardIdentity.RiskCallbackMessage({
            identityVersion: CrossGuardIdentity.IDENTITY_VERSION,
            originChainId: 1,
            originRiskController: address(riskController),
            originVault: address(vault),
            originUser: alice,
            positionId: CrossGuardIdentity.computePositionId(1, address(riskController), address(vault), alice, SALT_1),
            salt: SALT_1,
            nonce: 1,
            riskLevel: 8500,
            timestamp: block.timestamp
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                BorrowingController.UntrustedOriginDomain.selector, 1, address(riskController), address(vault)
            )
        );
        borrowingController.pauseBorrowing(spoofChainMsg);

        vm.stopPrank();
    }

    function testDefaultOwnerPolicyBreachBeforeRegistrationVsResolvedBeforeRegistration() public {
        vm.chainId(DEST_CHAIN_ID);

        // Scenario A: Unregistered position gets authenticated RiskBreach first -> binds default owner = originUser
        CrossGuardIdentity.RiskCallbackMessage memory breachA = CrossGuardIdentity.RiskCallbackMessage({
            identityVersion: CrossGuardIdentity.IDENTITY_VERSION,
            originChainId: ORIGIN_CHAIN_ID,
            originRiskController: address(riskController),
            originVault: address(vault),
            originUser: alice,
            positionId: alicePosId,
            salt: SALT_1,
            nonce: 1,
            riskLevel: 8500,
            timestamp: block.timestamp
        });

        (bool okBreachA,) = callbackProxy.executeCallback(
            address(crossGuardCallback),
            abi.encodeCall(crossGuardCallback.handleRiskBreach, (address(0), breachA)),
            CALLBACK_GAS_LIMIT,
            address(reactiveContract)
        );
        assertTrue(okBreachA);
        assertEq(borrowingController.positionOwners(alicePosId), alice);
        assertEq(borrowingController.originUsers(alicePosId), alice);
        assertTrue(borrowingController.isBorrowingPaused(alicePosId));

        // Subsequent RiskResolved preserves alice as owner and allows ONLY alice to borrow
        CrossGuardIdentity.RiskCallbackMessage memory resolveA = breachA;
        resolveA.nonce = 2;
        resolveA.riskLevel = 5000;
        resolveA.timestamp = block.timestamp + 10;
        (bool okResA,) = callbackProxy.executeCallback(
            address(crossGuardCallback),
            abi.encodeCall(crossGuardCallback.handleRiskResolved, (address(0), resolveA)),
            CALLBACK_GAS_LIMIT,
            address(reactiveContract)
        );
        assertTrue(okResA);
        assertEq(borrowingController.positionOwners(alicePosId), alice);
        assertFalse(borrowingController.isBorrowingPaused(alicePosId));

        vm.prank(alice);
        borrowingController.borrow(alicePosId, 100e18);

        // Scenario B: Unregistered SALT_2 gets RiskResolved first -> initializes identity, keeps positionOwners == 0
        CrossGuardIdentity.RiskCallbackMessage memory resolveB = CrossGuardIdentity.RiskCallbackMessage({
            identityVersion: CrossGuardIdentity.IDENTITY_VERSION,
            originChainId: ORIGIN_CHAIN_ID,
            originRiskController: address(riskController),
            originVault: address(vault),
            originUser: alice,
            positionId: alicePosId2,
            salt: SALT_2,
            nonce: 1,
            riskLevel: 4000,
            timestamp: block.timestamp + 20
        });

        (bool okResB,) = callbackProxy.executeCallback(
            address(crossGuardCallback),
            abi.encodeCall(crossGuardCallback.handleRiskResolved, (address(0), resolveB)),
            CALLBACK_GAS_LIMIT,
            address(reactiveContract)
        );
        assertTrue(okResB);
        assertEq(borrowingController.positionIdentityVersion(alicePosId2), CrossGuardIdentity.IDENTITY_VERSION);
        assertEq(borrowingController.originUsers(alicePosId2), alice);
        assertEq(borrowingController.originIdentityHashes(alicePosId2), alicePosId2);
        assertEq(borrowingController.positionOwners(alicePosId2), address(0));

        // alice cannot borrow until explicit registration occurs
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BorrowingController.UnregisteredPosition.selector, alicePosId2));
        borrowingController.borrow(alicePosId2, 10e18);

        // alice CAN now delegate SALT_2 to destSmartWallet via EIP-712 seamlessly!
        uint256 deadline = block.timestamp + 1 hours;
        (CrossGuardIdentity.OriginIdentity memory idB, bytes memory sigB) =
            _signAuthorization(borrowingController, alicePk, alice, SALT_2, destSmartWallet, 0, deadline);
        vm.prank(relayer);
        borrowingController.registerPositionWithAuthorization(idB, destSmartWallet, deadline, sigB);
        assertEq(borrowingController.positionOwners(alicePosId2), destSmartWallet);

        // Later breach + resolution on SALT_2 MUST preserve destSmartWallet without overwriting to alice or reactiveContract
        CrossGuardIdentity.RiskCallbackMessage memory breachB = resolveB;
        breachB.nonce = 2;
        breachB.riskLevel = 8800;
        (bool okBreachB,) = callbackProxy.executeCallback(
            address(crossGuardCallback),
            abi.encodeCall(crossGuardCallback.handleRiskBreach, (address(0), breachB)),
            CALLBACK_GAS_LIMIT,
            address(reactiveContract)
        );
        assertTrue(okBreachB);
        assertEq(borrowingController.positionOwners(alicePosId2), destSmartWallet);
    }
}

/// @title M007IdentityHandler
/// @notice Bounded stateful actor for multi-chain identity, delegation, callback replay, and spoofing invariants.
contract M007IdentityHandler is Test {
    uint256 constant ORIGIN_CHAIN = 84532;
    uint256 constant DEST_CHAIN = 1301;

    address public immutable owner;
    TestValuationSource public immutable oracle;
    RiskController public immutable riskController;
    CollateralVault public immutable vault;
    CrossGuardReactive public immutable reactiveContract;
    MockOmniSystemContract public immutable omniSys;
    MockCallbackProxy public immutable callbackProxy;
    CrossGuardCallback public immutable crossGuardCallback;
    BorrowingController public immutable borrowingController;

    address public immutable alice;
    uint256 public immutable alicePk;
    address public immutable bob;
    uint256 public immutable bobPk;
    MockERC1271Wallet public immutable smartOriginWallet;
    uint256 public immutable smartWalletSignerPk;
    address public immutable charlie;
    uint256 public immutable charliePk;

    address public immutable destWalletA = address(0xD101);
    address public immutable destWalletB = address(0xD102);
    address public immutable attacker = address(0xBAD1);
    address public immutable relayer = address(0xFEED);
    address public immutable mockUsdc = address(0x2222);

    uint256 public constant NUM_SLOTS = 4;
    bytes32[4] public slotPosIds;
    address[4] public slotOriginUsers;
    uint256[4] public slotUserPks;
    bytes32[4] public slotSalts;
    address[4] public slotCollateralAssets;

    // Ghost tracking variables for invariants
    mapping(bytes32 => bool) public ghostOriginOpened;
    mapping(bytes32 => bool) public ghostBreachOrExplicitRegistered;
    mapping(bytes32 => address) public ghostLockedDestOwner;
    mapping(bytes32 => address) public ghostDelegatedDestOwner;
    mapping(bytes32 => address) public ghostLockedOriginUser;
    mapping(bytes32 => bytes32) public ghostLockedIdentityHash;
    mapping(bytes32 => uint8) public ghostLockedVersion;

    mapping(address => uint256) public ghostMinSigNonce;
    mapping(bytes32 => uint256) public ghostMinProcessedNonce;
    mapping(bytes32 => CrossGuardIdentity.OriginIdentity) public ghostOriginTuple;
    mapping(bytes32 => bool) public ghostOriginTupleCaptured;

    // Record at most 1 consumed signature per slot for active replay invariance checks
    mapping(bytes32 => CrossGuardIdentity.OriginIdentity) public consumedId;
    mapping(bytes32 => address) public consumedDestOwner;
    mapping(bytes32 => uint256) public consumedDeadline;
    mapping(bytes32 => bytes) public consumedSig;
    mapping(bytes32 => bool) public hasConsumedSig;

    bool public ghostUnexpectedOwnerMutation;
    bool public ghostIdentityMetadataMutated;
    bool public ghostUnauthorizedBorrowSucceeded;
    bool public ghostPausedBorrowSucceeded;
    bool public ghostSpoofedReactiveAccepted;
    bool public ghostReplaySucceeded;

    constructor(
        address _owner,
        TestValuationSource _oracle,
        RiskController _riskController,
        CollateralVault _vault,
        CrossGuardReactive _reactiveContract,
        MockOmniSystemContract _omniSys,
        MockCallbackProxy _callbackProxy,
        CrossGuardCallback _crossGuardCallback,
        BorrowingController _borrowingController,
        address _alice,
        uint256 _alicePk,
        address _bob,
        uint256 _bobPk,
        MockERC1271Wallet _smartOriginWallet,
        uint256 _smartWalletSignerPk,
        address _charlie,
        uint256 _charliePk
    ) {
        owner = _owner;
        oracle = _oracle;
        riskController = _riskController;
        vault = _vault;
        reactiveContract = _reactiveContract;
        omniSys = _omniSys;
        callbackProxy = _callbackProxy;
        crossGuardCallback = _crossGuardCallback;
        borrowingController = _borrowingController;
        alice = _alice;
        alicePk = _alicePk;
        bob = _bob;
        bobPk = _bobPk;
        smartOriginWallet = _smartOriginWallet;
        smartWalletSignerPk = _smartWalletSignerPk;
        charlie = _charlie;
        charliePk = _charliePk;

        slotOriginUsers[0] = alice;
        slotUserPks[0] = alicePk;
        slotSalts[0] = keccak256("inv-salt-0");
        slotCollateralAssets[0] = address(0x1001);

        slotOriginUsers[1] = bob;
        slotUserPks[1] = bobPk;
        slotSalts[1] = keccak256("inv-salt-1");
        slotCollateralAssets[1] = address(0x1002);

        slotOriginUsers[2] = address(smartOriginWallet);
        slotUserPks[2] = smartWalletSignerPk;
        slotSalts[2] = keccak256("inv-salt-2");
        slotCollateralAssets[2] = address(0x1003);

        slotOriginUsers[3] = charlie;
        slotUserPks[3] = charliePk;
        slotSalts[3] = keccak256("inv-salt-3");
        slotCollateralAssets[3] = address(0x1004);

        for (uint256 i = 0; i < NUM_SLOTS; i++) {
            slotPosIds[i] = CrossGuardIdentity.computePositionId(
                ORIGIN_CHAIN, address(riskController), address(vault), slotOriginUsers[i], slotSalts[i]
            );
        }
    }

    function _syncIdentityGhosts(bytes32 pos) internal {
        uint8 ver = borrowingController.positionIdentityVersion(pos);
        if (ver != 0) {
            address u = borrowingController.originUsers(pos);
            bytes32 h = borrowingController.originIdentityHashes(pos);
            if (ghostLockedIdentityHash[pos] != bytes32(0)) {
                // Already locked; verify immutable
                if (
                    ghostLockedOriginUser[pos] != u || ghostLockedIdentityHash[pos] != h
                        || ghostLockedVersion[pos] != ver
                ) {
                    ghostIdentityMetadataMutated = true;
                }
            } else {
                ghostLockedOriginUser[pos] = u;
                ghostLockedIdentityHash[pos] = h;
                ghostLockedVersion[pos] = ver;
            }
        }

        address curOwner = borrowingController.positionOwners(pos);
        if (curOwner != address(0)) {
            if (ghostLockedDestOwner[pos] == address(0)) {
                ghostLockedDestOwner[pos] = curOwner;
            } else if (ghostLockedDestOwner[pos] != curOwner) {
                ghostUnexpectedOwnerMutation = true;
            }
        } else if (ghostLockedDestOwner[pos] != address(0)) {
            ghostUnexpectedOwnerMutation = true;
        }
    }

    function openOriginPosition(uint256 slotIdx) external {
        uint256 i = slotIdx % NUM_SLOTS;
        bytes32 pos = slotPosIds[i];
        vm.chainId(ORIGIN_CHAIN);

        if (!ghostOriginOpened[pos]) {
            vm.prank(owner);
            oracle.setAssetPrice(slotCollateralAssets[i], 3000e8);

            vm.startPrank(slotOriginUsers[i]);
            vault.openPosition(slotSalts[i], slotCollateralAssets[i], 2e18);
            vault.recordBorrow(pos, mockUsdc, 2000e18);
            vm.stopPrank();

            ghostOriginOpened[pos] = true;
            ghostOriginTuple[pos] = riskController.getPositionIdentity(pos);
            ghostOriginTupleCaptured[pos] = true;
        }

        // Attacker squat attempt using same salt must never claim pos
        vm.prank(attacker);
        try vault.openPosition(slotSalts[i], slotCollateralAssets[i], 1e18) returns (bytes32 attPos) {
            if (attPos == pos) ghostSpoofedReactiveAccepted = true;
        } catch {}
    }

    function registerSameWallet(uint256 slotIdx) external {
        uint256 i = slotIdx % NUM_SLOTS;
        bytes32 pos = slotPosIds[i];
        vm.chainId(DEST_CHAIN);

        // Attacker tries same-wallet claim with same salt -> gets separate ID only
        vm.prank(attacker);
        try borrowingController.registerPosition(slotSalts[i]) returns (bytes32 attId) {
            if (attId == pos) ghostUnexpectedOwnerMutation = true;
        } catch {}

        // Legitimate user registers
        vm.prank(slotOriginUsers[i]);
        try borrowingController.registerPosition(slotSalts[i]) {
            ghostBreachOrExplicitRegistered[pos] = true;
        } catch {}

        _syncIdentityGhosts(pos);
    }

    function registerDelegatedWithEip712(uint256 slotIdx, bool altDest, bool tryWrongSigner, bool tryExpired) external {
        uint256 i = slotIdx % NUM_SLOTS;
        bytes32 pos = slotPosIds[i];
        address user = slotOriginUsers[i];
        uint256 pk = tryWrongSigner ? uint256(0xDEAD1) : slotUserPks[i];
        address destOwner = altDest ? destWalletB : destWalletA;
        vm.chainId(DEST_CHAIN);

        uint256 nonceBefore = borrowingController.sigNonces(user);
        if (nonceBefore < ghostMinSigNonce[user]) {
            ghostReplaySucceeded = true;
        }

        uint256 deadline = tryExpired ? block.timestamp - 1 : block.timestamp + 1 hours;
        CrossGuardIdentity.OriginIdentity memory id = CrossGuardIdentity.OriginIdentity({
            originChainId: ORIGIN_CHAIN,
            originRiskController: address(riskController),
            originVault: address(vault),
            originUser: user,
            salt: slotSalts[i]
        });
        bytes32 digest = borrowingController.computeAuthorizePositionDigest(id, destOwner, nonceBefore, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        try borrowingController.registerPositionWithAuthorization(id, destOwner, deadline, sig) {
            if (tryWrongSigner || tryExpired) {
                ghostReplaySucceeded = true;
            }
            ghostBreachOrExplicitRegistered[pos] = true;
            if (ghostDelegatedDestOwner[pos] == address(0)) {
                ghostDelegatedDestOwner[pos] = destOwner;
            }
            if (!hasConsumedSig[pos]) {
                consumedId[pos] = id;
                consumedDestOwner[pos] = destOwner;
                consumedDeadline[pos] = deadline;
                consumedSig[pos] = sig;
                hasConsumedSig[pos] = true;
            }
        } catch {}

        uint256 nonceAfter = borrowingController.sigNonces(user);
        if (nonceAfter < nonceBefore) {
            ghostReplaySucceeded = true;
        }
        if (nonceAfter > ghostMinSigNonce[user]) {
            ghostMinSigNonce[user] = nonceAfter;
        }

        // Attempt replaying stored consumed signature
        if (hasConsumedSig[pos]) {
            vm.prank(relayer);
            try borrowingController.registerPositionWithAuthorization(
                consumedId[pos], consumedDestOwner[pos], consumedDeadline[pos], consumedSig[pos]
            ) {
                ghostReplaySucceeded = true;
            } catch {}
        }

        _syncIdentityGhosts(pos);
    }

    function triggerOriginTransition(uint256 slotIdx, bool breach, bool deliverImmediately) external {
        uint256 i = slotIdx % NUM_SLOTS;
        bytes32 pos = slotPosIds[i];
        if (!ghostOriginOpened[pos]) return;

        vm.chainId(ORIGIN_CHAIN);
        vm.prank(owner);
        oracle.setAssetPrice(slotCollateralAssets[i], breach ? 1000e8 : 4000e8);

        uint256 prevOriginNonce = riskController.positionNonce(pos);
        (bool isBreached, uint256 ltvBps, uint256 originNonce) = vault.evaluatePositionRisk(pos);

        if (originNonce > prevOriginNonce) {
            bytes32 topic0 =
                isBreached ? reactiveContract.RISK_BREACH_TOPIC_0() : reactiveContract.RISK_RESOLVED_TOPIC_0();
            IReactive.LogRecord memory rec = IReactive.LogRecord({
                chain_id: ORIGIN_CHAIN,
                _contract: address(riskController),
                topic_0: uint256(topic0),
                topic_1: uint256(pos),
                topic_2: uint256(uint160(slotOriginUsers[i])),
                topic_3: originNonce,
                data: abi.encode(
                    CrossGuardIdentity.IDENTITY_VERSION,
                    address(vault),
                    slotSalts[i],
                    ltvBps,
                    riskController.riskThresholdBps(),
                    block.timestamp + 1
                ),
                block_number: block.number,
                op_code: 0,
                block_hash: 0,
                tx_hash: 0,
                log_index: 0
            });

            vm.prank(address(omniSys));
            reactiveContract.react(rec);

            if (deliverImmediately) {
                (,, bytes memory payload,, CrossGuardReactive.DispatchStatus status) =
                    reactiveContract.getLatestCallback(pos);
                if (status == CrossGuardReactive.DispatchStatus.REQUESTED && payload.length > 0) {
                    vm.chainId(DEST_CHAIN);
                    (bool ok,) = callbackProxy.executeCallback(
                        address(crossGuardCallback), payload, 300_000, address(reactiveContract)
                    );
                    if (ok && isBreached) {
                        ghostBreachOrExplicitRegistered[pos] = true;
                    }
                    uint256 pNow = borrowingController.lastProcessedNonce(pos);
                    if (pNow > ghostMinProcessedNonce[pos]) ghostMinProcessedNonce[pos] = pNow;
                }
            }
        }

        _syncIdentityGhosts(pos);
    }

    function executeStoredCallback(uint256 slotIdx) external {
        uint256 i = slotIdx % NUM_SLOTS;
        bytes32 pos = slotPosIds[i];
        (, CrossGuardReactive.CallbackType evType, bytes memory payload,, CrossGuardReactive.DispatchStatus status) =
            reactiveContract.getLatestCallback(pos);
        if (status != CrossGuardReactive.DispatchStatus.REQUESTED || payload.length == 0) return;

        vm.chainId(DEST_CHAIN);
        (bool ok,) =
            callbackProxy.executeCallback(address(crossGuardCallback), payload, 300_000, address(reactiveContract));
        if (ok && evType == CrossGuardReactive.CallbackType.BREACH) {
            ghostBreachOrExplicitRegistered[pos] = true;
        }
        uint256 pNow = borrowingController.lastProcessedNonce(pos);
        if (pNow > ghostMinProcessedNonce[pos]) ghostMinProcessedNonce[pos] = pNow;

        _syncIdentityGhosts(pos);
    }

    function retryStoredCallback(uint256 slotIdx) external {
        uint256 i = slotIdx % NUM_SLOTS;
        bytes32 pos = slotPosIds[i];
        (uint256 nonce,,,,) = reactiveContract.getLatestCallback(pos);
        if (nonce == 0) return;
        vm.prank(owner);
        try reactiveContract.retryFailedCallback(pos, nonce, bytes32("M007_INV_RETRY")) {} catch {}
    }

    function adminPauseAndResume(uint256 slotIdx, uint256 action) external {
        uint256 i = slotIdx % NUM_SLOTS;
        bytes32 pos = slotPosIds[i];
        vm.chainId(DEST_CHAIN);
        uint256 op = action % 3;
        vm.startPrank(owner);
        if (op == 0) {
            try borrowingController.emergencyPauseBorrowing(pos) {} catch {}
        } else if (op == 1) {
            try borrowingController.resumeBorrowing(pos) {} catch {}
        } else {
            try borrowingController.emergencyResumeBorrowing(pos, "inv-audit") {} catch {}
        }
        vm.stopPrank();
        _syncIdentityGhosts(pos);
    }

    function exerciseBorrow(uint256 slotIdx, uint256 callerChoice) external {
        uint256 i = slotIdx % NUM_SLOTS;
        bytes32 pos = slotPosIds[i];
        vm.chainId(DEST_CHAIN);

        address caller;
        uint256 c = callerChoice % 4;
        if (c == 0) caller = borrowingController.positionOwners(pos);
        else if (c == 1) caller = slotOriginUsers[i];
        else if (c == 2) caller = destWalletA;
        else caller = attacker;

        address expectedOwner = borrowingController.positionOwners(pos);
        bool paused = borrowingController.isBorrowingPaused(pos);
        uint8 ver = borrowingController.positionIdentityVersion(pos);

        vm.prank(caller);
        try borrowingController.borrow(pos, 10e18) {
            if (expectedOwner == address(0) || ver == 0 || caller != expectedOwner) {
                ghostUnauthorizedBorrowSucceeded = true;
            }
            if (paused) {
                ghostPausedBorrowSucceeded = true;
            }
        } catch {}
    }

    function injectSpoofedIdentityLogs(uint256 slotIdx, uint256 mutationType) external {
        uint256 i = slotIdx % NUM_SLOTS;
        bytes32 pos = slotPosIds[i];
        uint256 m = mutationType % 4;

        uint256 reactiveNonceBefore = reactiveContract.latestOriginNonce(pos);
        uint256 destNonceBefore = borrowingController.lastProcessedNonce(pos);

        if (m < 3) {
            uint8 ver = m == 1 ? 2 : CrossGuardIdentity.IDENTITY_VERSION;
            address evVault = m == 0 ? attacker : address(vault);
            bytes32 targetPos = m == 2 ? keccak256("forged-pos") : pos;

            IReactive.LogRecord memory rec = IReactive.LogRecord({
                chain_id: ORIGIN_CHAIN,
                _contract: address(riskController),
                topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
                topic_1: uint256(targetPos),
                topic_2: uint256(uint160(slotOriginUsers[i])),
                topic_3: reactiveNonceBefore + 99,
                data: abi.encode(
                    ver, evVault, slotSalts[i], 9000, riskController.riskThresholdBps(), block.timestamp + 1
                ),
                block_number: block.number,
                op_code: 0,
                block_hash: 0,
                tx_hash: 0,
                log_index: 0
            });
            vm.prank(address(omniSys));
            reactiveContract.react(rec);
            if (reactiveContract.latestOriginNonce(pos) != reactiveNonceBefore) {
                ghostSpoofedReactiveAccepted = true;
            }
            if (m == 2 && reactiveContract.latestOriginNonce(targetPos) != 0) {
                ghostSpoofedReactiveAccepted = true;
            }
        } else {
            // Destination callback identity substitution attempt via untrusted vault/domain
            CrossGuardIdentity.RiskCallbackMessage memory spoofMsg = CrossGuardIdentity.RiskCallbackMessage({
                identityVersion: CrossGuardIdentity.IDENTITY_VERSION,
                originChainId: ORIGIN_CHAIN,
                originRiskController: address(riskController),
                originVault: attacker,
                originUser: slotOriginUsers[i],
                positionId: CrossGuardIdentity.computePositionId(
                    ORIGIN_CHAIN, address(riskController), attacker, slotOriginUsers[i], slotSalts[i]
                ),
                salt: slotSalts[i],
                nonce: destNonceBefore + 1,
                riskLevel: 9000,
                timestamp: block.timestamp + 1
            });
            (bool ok,) = callbackProxy.executeCallback(
                address(crossGuardCallback),
                abi.encodeCall(crossGuardCallback.handleRiskBreach, (address(0), spoofMsg)),
                300_000,
                address(reactiveContract)
            );
            if (ok) {
                ghostSpoofedReactiveAccepted = true;
            }
        }
    }
}

/// @title M007IdentityInvariantTest
/// @notice Stateful handler-based invariant suite enforcing all 10 M007.1 identity security invariants.
contract M007IdentityInvariantTest is Test {
    uint256 constant ORIGIN_CHAIN = 84532;
    uint256 constant DEST_CHAIN = 1301;
    uint64 constant CALLBACK_GAS_LIMIT = 300_000;

    address owner = address(0xAA);
    uint256 alicePk = 0xA11CE;
    uint256 bobPk = 0xB0B;
    uint256 smartSignerPk = 0x51A7;
    uint256 charliePk = 0xC4A7;

    TestValuationSource oracle;
    RiskController riskController;
    CollateralVault vault;
    CrossGuardReactive reactiveContract;
    MockOmniSystemContract omniSys;
    MockCallbackProxy callbackProxy;
    CrossGuardCallback crossGuardCallback;
    BorrowingController borrowingController;
    MockERC1271Wallet smartWallet;
    M007IdentityHandler handler;

    function setUp() public {
        vm.chainId(ORIGIN_CHAIN);
        vm.startPrank(owner);
        oracle = new TestValuationSource(owner);
        oracle.setAssetPrice(address(0x2222), 1e8); // mockUsdc
        riskController = new RiskController(owner, 8000);
        vault = new CollateralVault(owner, address(oracle), address(riskController));
        riskController.setAuthorizedVault(address(vault), true);

        omniSys = new MockOmniSystemContract();
        callbackProxy = new MockCallbackProxy();
        borrowingController = new BorrowingController(owner, ORIGIN_CHAIN, address(riskController), address(vault));
        reactiveContract = new CrossGuardReactive(
            owner, address(omniSys), ORIGIN_CHAIN, address(riskController), address(vault), DEST_CHAIN, address(0), 0
        );
        crossGuardCallback = new CrossGuardCallback(
            owner, address(callbackProxy), address(borrowingController), address(reactiveContract)
        );
        borrowingController.setCallbackAdapter(address(crossGuardCallback));
        reactiveContract.setDestinationConfig(DEST_CHAIN, address(crossGuardCallback), CALLBACK_GAS_LIMIT);
        vm.stopPrank();

        smartWallet = new MockERC1271Wallet(vm.addr(smartSignerPk));

        handler = new M007IdentityHandler(
            owner,
            oracle,
            riskController,
            vault,
            reactiveContract,
            omniSys,
            callbackProxy,
            crossGuardCallback,
            borrowingController,
            vm.addr(alicePk),
            alicePk,
            vm.addr(bobPk),
            bobPk,
            smartWallet,
            smartSignerPk,
            vm.addr(charliePk),
            charliePk
        );

        targetContract(address(handler));
    }

    function invariant_PositionOwnersBindCanonicalOriginIdentity() public view {
        for (uint256 i = 0; i < handler.NUM_SLOTS(); i++) {
            bytes32 pos = handler.slotPosIds(i);
            address ownerNow = borrowingController.positionOwners(pos);
            if (ownerNow != address(0)) {
                address u = borrowingController.originUsers(pos);
                assertEq(u, handler.slotOriginUsers(i));
                assertEq(borrowingController.positionIdentityVersion(pos), CrossGuardIdentity.IDENTITY_VERSION);
                assertEq(borrowingController.originIdentityHashes(pos), pos);
                bytes32 derived = borrowingController.computePositionId(u, handler.slotSalts(i));
                assertEq(derived, pos);
            }
        }
    }

    function invariant_OriginUserAndIdentityImmutableOnceInitialized() public view {
        assertFalse(handler.ghostIdentityMetadataMutated());
        for (uint256 i = 0; i < handler.NUM_SLOTS(); i++) {
            bytes32 pos = handler.slotPosIds(i);
            if (handler.ghostOriginTupleCaptured(pos)) {
                CrossGuardIdentity.OriginIdentity memory stored = riskController.getPositionIdentity(pos);
                assertTrue(riskController.positionIdentityRegistered(pos));
                assertEq(stored.originChainId, ORIGIN_CHAIN);
                assertEq(stored.originRiskController, address(riskController));
                assertEq(stored.originVault, address(vault));
                assertEq(stored.originUser, handler.slotOriginUsers(i));
                assertEq(stored.salt, handler.slotSalts(i));
            }
        }
    }

    function invariant_NoUnauthorizedOwnerOverwrite() public view {
        assertFalse(handler.ghostUnexpectedOwnerMutation());
    }

    function invariant_UnregisteredRiskResolvedNeverGrantsOwnership() public view {
        for (uint256 i = 0; i < handler.NUM_SLOTS(); i++) {
            bytes32 pos = handler.slotPosIds(i);
            if (!handler.ghostBreachOrExplicitRegistered(pos)) {
                assertEq(borrowingController.positionOwners(pos), address(0));
            }
        }
    }

    function invariant_SigNoncesStrictlyMonotonicAndSingleUse() public view {
        assertFalse(handler.ghostReplaySucceeded());
        for (uint256 i = 0; i < handler.NUM_SLOTS(); i++) {
            address u = handler.slotOriginUsers(i);
            assertGe(borrowingController.sigNonces(u), handler.ghostMinSigNonce(u));
        }
    }

    function invariant_NoUnauthorizedBorrowing() public view {
        assertFalse(handler.ghostUnauthorizedBorrowSucceeded());
        assertFalse(handler.ghostPausedBorrowSucceeded());
    }

    function invariant_OriginVaultAndControllerDomainParity() public view {
        assertEq(address(vault.riskController()), address(riskController));
        assertTrue(riskController.authorizedVaults(address(vault)));
        assertEq(reactiveContract.originChainId(), ORIGIN_CHAIN);
        assertEq(reactiveContract.originRiskController(), address(riskController));
        assertEq(reactiveContract.originCollateralVault(), address(vault));
        assertEq(borrowingController.trustedOriginChainId(), ORIGIN_CHAIN);
        assertEq(borrowingController.trustedOriginRiskController(), address(riskController));
        assertEq(borrowingController.trustedOriginVault(), address(vault));
    }

    function invariant_ReactiveRejectsSpoofedVaultsAndIdentityMismatch() public view {
        assertFalse(handler.ghostSpoofedReactiveAccepted());
    }

    function invariant_CrossWalletDelegatedOwnershipPreservedAcrossBreachAndRecovery() public view {
        for (uint256 i = 0; i < handler.NUM_SLOTS(); i++) {
            bytes32 pos = handler.slotPosIds(i);
            address delegated = handler.ghostDelegatedDestOwner(pos);
            if (delegated != address(0)) {
                assertEq(borrowingController.positionOwners(pos), delegated);
            }
        }
    }

    function invariant_RiskAndAdminPauseOrthogonalityWithCanonicalIdentity() public view {
        for (uint256 i = 0; i < handler.NUM_SLOTS(); i++) {
            bytes32 pos = handler.slotPosIds(i);
            bool expectedPaused = borrowingController.pausedByRiskBreach(pos) || borrowingController.pausedByAdmin(pos);
            assertEq(borrowingController.isBorrowingPaused(pos), expectedPaused);
            assertGe(borrowingController.lastProcessedNonce(pos), handler.ghostMinProcessedNonce(pos));
        }
    }
}

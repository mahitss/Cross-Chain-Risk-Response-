// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {RiskController} from "../../src/origin/RiskController.sol";
import {CrossGuardReactive} from "../../src/reactive/CrossGuardReactive.sol";
import {CrossGuardIdentity} from "../../src/libraries/CrossGuardIdentity.sol";
import {MockOmniSystemContract} from "../mocks/MockOmniSystemContract.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ConfigurationConsistencyTest is Test {
    RiskController riskController;
    CrossGuardReactive reactiveContract;
    MockOmniSystemContract mockSystem;

    address owner = address(0xAA);
    address authorizedVault = address(0x11);
    address destCallback = address(0x22);
    address stranger = address(0x99);

    uint256 constant ORIGIN_CHAIN_ID = 84532; // Base Sepolia
    uint256 constant DEST_CHAIN_ID = 1301; // Unichain Sepolia
    uint64 constant GAS_LIMIT = 300_000;
    bytes32 constant SALT = keccak256("salt-config-1");
    address user = address(0x5555);
    bytes32 positionId;

    function setUp() public {
        mockSystem = new MockOmniSystemContract();

        vm.startPrank(owner);
        riskController = new RiskController(owner, 8000);
        riskController.setAuthorizedVault(authorizedVault, true);

        reactiveContract = new CrossGuardReactive(
            owner,
            address(mockSystem),
            ORIGIN_CHAIN_ID,
            address(riskController),
            authorizedVault,
            DEST_CHAIN_ID,
            destCallback,
            GAS_LIMIT
        );
        vm.stopPrank();

        vm.chainId(ORIGIN_CHAIN_ID);
        positionId = riskController.computePositionId(authorizedVault, user, SALT);
        vm.prank(authorizedVault);
        riskController.registerPositionIdentity(positionId, user, SALT);
    }

    function testOriginIsSoleAuthoritativeRiskPolicy() public view {
        assertEq(riskController.riskThresholdBps(), 8000, "Authoritative origin threshold should be 8000 bps");
        assertEq(reactiveContract.originRiskController(), address(riskController));
        assertEq(reactiveContract.originCollateralVault(), authorizedVault);
        assertEq(reactiveContract.originChainId(), ORIGIN_CHAIN_ID);
        assertEq(reactiveContract.destinationChainId(), DEST_CHAIN_ID);
        assertEq(reactiveContract.destinationCallback(), destCallback);
        assertEq(reactiveContract.callbackGasLimit(), GAS_LIMIT);
    }

    function testAuthoritativeOriginBreachDispatchedWithoutSecondaryFilterSuppression() public {
        vm.prank(authorizedVault);
        (bool isBreached, uint256 currentLtvBps, uint256 nonce) =
            riskController.assessRisk(positionId, user, 10_000e8, 8500e8);

        assertTrue(isBreached, "Origin should identify 8500 bps as breached against 8000 threshold");
        assertEq(currentLtvBps, 8500);

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: nonce,
            data: abi.encode(
                CrossGuardIdentity.IDENTITY_VERSION,
                authorizedVault,
                SALT,
                currentLtvBps,
                uint256(8000),
                block.timestamp
            ),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(mockSystem.requestedCallbackCount(), 1, "Valid origin breach must dispatch destination callback");
    }

    function testSafeOriginStateDoesNotEmitBreach() public {
        vm.prank(authorizedVault);
        (bool isBreached, uint256 currentLtvBps,) = riskController.assessRisk(positionId, user, 10_000e8, 7500e8);

        assertFalse(isBreached, "Origin should NOT breach when LTV is below 8000 bps");
        assertEq(currentLtvBps, 7500);
        assertEq(mockSystem.requestedCallbackCount(), 0, "No callback requested when safe");
    }

    function testSingleAuthoritativePolicyUpdate() public {
        uint256 newThreshold = 7500;
        vm.prank(owner);
        riskController.setRiskThreshold(newThreshold);
        assertEq(riskController.riskThresholdBps(), newThreshold);
    }

    function testDestinationConfigRejectsZeroGasLimit() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidGasLimit.selector, 0));
        reactiveContract.setDestinationConfig(DEST_CHAIN_ID, destCallback, 0);
        vm.stopPrank();
    }

    function testDestinationConfigRejectsUnsupportedChainId() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnsupportedChainId.selector, 0));
        reactiveContract.setDestinationConfig(0, destCallback, GAS_LIMIT);

        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnsupportedChainId.selector, 11155111));
        reactiveContract.setDestinationConfig(11155111, destCallback, GAS_LIMIT);
        vm.stopPrank();
    }

    function testDestinationConfigRejectsZeroCallbackAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(CrossGuardReactive.ZeroAddress.selector);
        reactiveContract.setDestinationConfig(DEST_CHAIN_ID, address(0), GAS_LIMIT);
        vm.stopPrank();
    }

    function testConstructorRejectsUnsupportedChains() public {
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnsupportedChainId.selector, 1));
        new CrossGuardReactive(
            owner,
            address(mockSystem),
            1,
            address(riskController),
            authorizedVault,
            DEST_CHAIN_ID,
            destCallback,
            GAS_LIMIT
        );

        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnsupportedChainId.selector, 11155111));
        new CrossGuardReactive(
            owner,
            address(mockSystem),
            ORIGIN_CHAIN_ID,
            address(riskController),
            authorizedVault,
            11155111,
            destCallback,
            GAS_LIMIT
        );
    }

    function testUnauthorizedConfigChangesRevert() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        riskController.setRiskThreshold(7000);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        riskController.setAuthorizedVault(stranger, true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reactiveContract.setDestinationConfig(DEST_CHAIN_ID, destCallback, GAS_LIMIT);
        vm.stopPrank();
    }

    function testOriginRiskControllerRejectsZeroAddressVault() public {
        vm.prank(owner);
        vm.expectRevert(RiskController.ZeroAddress.selector);
        riskController.setAuthorizedVault(address(0), true);
    }
}

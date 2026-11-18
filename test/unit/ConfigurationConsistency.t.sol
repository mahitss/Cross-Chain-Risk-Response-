// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {RiskController} from "../../src/origin/RiskController.sol";
import {CrossGuardReactive} from "../../src/reactive/CrossGuardReactive.sol";
import {MockOmniSystemContract} from "../mocks/MockOmniSystemContract.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ConfigurationConsistencyTest
/// @notice Tests verifying threshold alignment, configuration parity, mismatch handling,
///         and boundary validation between origin RiskController and CrossGuardReactive.
contract ConfigurationConsistencyTest is Test {
    RiskController riskController;
    CrossGuardReactive reactiveContract;
    MockOmniSystemContract mockSystem;

    address owner = address(0xAA);
    address authorizedVault = address(0x11);
    address destCallback = address(0x22);
    address stranger = address(0x99);

    uint256 constant ORIGIN_CHAIN_ID = 84532;
    uint256 constant DEST_CHAIN_ID = 1301;
    uint64 constant GAS_LIMIT = 300_000;
    bytes32 positionId = keccak256("position-config-1");
    address user = address(0x5555);

    function setUp() public {
        mockSystem = new MockOmniSystemContract();

        vm.startPrank(owner);
        riskController = new RiskController(owner, 8000); // 80% default
        riskController.setAuthorizedVault(authorizedVault, true);

        reactiveContract = new CrossGuardReactive(
            owner,
            address(mockSystem),
            ORIGIN_CHAIN_ID,
            address(riskController),
            DEST_CHAIN_ID,
            destCallback,
            GAS_LIMIT,
            8000 // 80% default
        );
        vm.stopPrank();
    }

    function testInitialConfigurationParity() public view {
        assertEq(
            riskController.riskThresholdBps(),
            reactiveContract.minRiskThresholdBps(),
            "Initial threshold mismatch between origin and reactive"
        );
        assertEq(riskController.riskThresholdBps(), 8000);
    }

    function testSynchronizedPolicyUpdate() public {
        uint256 newThreshold = 7500; // 75%

        vm.startPrank(owner);
        riskController.setRiskThreshold(newThreshold);
        reactiveContract.setMinRiskThresholdBps(newThreshold);
        vm.stopPrank();

        assertEq(riskController.riskThresholdBps(), newThreshold);
        assertEq(reactiveContract.minRiskThresholdBps(), newThreshold);
    }

    function testMismatchReactiveHigherThanOriginIgnoresModerateBreach() public {
        // Origin set to 8000 bps, Reactive updated to 8500 bps
        vm.prank(owner);
        reactiveContract.setMinRiskThresholdBps(8500);

        // Origin triggers breach at 8200 bps
        // Collateral = $10,000 (10000e8), Debt = $8,200 (8200e8) -> LTV = 8200 bps
        vm.prank(authorizedVault);
        (bool isBreached, uint256 currentLtvBps, uint256 nonce) =
            riskController.assessRisk(positionId, user, 10_000e8, 8200e8);

        assertTrue(isBreached, "Origin should consider 8200 bps breached against 8000 threshold");
        assertEq(currentLtvBps, 8200);

        // System contract delivers log to CrossGuardReactive
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(riskController),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: nonce,
            data: abi.encode(currentLtvBps, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        // Because reactive threshold is 8500, it filters out 8200 bps -> 0 callbacks requested
        assertEq(mockSystem.requestedCallbackCount(), 0, "Reactive should have ignored breach below its 8500 threshold");
    }

    function testMismatchReactiveLowerThanOriginDoesNotTriggerPrematurely() public {
        // Origin set to 8500 bps, Reactive set to 8000 bps
        vm.prank(owner);
        riskController.setRiskThreshold(8500);

        // Origin evaluates LTV = 8200 bps (below 8500 bps origin threshold)
        vm.prank(authorizedVault);
        (bool isBreached, uint256 currentLtvBps,) = riskController.assessRisk(positionId, user, 10_000e8, 8200e8);

        // Origin does not breach, so no event is emitted on Base Sepolia
        assertFalse(isBreached, "Origin should NOT breach when LTV is below 8500 bps");
        assertEq(currentLtvBps, 8200);

        // Reactive never receives an event, requestedCallbackCount remains 0
        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testConsistentBoundaryValidation() public {
        // Both contracts reject threshold = 0
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(RiskController.InvalidThreshold.selector, 0));
        riskController.setRiskThreshold(0);

        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidThreshold.selector, 0));
        reactiveContract.setMinRiskThresholdBps(0);

        // Both contracts reject threshold > 10,000 (100% LTV)
        vm.expectRevert(abi.encodeWithSelector(RiskController.InvalidThreshold.selector, 10_001));
        riskController.setRiskThreshold(10_001);

        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidThreshold.selector, 10_001));
        reactiveContract.setMinRiskThresholdBps(10_001);
        vm.stopPrank();
    }

    function testUnauthorizedThresholdChangesRevert() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        riskController.setRiskThreshold(7000);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reactiveContract.setMinRiskThresholdBps(7000);
        vm.stopPrank();
    }
}

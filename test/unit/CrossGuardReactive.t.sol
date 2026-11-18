// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {CrossGuardReactive} from "../../src/reactive/CrossGuardReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "../../src/interfaces/ISystemContract.sol";
import {ICrossGuardCallback} from "../../src/interfaces/ICrossGuardCallback.sol";
import {MockOmniSystemContract} from "../mocks/MockOmniSystemContract.sol";

/// @title CrossGuardReactiveTest
/// @notice Unit tests for CrossGuardReactive verifying Omni system callback dispatch, payload verification,
///         removal of legacy events, and deployment flexibility.
contract CrossGuardReactiveTest is Test {
    CrossGuardReactive reactiveContract;
    MockOmniSystemContract mockSystem;

    address owner = address(0xAA);
    address originRiskController = address(0xBB);
    address destCallback = address(0xCC);
    address stranger = address(0xDD);

    uint256 constant ORIGIN_CHAIN_ID = 84532; // Base Sepolia
    uint256 constant DEST_CHAIN_ID = 1301; // Unichain Sepolia
    uint64 constant GAS_LIMIT = 300_000;
    uint256 constant MIN_THRESHOLD_BPS = 8000;

    bytes32 positionId = keccak256("position-1");
    address user = address(0x1234);

    function setUp() public {
        mockSystem = new MockOmniSystemContract();

        vm.prank(owner);
        reactiveContract = new CrossGuardReactive(
            owner,
            address(mockSystem),
            ORIGIN_CHAIN_ID,
            originRiskController,
            DEST_CHAIN_ID,
            destCallback,
            GAS_LIMIT,
            MIN_THRESHOLD_BPS
        );
    }

    function testDefaultOmniSystemContractAddress() public {
        // When address(0) is passed as _systemContract, it defaults to 0x8888888888888888888888888888888888888888
        address omniSys = 0x8888888888888888888888888888888888888888;
        vm.etch(omniSys, address(mockSystem).code);

        CrossGuardReactive defaultContract = new CrossGuardReactive(
            owner,
            address(0),
            ORIGIN_CHAIN_ID,
            originRiskController,
            DEST_CHAIN_ID,
            destCallback,
            GAS_LIMIT,
            MIN_THRESHOLD_BPS
        );

        assertEq(address(defaultContract.systemContract()), omniSys);
    }

    function testReactDispatchesOmniCallbackV1WithoutLegacyEvent() public {
        uint256 nonce = 42;
        uint256 breachedLtv = 8500;
        uint256 eventTimestamp = block.timestamp;

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: nonce,
            data: abi.encode(breachedLtv, 8000, eventTimestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        bytes memory expectedPayload = abi.encodeWithSignature(
            "handleRiskBreach(address,bytes32,uint256,uint256,uint256)",
            address(0),
            positionId,
            nonce,
            breachedLtv,
            eventTimestamp
        );

        // Calling from authorized system contract succeeds
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
        assertEq(mockSystem.requestedCallbackCount(), 1);

        // Verify complete callback request properties
        ISystemContract.CallbackConfiguration_V_1_0 memory recorded = mockSystem.getLastRequestedCallback();
        assertEq(recorded.chainId, DEST_CHAIN_ID, "Destination chain mismatch");
        assertEq(recorded.recipient, destCallback, "Recipient callback mismatch");
        assertEq(recorded.gasLimit, GAS_LIMIT, "Gas limit mismatch");
        assertEq(recorded.payload, expectedPayload, "Payload mismatch");

        // Verify payload decoding
        bytes4 selector;
        bytes memory p = recorded.payload;
        assembly {
            selector := mload(add(p, 32))
        }
        assertEq(selector, ICrossGuardCallback.handleRiskBreach.selector, "Selector mismatch");
    }

    function testDeployWithUnsetDestinationCallbackAndConfigureLater() public {
        // Allows deploying CrossGuardReactive on Lasna BEFORE destination is deployed on Unichain
        CrossGuardReactive lazyReactive = new CrossGuardReactive(
            owner,
            address(mockSystem),
            ORIGIN_CHAIN_ID,
            originRiskController,
            DEST_CHAIN_ID,
            address(0), // Destination not yet deployed
            GAS_LIMIT,
            MIN_THRESHOLD_BPS
        );

        assertEq(lazyReactive.destinationCallback(), address(0));

        // When log arrives before destination is set, react() returns early without dispatching
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(lazyReactive.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(mockSystem));
        lazyReactive.react(log);
        assertEq(mockSystem.requestedCallbackCount(), 0);

        // Now link destination callback post-deployment
        vm.prank(owner);
        lazyReactive.setDestinationConfig(DEST_CHAIN_ID, destCallback, GAS_LIMIT);

        // Next reactive trigger dispatches callback successfully
        vm.prank(address(mockSystem));
        lazyReactive.react(log);
        assertEq(mockSystem.requestedCallbackCount(), 1);
    }

    function testRevertReactUnauthorizedCaller() public {
        IReactive.LogRecord memory log;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnauthorizedCaller.selector, stranger));
        reactiveContract.react(log);
    }

    function testReactIgnoresWrongChainId() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: 1, // Mainnet instead of Base Sepolia
            _contract: originRiskController,
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testReactIgnoresWrongEmitter() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(0xDEAD),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testReactIgnoresWrongTopic() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(keccak256("SomeOtherEvent()")),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testReactIgnoresBelowThreshold() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(7000, 8000, block.timestamp), // 70% < 80%
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testSetDestinationConfig() public {
        address newCallback = address(0x999);
        vm.prank(owner);
        reactiveContract.setDestinationConfig(11155111, newCallback, 500_000);

        assertEq(reactiveContract.destinationChainId(), 11155111);
        assertEq(reactiveContract.destinationCallback(), newCallback);
        assertEq(reactiveContract.callbackGasLimit(), 500_000);

        vm.prank(owner);
        vm.expectRevert(CrossGuardReactive.ZeroAddress.selector);
        reactiveContract.setDestinationConfig(11155111, address(0), 500_000);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidChainId.selector, 0));
        reactiveContract.setDestinationConfig(0, newCallback, 500_000);
    }

    function testSetMinRiskThresholdBpsValidations() public {
        vm.prank(owner);
        reactiveContract.setMinRiskThresholdBps(8500);
        assertEq(reactiveContract.minRiskThresholdBps(), 8500);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidThreshold.selector, 0));
        reactiveContract.setMinRiskThresholdBps(0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidThreshold.selector, 10_001));
        reactiveContract.setMinRiskThresholdBps(10_001);
    }

    function testConstructorValidations() public {
        vm.expectRevert(CrossGuardReactive.ZeroAddress.selector);
        new CrossGuardReactive(
            owner,
            address(mockSystem),
            ORIGIN_CHAIN_ID,
            address(0),
            DEST_CHAIN_ID,
            destCallback,
            GAS_LIMIT,
            MIN_THRESHOLD_BPS
        );

        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidChainId.selector, 0));
        new CrossGuardReactive(
            owner,
            address(mockSystem),
            0,
            originRiskController,
            DEST_CHAIN_ID,
            destCallback,
            GAS_LIMIT,
            MIN_THRESHOLD_BPS
        );

        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidThreshold.selector, 0));
        new CrossGuardReactive(
            owner, address(mockSystem), ORIGIN_CHAIN_ID, originRiskController, DEST_CHAIN_ID, destCallback, GAS_LIMIT, 0
        );

        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidThreshold.selector, 10_001));
        new CrossGuardReactive(
            owner,
            address(mockSystem),
            ORIGIN_CHAIN_ID,
            originRiskController,
            DEST_CHAIN_ID,
            destCallback,
            GAS_LIMIT,
            10_001
        );
    }
}

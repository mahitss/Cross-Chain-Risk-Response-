// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {CrossGuardReactive} from "../../src/reactive/CrossGuardReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "../../src/interfaces/ISystemContract.sol";
import {MockOmniSystemContract} from "../mocks/MockOmniSystemContract.sol";

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
        // Mock bytecode at omniSys so constructor subscribe doesn't revert
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

    function testReactEmitsCallbackAndCallsSystemV1() public {
        uint256 nonce = 42;
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: nonce,
            data: abi.encode(8500, 8000, block.timestamp),
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
            8500,
            block.timestamp
        );

        vm.expectEmit(true, true, true, true);
        emit IReactive.Callback(DEST_CHAIN_ID, destCallback, GAS_LIMIT, expectedPayload);

        // Calling from authorized system contract succeeds
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
        assertEq(mockSystem.requestedCallbackCount(), 1);

        ISystemContract.CallbackConfiguration_V_1_0 memory recorded = mockSystem.getLastRequestedCallback();
        assertEq(recorded.chainId, DEST_CHAIN_ID);
        assertEq(recorded.recipient, destCallback);
        assertEq(recorded.gasLimit, GAS_LIMIT);
        assertEq(recorded.payload, expectedPayload);
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

        vm.expectRevert(CrossGuardReactive.ZeroAddress.selector);
        new CrossGuardReactive(
            owner,
            address(mockSystem),
            ORIGIN_CHAIN_ID,
            originRiskController,
            DEST_CHAIN_ID,
            address(0),
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

        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidChainId.selector, 0));
        new CrossGuardReactive(
            owner,
            address(mockSystem),
            ORIGIN_CHAIN_ID,
            originRiskController,
            0,
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

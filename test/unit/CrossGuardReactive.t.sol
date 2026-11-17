// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {CrossGuardReactive} from "../../src/reactive/CrossGuardReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CrossGuardReactiveTest is Test {
    CrossGuardReactive reactiveContract;

    address owner = address(0xAA);
    address originRiskController = address(0xBB);
    address destCallback = address(0xCC);
    address stranger = address(0xDD);

    uint256 constant ORIGIN_CHAIN_ID = 84532; // Base Sepolia
    uint256 constant DEST_CHAIN_ID = 1301;   // Unichain Sepolia
    uint64 constant GAS_LIMIT = 300_000;
    uint256 constant MIN_THRESHOLD_BPS = 8000;

    bytes32 positionId = keccak256("position-1");
    address user = address(0x1234);

    function setUp() public {
        address serviceAddr = address(0x0000000000000000000000000000000000fffFfF);
        vm.etch(serviceAddr, hex"00");

        vm.prank(owner);
        reactiveContract = new CrossGuardReactive(
            owner,
            address(0), // default service
            ORIGIN_CHAIN_ID,
            originRiskController,
            DEST_CHAIN_ID,
            destCallback,
            GAS_LIMIT,
            MIN_THRESHOLD_BPS
        );
    }

    function testReactEmitsCallbackOnBreach() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 0,
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        bytes memory expectedPayload = abi.encodeWithSignature(
            "handleRiskBreach(address,bytes32,uint256,uint256)",
            address(0),
            positionId,
            8500,
            block.timestamp
        );

        vm.expectEmit(true, true, true, true);
        emit IReactive.Callback(DEST_CHAIN_ID, destCallback, GAS_LIMIT, expectedPayload);

        vm.prank(address(0x0000000000000000000000000000000000fffFfF));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
    }

    function testReactIgnoresWrongChainId() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: 1, // Mainnet instead of Base Sepolia
            _contract: originRiskController,
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 0,
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(0x0000000000000000000000000000000000fffFfF));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
    }

    function testReactIgnoresWrongEmitter() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(0xDEAD),
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 0,
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(0x0000000000000000000000000000000000fffFfF));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
    }

    function testReactIgnoresWrongTopic() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(keccak256("SomeOtherEvent()")),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 0,
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(0x0000000000000000000000000000000000fffFfF));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
    }

    function testReactIgnoresBelowThreshold() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 0,
            data: abi.encode(7000, 8000, block.timestamp), // 70% < 80%
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(0x0000000000000000000000000000000000fffFfF));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
    }

    function testRevertReactUnauthorizedCaller() public {
        IReactive.LogRecord memory log;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnauthorizedCaller.selector, stranger));
        reactiveContract.react(log);
    }

    function testSetDestinationConfig() public {
        address newCallback = address(0x999);
        vm.prank(owner);
        reactiveContract.setDestinationConfig(11155111, newCallback, 500_000);

        assertEq(reactiveContract.destinationChainId(), 11155111);
        assertEq(reactiveContract.destinationCallback(), newCallback);
        assertEq(reactiveContract.callbackGasLimit(), 500_000);
    }

    function testSetMinRiskThresholdBps() public {
        vm.prank(owner);
        reactiveContract.setMinRiskThresholdBps(8500);
        assertEq(reactiveContract.minRiskThresholdBps(), 8500);
    }

    function testConstructorValidations() public {
        vm.expectRevert(CrossGuardReactive.ZeroAddress.selector);
        new CrossGuardReactive(owner, address(0), ORIGIN_CHAIN_ID, address(0), DEST_CHAIN_ID, destCallback, GAS_LIMIT, MIN_THRESHOLD_BPS);

        vm.expectRevert(CrossGuardReactive.ZeroAddress.selector);
        new CrossGuardReactive(owner, address(0), ORIGIN_CHAIN_ID, originRiskController, DEST_CHAIN_ID, address(0), GAS_LIMIT, MIN_THRESHOLD_BPS);

        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidChainId.selector, 0));
        new CrossGuardReactive(owner, address(0), 0, originRiskController, DEST_CHAIN_ID, destCallback, GAS_LIMIT, MIN_THRESHOLD_BPS);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {CrossGuardReactive} from "../../src/reactive/CrossGuardReactive.sol";
import {MockOmniSystemContract} from "../mocks/MockOmniSystemContract.sol";
import {ISystemContract} from "../../src/interfaces/ISystemContract.sol";
import {ICrossGuardCallback} from "../../src/interfaces/ICrossGuardCallback.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

/// @title CrossGuardReactiveTest
/// @notice Comprehensive unit tests for CrossGuardReactive running on Reactive Lasna (5318007).
///         Validates constructor configuration, log filtering, single authoritative policy
///         forwarding, zero gas limit rejection, and Omni v1 callback generation.
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

    bytes32 positionId = keccak256("position-1");
    address user = address(0x1234);

    function setUp() public {
        mockSystem = new MockOmniSystemContract();

        vm.prank(owner);
        reactiveContract = new CrossGuardReactive(
            owner, address(mockSystem), ORIGIN_CHAIN_ID, originRiskController, DEST_CHAIN_ID, destCallback, GAS_LIMIT
        );
    }

    function testDefaultOmniSystemContractAddress() public {
        // When address(0) is passed as _systemContract, it defaults to 0x8888888888888888888888888888888888888888
        address omniSys = 0x8888888888888888888888888888888888888888;
        vm.etch(omniSys, address(mockSystem).code);

        CrossGuardReactive defaultContract = new CrossGuardReactive(
            owner, address(0), ORIGIN_CHAIN_ID, originRiskController, DEST_CHAIN_ID, destCallback, GAS_LIMIT
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

        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
        assertEq(mockSystem.requestedCallbackCount(), 1);

        ISystemContract.CallbackConfiguration_V_1_0 memory cbReq = mockSystem.getLastRequestedCallback();
        assertEq(cbReq.chainId, DEST_CHAIN_ID);
        assertEq(cbReq.recipient, destCallback);
        assertEq(cbReq.gasLimit, GAS_LIMIT);
        assertEq(cbReq.payload, expectedPayload);

        // Verify payload format
        bytes4 selector;
        bytes memory p = cbReq.payload;
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
            0
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

    function testAuthoritativeOriginBreachDispatchedEvenWithModerateLtv() public {
        // Origin RiskController is sole authority. If origin emitted RiskBreach,
        // CrossGuardReactive unconditionally dispatches the callback without secondary threshold filtering.
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(reactiveContract.RISK_BREACH_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(7000, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
        assertEq(mockSystem.requestedCallbackCount(), 1);
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

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidGasLimit.selector, 0));
        reactiveContract.setDestinationConfig(11155111, newCallback, 0);
    }

    function testConstructorValidations() public {
        vm.expectRevert(CrossGuardReactive.ZeroAddress.selector);
        new CrossGuardReactive(
            owner, address(mockSystem), ORIGIN_CHAIN_ID, address(0), DEST_CHAIN_ID, destCallback, GAS_LIMIT
        );

        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidChainId.selector, 0));
        new CrossGuardReactive(
            owner, address(mockSystem), 0, originRiskController, DEST_CHAIN_ID, destCallback, GAS_LIMIT
        );

        // When destCallback is provided, gasLimit == 0 must revert
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidGasLimit.selector, 0));
        new CrossGuardReactive(
            owner, address(mockSystem), ORIGIN_CHAIN_ID, originRiskController, DEST_CHAIN_ID, destCallback, 0
        );

        // When destCallback is provided, destChainId == 0 must revert
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidChainId.selector, 0));
        new CrossGuardReactive(
            owner, address(mockSystem), ORIGIN_CHAIN_ID, originRiskController, 0, destCallback, GAS_LIMIT
        );
    }

    function testReactDispatchesOmniCallbackForRiskResolved() public {
        uint256 nonce = 43;
        uint256 recoveredLtv = 4500;
        uint256 eventTimestamp = block.timestamp;

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(reactiveContract.RISK_RESOLVED_TOPIC_0()),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: nonce,
            data: abi.encode(recoveredLtv, 8000, eventTimestamp),
            block_number: 101,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        bytes memory expectedPayload = abi.encodeWithSignature(
            "handleRiskResolved(address,bytes32,uint256,uint256,uint256)",
            address(0),
            positionId,
            nonce,
            recoveredLtv,
            eventTimestamp
        );

        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
        assertEq(mockSystem.requestedCallbackCount(), 1);

        ISystemContract.CallbackConfiguration_V_1_0 memory cbReq = mockSystem.getLastRequestedCallback();
        assertEq(cbReq.chainId, DEST_CHAIN_ID);
        assertEq(cbReq.recipient, destCallback);
        assertEq(cbReq.gasLimit, GAS_LIMIT);
        assertEq(cbReq.payload, expectedPayload);
    }

    function testReceiveAndWithdraw() public {
        vm.deal(address(reactiveContract), 1 ether);
        assertEq(address(reactiveContract).balance, 1 ether);

        address payable payout = payable(address(0x8888));
        vm.prank(owner);
        reactiveContract.withdraw(payout, 0.4 ether);
        assertEq(payout.balance, 0.4 ether);
        assertEq(address(reactiveContract).balance, 0.6 ether);

        vm.prank(owner);
        vm.expectRevert(CrossGuardReactive.ZeroAddress.selector);
        reactiveContract.withdraw(payable(address(0)), 0.1 ether);
    }

    function testPayReverts() public {
        vm.expectRevert("Not implemented");
        reactiveContract.pay(100);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {CrossGuardReactive} from "../../src/reactive/CrossGuardReactive.sol";
import {MockOmniSystemContract} from "../mocks/MockOmniSystemContract.sol";
import {ISystemContract} from "../../src/interfaces/ISystemContract.sol";
import {ICrossGuardCallback} from "../../src/interfaces/ICrossGuardCallback.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CrossGuardReactiveTest
/// @notice Comprehensive unit tests for CrossGuardReactive running on Reactive Lasna (5318007).
///         Validates constructor configuration, strict event parsing and validation,
///         fail-closed malformed event handling, supported-chain allowlisting,
///         and Omni v1 callback generation.
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

    bytes32 constant RISK_BREACH_TOPIC_0 = keccak256("RiskBreach(bytes32,address,uint256,uint256,uint256,uint256)");
    bytes32 constant RISK_RESOLVED_TOPIC_0 = keccak256("RiskResolved(bytes32,address,uint256,uint256,uint256,uint256)");

    bytes32 positionId = keccak256("position-1");
    address user = address(0x1234);

    event ReactiveEventRejected(
        bytes32 indexed topic0, bytes32 indexed positionId, uint256 indexed nonce, string reason
    );

    function setUp() public {
        mockSystem = new MockOmniSystemContract();

        vm.prank(owner);
        reactiveContract = new CrossGuardReactive(
            owner, address(mockSystem), ORIGIN_CHAIN_ID, originRiskController, DEST_CHAIN_ID, destCallback, GAS_LIMIT
        );
    }

    function testDefaultOmniSystemContractAddress() public {
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
            topic_0: uint256(RISK_BREACH_TOPIC_0),
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

    function testReactDispatchesOmniCallbackForRiskResolved() public {
        uint256 nonce = 43;
        uint256 recoveredLtv = 4500;
        uint256 eventTimestamp = block.timestamp;

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_RESOLVED_TOPIC_0),
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

    function testReactRejectsEmptyData() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: hex"", // Empty data length = 0 != 96
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, positionId, 1, "INVALID_DATA_LENGTH");
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(mockSystem.requestedCallbackCount(), 0, "Empty data must not trigger callback");
    }

    function testReactRejectsTruncatedData() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(uint256(8500), uint256(8000)), // Truncated: 64 bytes instead of 96
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, positionId, 1, "INVALID_DATA_LENGTH");
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(mockSystem.requestedCallbackCount(), 0, "Truncated data must not trigger callback");
    }

    function testReactRejectsOversizedData() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(uint256(8500), uint256(8000), uint256(block.timestamp), uint256(9999)), // 128 bytes
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, positionId, 1, "INVALID_DATA_LENGTH");
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(mockSystem.requestedCallbackCount(), 0, "Oversized data must not trigger callback");
    }

    function testReactRejectsInvalidIndexedUserAddressEncoding() public {
        uint256 malformedAddressWord = (uint256(1) << 160) | uint256(uint160(user));

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
            topic_1: uint256(positionId),
            topic_2: malformedAddressWord,
            topic_3: 1,
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, positionId, 1, "INVALID_INDEXED_USER");
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testReactRejectsZeroIndexedUserAddress() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
            topic_1: uint256(positionId),
            topic_2: 0, // address(0)
            topic_3: 1,
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, positionId, 1, "INVALID_INDEXED_USER");
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testReactRejectsZeroPositionId() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
            topic_1: 0, // bytes32(0)
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, bytes32(0), 1, "ZERO_POSITION_ID");
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testReactRejectsZeroNonce() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 0, // Zero nonce
            data: abi.encode(8500, 8000, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, positionId, 0, "ZERO_NONCE");
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testReactRejectsInvalidThreshold() public {
        // Zero threshold
        IReactive.LogRecord memory log1 = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(8500, 0, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, positionId, 1, "INVALID_THRESHOLD");
        vm.prank(address(mockSystem));
        reactiveContract.react(log1);

        // Threshold > 10,000 (100% LTV)
        IReactive.LogRecord memory log2 = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(8500, 10_001, block.timestamp),
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, positionId, 1, "INVALID_THRESHOLD");
        vm.prank(address(mockSystem));
        reactiveContract.react(log2);

        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testReactRejectsZeroTimestamp() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(8500, 8000, 0), // Timestamp = 0
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, positionId, 1, "INVALID_TIMESTAMP");
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testReactRejectsBreachWithLtvBelowThreshold() public {
        // Semantic validation: a breach event must have currentLtvBps >= riskThresholdBps
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(7500, 8000, block.timestamp), // 75% < 80% threshold
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, positionId, 1, "BREACH_BELOW_THRESHOLD");
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testReactRejectsResolutionWithLtvAtOrAboveThreshold() public {
        // Semantic validation: a resolution event must have currentLtvBps < riskThresholdBps
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_RESOLVED_TOPIC_0),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(8000, 8000, block.timestamp), // 80% >= 80% threshold
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_RESOLVED_TOPIC_0, positionId, 1, "RESOLVED_NOT_BELOW_THRESHOLD");
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testReactIgnoresWrongChainId() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: 1, // Mainnet instead of Base Sepolia
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
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

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, positionId, 1, "WRONG_CHAIN_ID");
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testReactIgnoresWrongEmitter() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(0xDEAD),
            topic_0: uint256(RISK_BREACH_TOPIC_0),
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

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, positionId, 1, "WRONG_EMITTER");
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testReactIgnoresWrongTopic() public {
        bytes32 wrongTopic = keccak256("SomeOtherEvent()");
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(wrongTopic),
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

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(wrongTopic, positionId, 1, "WRONG_EVENT_TOPIC");
        vm.prank(address(mockSystem));
        reactiveContract.react(log);

        assertEq(reactiveContract.reactCount(), 1);
        assertEq(mockSystem.requestedCallbackCount(), 0);
    }

    function testRevertReactUnauthorizedCaller() public {
        IReactive.LogRecord memory log;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnauthorizedCaller.selector, stranger));
        reactiveContract.react(log);
    }

    function testAuthoritativeOriginBreachDispatchedEvenWithModerateLtv() public {
        // Position breaches at 7500 bps against origin threshold 7000 bps
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
            topic_1: uint256(positionId),
            topic_2: uint256(uint160(user)),
            topic_3: 1,
            data: abi.encode(7500, 7000, block.timestamp),
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

    function testDeployWithUnsetDestinationCallbackAndConfigureLater() public {
        // Allows deploying CrossGuardReactive on Lasna BEFORE destination is deployed on Unichain
        CrossGuardReactive lazyReactive = new CrossGuardReactive(
            owner, address(mockSystem), ORIGIN_CHAIN_ID, originRiskController, DEST_CHAIN_ID, address(0), 0
        );

        assertEq(lazyReactive.destinationCallback(), address(0));
        assertEq(lazyReactive.destinationChainId(), 0);
        assertEq(lazyReactive.callbackGasLimit(), 0);

        // When log arrives before destination is set, react() returns early without dispatching
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: originRiskController,
            topic_0: uint256(RISK_BREACH_TOPIC_0),
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

        vm.expectEmit(true, true, true, true);
        emit ReactiveEventRejected(RISK_BREACH_TOPIC_0, positionId, 1, "DESTINATION_NOT_CONFIGURED");
        vm.prank(address(mockSystem));
        lazyReactive.react(log);
        assertEq(mockSystem.requestedCallbackCount(), 0);

        // Now link destination callback post-deployment
        vm.prank(owner);
        lazyReactive.setDestinationConfig(DEST_CHAIN_ID, destCallback, GAS_LIMIT);

        assertEq(lazyReactive.destinationCallback(), destCallback);
        assertEq(lazyReactive.destinationChainId(), DEST_CHAIN_ID);
        assertEq(lazyReactive.callbackGasLimit(), GAS_LIMIT);

        // Next reactive trigger dispatches callback successfully
        vm.prank(address(mockSystem));
        lazyReactive.react(log);
        assertEq(mockSystem.requestedCallbackCount(), 1);
    }

    function testSetDestinationConfig() public {
        address newCallback = address(0x999);
        vm.prank(owner);
        reactiveContract.setDestinationConfig(DEST_CHAIN_ID, newCallback, 500_000);

        assertEq(reactiveContract.destinationChainId(), DEST_CHAIN_ID);
        assertEq(reactiveContract.destinationCallback(), newCallback);
        assertEq(reactiveContract.callbackGasLimit(), 500_000);

        vm.startPrank(owner);
        // Zero callback address rejected
        vm.expectRevert(CrossGuardReactive.ZeroAddress.selector);
        reactiveContract.setDestinationConfig(DEST_CHAIN_ID, address(0), 500_000);

        // Unsupported destination chain ID rejected
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnsupportedChainId.selector, 0));
        reactiveContract.setDestinationConfig(0, newCallback, 500_000);

        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnsupportedChainId.selector, 11155111));
        reactiveContract.setDestinationConfig(11155111, newCallback, 500_000);

        // Zero gas limit rejected
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidGasLimit.selector, 0));
        reactiveContract.setDestinationConfig(DEST_CHAIN_ID, newCallback, 0);
        vm.stopPrank();

        // Stranger cannot update destination config
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reactiveContract.setDestinationConfig(DEST_CHAIN_ID, newCallback, 500_000);
    }

    function testConstructorValidations() public {
        // Zero origin controller rejected
        vm.expectRevert(CrossGuardReactive.ZeroAddress.selector);
        new CrossGuardReactive(
            owner, address(mockSystem), ORIGIN_CHAIN_ID, address(0), DEST_CHAIN_ID, destCallback, GAS_LIMIT
        );

        // Unsupported origin chain rejected
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnsupportedChainId.selector, 0));
        new CrossGuardReactive(
            owner, address(mockSystem), 0, originRiskController, DEST_CHAIN_ID, destCallback, GAS_LIMIT
        );

        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnsupportedChainId.selector, 1));
        new CrossGuardReactive(
            owner, address(mockSystem), 1, originRiskController, DEST_CHAIN_ID, destCallback, GAS_LIMIT
        );

        // Unsupported destination chain rejected when callback provided
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnsupportedChainId.selector, 0));
        new CrossGuardReactive(
            owner, address(mockSystem), ORIGIN_CHAIN_ID, originRiskController, 0, destCallback, GAS_LIMIT
        );

        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnsupportedChainId.selector, 11155111));
        new CrossGuardReactive(
            owner, address(mockSystem), ORIGIN_CHAIN_ID, originRiskController, 11155111, destCallback, GAS_LIMIT
        );

        // Zero gas limit rejected when callback provided
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.InvalidGasLimit.selector, 0));
        new CrossGuardReactive(
            owner, address(mockSystem), ORIGIN_CHAIN_ID, originRiskController, DEST_CHAIN_ID, destCallback, 0
        );

        // Unsupported destination chain rejected even when callback is address(0)
        vm.expectRevert(abi.encodeWithSelector(CrossGuardReactive.UnsupportedChainId.selector, 9999));
        new CrossGuardReactive(owner, address(mockSystem), ORIGIN_CHAIN_ID, originRiskController, 9999, address(0), 0);
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

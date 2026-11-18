// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {CrossGuardCallback} from "../../src/destination/CrossGuardCallback.sol";
import {BorrowingController} from "../../src/destination/BorrowingController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CrossGuardCallbackTest
/// @notice Unit tests for destination callback adapter verifying Omni injected Reactive contract address semantics.
contract CrossGuardCallbackTest is Test {
    CrossGuardCallback callbackReceiver;
    BorrowingController borrowingController;

    address owner = address(0xAA);
    address callbackProxy = address(0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4); // Unichain official proxy
    address deployedReactiveContract = address(0x5318007001); // Simulated Lasna contract address
    address forgedReactiveSender = address(0xDEADBEEF);
    address legacyRvmId = address(uint160(uint256(keccak256("legacy-rvm-id"))));
    address stranger = address(0xDD);
    bytes32 positionId = keccak256("position-1");

    function setUp() public {
        vm.startPrank(owner);
        borrowingController = new BorrowingController(owner);
        callbackReceiver =
            new CrossGuardCallback(owner, callbackProxy, address(borrowingController), deployedReactiveContract);
        borrowingController.setCallbackAdapter(address(callbackReceiver));
        vm.stopPrank();
    }

    function testHandleRiskBreachSuccessWithOmniReactiveAddress() public {
        // Omni relayer injects deployed Reactive contract address as reactiveSender
        vm.prank(callbackProxy);
        callbackReceiver.handleRiskBreach(deployedReactiveContract, positionId, 1, 8500, block.timestamp);

        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);
    }

    function testRevertWhenUnauthorizedProxyCalls() public {
        address fakeProxy = address(0xEE);
        vm.prank(fakeProxy);
        vm.expectRevert("Authorized sender only");
        callbackReceiver.handleRiskBreach(deployedReactiveContract, positionId, 1, 8500, block.timestamp);
    }

    function testRevertWhenForgedReactiveSenderCalls() public {
        vm.prank(callbackProxy);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrossGuardCallback.UnauthorizedReactiveSender.selector, forgedReactiveSender, deployedReactiveContract
            )
        );
        callbackReceiver.handleRiskBreach(forgedReactiveSender, positionId, 1, 8500, block.timestamp);
    }

    function testRevertWhenLegacyRvmIdUsedInsteadOfDeployedContractAddress() public {
        // Verifies that assumptions based on legacy RVM IDs are rejected when configured for deployed contract address
        vm.prank(callbackProxy);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrossGuardCallback.UnauthorizedReactiveSender.selector, legacyRvmId, deployedReactiveContract
            )
        );
        callbackReceiver.handleRiskBreach(legacyRvmId, positionId, 1, 8500, block.timestamp);
    }

    function testConstructorRejectsZeroAuthorizedReactiveSender() public {
        vm.expectRevert(CrossGuardCallback.ZeroAddress.selector);
        new CrossGuardCallback(owner, callbackProxy, address(borrowingController), address(0));
    }

    function testSetAuthorizedReactiveSenderRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(CrossGuardCallback.ZeroAddress.selector);
        callbackReceiver.setAuthorizedReactiveSender(address(0));
    }

    function testSetAuthorizedReactiveSenderSuccess() public {
        address newReactiveContract = address(0x5318007002);
        vm.prank(owner);
        callbackReceiver.setAuthorizedReactiveSender(newReactiveContract);
        assertEq(callbackReceiver.authorizedReactiveSender(), newReactiveContract);

        // New contract succeeds
        vm.prank(callbackProxy);
        callbackReceiver.handleRiskBreach(newReactiveContract, positionId, 1, 8500, block.timestamp);
        assertTrue(borrowingController.isBorrowingPaused(positionId));

        // Old contract now reverts
        vm.prank(callbackProxy);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrossGuardCallback.UnauthorizedReactiveSender.selector, deployedReactiveContract, newReactiveContract
            )
        );
        callbackReceiver.handleRiskBreach(deployedReactiveContract, positionId, 2, 8500, block.timestamp);
    }

    function testSetBorrowingController() public {
        address newController = address(0x888);
        vm.prank(owner);
        callbackReceiver.setBorrowingController(newController);
        assertEq(callbackReceiver.borrowingController(), newController);

        vm.prank(owner);
        vm.expectRevert(CrossGuardCallback.ZeroAddress.selector);
        callbackReceiver.setBorrowingController(address(0));
    }

    function testRevertWhenNonOwnerSetsConfig() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        callbackReceiver.setAuthorizedReactiveSender(address(0x123));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        callbackReceiver.setBorrowingController(address(0x123));
    }

    function testConstructorZeroAddressReverts() public {
        vm.expectRevert(CrossGuardCallback.ZeroAddress.selector);
        new CrossGuardCallback(owner, address(0), address(borrowingController), deployedReactiveContract);

        vm.expectRevert(CrossGuardCallback.ZeroAddress.selector);
        new CrossGuardCallback(owner, callbackProxy, address(0), deployedReactiveContract);
    }
}

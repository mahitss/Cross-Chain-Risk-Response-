// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {CrossGuardCallback} from "../../src/destination/CrossGuardCallback.sol";
import {BorrowingController} from "../../src/destination/BorrowingController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CrossGuardCallbackTest is Test {
    CrossGuardCallback callbackReceiver;
    BorrowingController borrowingController;

    address owner = address(0xAA);
    address callbackProxy = address(0xBB);
    address authorizedRvm = address(0xCC);
    address stranger = address(0xDD);
    bytes32 positionId = keccak256("position-1");

    function setUp() public {
        vm.startPrank(owner);
        borrowingController = new BorrowingController(owner);
        callbackReceiver = new CrossGuardCallback(
            owner,
            callbackProxy,
            address(borrowingController),
            authorizedRvm
        );
        borrowingController.setCallbackAdapter(address(callbackReceiver));
        vm.stopPrank();
    }

    function testHandleRiskBreachSuccess() public {
        vm.prank(callbackProxy);
        callbackReceiver.handleRiskBreach(authorizedRvm, positionId, 8500, block.timestamp);

        assertTrue(borrowingController.isBorrowingPaused(positionId));
    }

    function testRevertWhenUnauthorizedProxyCalls() public {
        address fakeProxy = address(0xEE);
        vm.prank(fakeProxy);
        vm.expectRevert("Authorized sender only");
        callbackReceiver.handleRiskBreach(authorizedRvm, positionId, 8500, block.timestamp);
    }

    function testRevertWhenUnauthorizedRvmCalls() public {
        address fakeRvm = address(0xEE);
        vm.prank(callbackProxy);
        vm.expectRevert(
            abi.encodeWithSelector(CrossGuardCallback.UnauthorizedRvmSender.selector, fakeRvm, authorizedRvm)
        );
        callbackReceiver.handleRiskBreach(fakeRvm, positionId, 8500, block.timestamp);
    }

    function testSetAuthorizedReactiveSender() public {
        address newRvm = address(0x999);
        vm.prank(owner);
        callbackReceiver.setAuthorizedReactiveSender(newRvm);
        assertEq(callbackReceiver.authorizedReactiveSender(), newRvm);

        vm.prank(owner);
        vm.expectRevert(CrossGuardCallback.ZeroAddress.selector);
        callbackReceiver.setAuthorizedReactiveSender(address(0));
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
        new CrossGuardCallback(owner, address(0), address(borrowingController), authorizedRvm);

        vm.expectRevert(CrossGuardCallback.ZeroAddress.selector);
        new CrossGuardCallback(owner, callbackProxy, address(0), authorizedRvm);
    }
}

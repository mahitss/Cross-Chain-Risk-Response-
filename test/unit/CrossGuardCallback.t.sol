// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {CrossGuardCallback} from "../../src/destination/CrossGuardCallback.sol";
import {BorrowingController} from "../../src/destination/BorrowingController.sol";
import {ICrossGuardCallback} from "../../src/interfaces/ICrossGuardCallback.sol";
import {CrossGuardIdentity} from "../../src/libraries/CrossGuardIdentity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CrossGuardCallbackTest is Test {
    CrossGuardCallback callbackReceiver;
    BorrowingController borrowingController;

    address owner = address(0xAA);
    address callbackProxy = address(0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4);
    address deployedReactiveContract = address(0x5318007001);
    address forgedReactiveSender = address(0xDEADBEEF);
    address legacyRvmId = address(uint160(uint256(keccak256("legacy-rvm-id"))));
    address stranger = address(0xDD);

    uint256 constant ORIGIN_CHAIN_ID = 84532;
    address constant ORIGIN_RISK_CTRL = address(0x1111);
    address constant ORIGIN_VAULT = address(0x2222);
    address originUser = address(0x3333);
    bytes32 constant SALT = keccak256("callback-salt-1");
    bytes32 positionId;

    function setUp() public {
        vm.startPrank(owner);
        borrowingController = new BorrowingController(owner, ORIGIN_CHAIN_ID, ORIGIN_RISK_CTRL, ORIGIN_VAULT);
        callbackReceiver =
            new CrossGuardCallback(owner, callbackProxy, address(borrowingController), deployedReactiveContract);
        borrowingController.setCallbackAdapter(address(callbackReceiver));
        vm.stopPrank();

        positionId =
            CrossGuardIdentity.computePositionId(ORIGIN_CHAIN_ID, ORIGIN_RISK_CTRL, ORIGIN_VAULT, originUser, SALT);
    }

    function _msg(bytes32 posId, uint256 nonce, uint256 ltv, uint256 ts)
        internal
        view
        returns (CrossGuardIdentity.RiskCallbackMessage memory)
    {
        return CrossGuardIdentity.RiskCallbackMessage({
            identityVersion: CrossGuardIdentity.IDENTITY_VERSION,
            originChainId: ORIGIN_CHAIN_ID,
            originRiskController: ORIGIN_RISK_CTRL,
            originVault: ORIGIN_VAULT,
            originUser: originUser,
            positionId: posId,
            salt: SALT,
            nonce: nonce,
            riskLevel: ltv,
            timestamp: ts
        });
    }

    function testHandleRiskBreachSuccessWithOmniReactiveAddress() public {
        vm.prank(callbackProxy);
        callbackReceiver.handleRiskBreach(deployedReactiveContract, _msg(positionId, 1, 8500, block.timestamp));

        assertTrue(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 1);
        assertEq(borrowingController.originUsers(positionId), originUser);
    }

    function testRevertWhenUnauthorizedProxyCalls() public {
        address fakeProxy = address(0xEE);
        vm.prank(fakeProxy);
        vm.expectRevert("Authorized sender only");
        callbackReceiver.handleRiskBreach(deployedReactiveContract, _msg(positionId, 1, 8500, block.timestamp));
    }

    function testRevertWhenForgedReactiveSenderCalls() public {
        vm.prank(callbackProxy);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrossGuardCallback.UnauthorizedReactiveSender.selector, forgedReactiveSender, deployedReactiveContract
            )
        );
        callbackReceiver.handleRiskBreach(forgedReactiveSender, _msg(positionId, 1, 8500, block.timestamp));
    }

    function testRevertWhenLegacyRvmIdUsedInsteadOfDeployedContractAddress() public {
        vm.prank(callbackProxy);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrossGuardCallback.UnauthorizedReactiveSender.selector, legacyRvmId, deployedReactiveContract
            )
        );
        callbackReceiver.handleRiskBreach(legacyRvmId, _msg(positionId, 1, 8500, block.timestamp));
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

        vm.prank(callbackProxy);
        callbackReceiver.handleRiskBreach(newReactiveContract, _msg(positionId, 1, 8500, block.timestamp));
        assertTrue(borrowingController.isBorrowingPaused(positionId));

        vm.prank(callbackProxy);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrossGuardCallback.UnauthorizedReactiveSender.selector, deployedReactiveContract, newReactiveContract
            )
        );
        callbackReceiver.handleRiskBreach(deployedReactiveContract, _msg(positionId, 2, 8500, block.timestamp));
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

    function testConstructorZeroAddressRevert() public {
        vm.expectRevert(CrossGuardCallback.ZeroAddress.selector);
        new CrossGuardCallback(owner, address(0), address(borrowingController), deployedReactiveContract);

        vm.expectRevert(CrossGuardCallback.ZeroAddress.selector);
        new CrossGuardCallback(owner, callbackProxy, address(0), deployedReactiveContract);
    }

    function testHandleRiskResolvedSuccessWithOmniReactiveAddress() public {
        vm.prank(callbackProxy);
        callbackReceiver.handleRiskBreach(deployedReactiveContract, _msg(positionId, 1, 8500, block.timestamp));
        assertTrue(borrowingController.isBorrowingPaused(positionId));

        vm.prank(callbackProxy);
        vm.expectEmit(true, true, true, true);
        emit ICrossGuardCallback.RiskResolvedHandled(
            positionId, deployedReactiveContract, originUser, 2, 4500, block.timestamp + 10
        );

        callbackReceiver.handleRiskResolved(deployedReactiveContract, _msg(positionId, 2, 4500, block.timestamp + 10));

        assertFalse(borrowingController.isBorrowingPaused(positionId));
        assertEq(borrowingController.lastProcessedNonce(positionId), 2);
    }

    function testRevertWhenUnauthorizedProxyCallsHandleRiskResolved() public {
        address unauthorizedCaller = address(0x999);
        vm.prank(unauthorizedCaller);
        vm.expectRevert("Authorized sender only");
        callbackReceiver.handleRiskResolved(deployedReactiveContract, _msg(positionId, 2, 4500, block.timestamp));
    }

    function testRevertWhenForgedReactiveSenderCallsHandleRiskResolved() public {
        vm.prank(callbackProxy);
        callbackReceiver.handleRiskBreach(deployedReactiveContract, _msg(positionId, 1, 8500, block.timestamp));

        address attackerContract = address(0x666);
        vm.prank(callbackProxy);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrossGuardCallback.UnauthorizedReactiveSender.selector, attackerContract, deployedReactiveContract
            )
        );
        callbackReceiver.handleRiskResolved(attackerContract, _msg(positionId, 2, 4500, block.timestamp));
    }

    function testRevertWhenZeroPositionIdUsed() public {
        vm.prank(callbackProxy);
        vm.expectRevert(CrossGuardCallback.InvalidPositionId.selector);
        callbackReceiver.handleRiskBreach(deployedReactiveContract, _msg(bytes32(0), 1, 8500, block.timestamp));

        vm.prank(callbackProxy);
        vm.expectRevert(CrossGuardCallback.InvalidPositionId.selector);
        callbackReceiver.handleRiskResolved(deployedReactiveContract, _msg(bytes32(0), 2, 4500, block.timestamp));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestValuationSource} from "../../src/origin/TestValuationSource.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TestValuationSourceTest is Test {
    TestValuationSource oracle;
    address owner = address(0xAA);
    address user = address(0xBB);
    address mockWeth = address(0x1111);

    function setUp() public {
        vm.prank(owner);
        oracle = new TestValuationSource(owner);
    }

    function testSetAndGetPrice() public {
        vm.prank(owner);
        oracle.setAssetPrice(mockWeth, 3000e8); // $3,000

        assertEq(oracle.getAssetPrice(mockWeth), 3000e8);
    }

    function testRevertWhenZeroPrice() public {
        vm.prank(owner);
        vm.expectRevert(TestValuationSource.ZeroPrice.selector);
        oracle.setAssetPrice(mockWeth, 0);
    }

    function testRevertWhenPriceNotSet() public {
        vm.expectRevert(abi.encodeWithSelector(TestValuationSource.AssetPriceNotSet.selector, mockWeth));
        oracle.getAssetPrice(mockWeth);
    }

    function testRevertWhenNonOwnerSetsPrice() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        oracle.setAssetPrice(mockWeth, 2500e8);
    }
}

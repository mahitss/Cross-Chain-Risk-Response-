// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployOrigin} from "../../script/DeployOrigin.s.sol";
import {DeployDestination} from "../../script/DeployDestination.s.sol";
import {DeployReactive} from "../../script/DeployReactive.s.sol";
import {ConfigureReactive} from "../../script/ConfigureReactive.s.sol";

/// @title ScriptPreflightTest
/// @notice Tests verifying runtime execution network preflight guards and fail-closed origin identity config checks.
contract ScriptPreflightTest is Test {
    DeployOrigin deployOriginScript;
    DeployDestination deployDestScript;
    DeployReactive deployReactiveScript;
    ConfigureReactive configureScript;

    function setUp() public {
        deployOriginScript = new DeployOrigin();
        deployDestScript = new DeployDestination();
        deployReactiveScript = new DeployReactive();
        configureScript = new ConfigureReactive();

        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        vm.setEnv("BASE_RISK_CONTROLLER", "0x00000000000000000000000000000000000000bb");
        vm.setEnv("BASE_COLLATERAL_VAULT", "0x00000000000000000000000000000000000000dd");
        vm.setEnv("REACTIVE_CROSSGUARD", "0x00000000000000000000000000000000000000aa");
        vm.setEnv("UNICHAIN_CALLBACK_ADAPTER", "0x00000000000000000000000000000000000000cc");
    }

    function testDeployOriginRejectsUnsupportedNetwork() public {
        vm.chainId(1);
        vm.expectRevert("Unsupported execution network: must run on Base Sepolia (84532)");
        deployOriginScript.run();

        vm.chainId(5318007);
        vm.expectRevert("Unsupported execution network: must run on Base Sepolia (84532)");
        deployOriginScript.run();

        vm.chainId(1301);
        vm.expectRevert("Unsupported execution network: must run on Base Sepolia (84532)");
        deployOriginScript.run();
    }

    function testDeployDestinationRejectsUnsupportedNetwork() public {
        vm.chainId(1);
        vm.expectRevert("Unsupported execution network: must run on Unichain Sepolia (1301)");
        deployDestScript.run();

        vm.chainId(84532);
        vm.expectRevert("Unsupported execution network: must run on Unichain Sepolia (1301)");
        deployDestScript.run();

        vm.chainId(5318007);
        vm.expectRevert("Unsupported execution network: must run on Unichain Sepolia (1301)");
        deployDestScript.run();
    }

    function testDeployReactiveRejectsUnsupportedNetwork() public {
        vm.chainId(1);
        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        deployReactiveScript.run();

        vm.chainId(84532);
        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        deployReactiveScript.run();

        vm.chainId(1301);
        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        deployReactiveScript.run();
    }

    function testConfigureReactiveRejectsUnsupportedNetwork() public {
        vm.chainId(1);
        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        configureScript.run();

        vm.chainId(84532);
        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        configureScript.run();

        vm.chainId(1301);
        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        configureScript.run();
    }

    function testDeployReactiveAndDestinationFailClosedOnInvalidOriginVaultConfig() public {
        vm.chainId(5318007);
        vm.setEnv("BASE_COLLATERAL_VAULT", "0x0000000000000000000000000000000000000000");
        vm.expectRevert("BASE_COLLATERAL_VAULT cannot be zero address");
        deployReactiveScript.run();

        address deployer = vm.addr(1);
        vm.setEnv("BASE_COLLATERAL_VAULT", vm.toString(deployer));
        vm.expectRevert(
            "BASE_COLLATERAL_VAULT cannot be deployer EOA: must be deployed CollateralVault contract address"
        );
        deployReactiveScript.run();

        vm.chainId(1301);
        vm.setEnv("BASE_COLLATERAL_VAULT", "0x0000000000000000000000000000000000000000");
        vm.expectRevert("BASE_COLLATERAL_VAULT cannot be zero address");
        deployDestScript.run();

        vm.setEnv("BASE_COLLATERAL_VAULT", "0x00000000000000000000000000000000000000dd");
    }
}

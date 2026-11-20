// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployOrigin} from "../../script/DeployOrigin.s.sol";
import {DeployDestination} from "../../script/DeployDestination.s.sol";
import {DeployReactive} from "../../script/DeployReactive.s.sol";
import {ConfigureReactive} from "../../script/ConfigureReactive.s.sol";

/// @title ScriptPreflightTest
/// @notice Tests verifying runtime execution network preflight guards on all deployment and configuration scripts.
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

        // Provide dummy environment variables for scripts that parse them before network checks
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        vm.setEnv("BASE_RISK_CONTROLLER", "0x00000000000000000000000000000000000000bb");
        vm.setEnv("REACTIVE_CROSSGUARD", "0x00000000000000000000000000000000000000aa");
        vm.setEnv("UNICHAIN_CALLBACK_ADAPTER", "0x00000000000000000000000000000000000000cc");
    }

    function testDeployOriginRejectsUnsupportedNetwork() public {
        // Must run on Base Sepolia (84532); reject Ethereum Mainnet (1)
        vm.chainId(1);
        vm.expectRevert("Unsupported execution network: must run on Base Sepolia (84532)");
        deployOriginScript.run();

        // Reject Reactive Lasna (5318007)
        vm.chainId(5318007);
        vm.expectRevert("Unsupported execution network: must run on Base Sepolia (84532)");
        deployOriginScript.run();

        // Reject Unichain Sepolia (1301)
        vm.chainId(1301);
        vm.expectRevert("Unsupported execution network: must run on Base Sepolia (84532)");
        deployOriginScript.run();
    }

    function testDeployDestinationRejectsUnsupportedNetwork() public {
        // Must run on Unichain Sepolia (1301); reject Ethereum Mainnet (1)
        vm.chainId(1);
        vm.expectRevert("Unsupported execution network: must run on Unichain Sepolia (1301)");
        deployDestScript.run();

        // Reject Base Sepolia (84532)
        vm.chainId(84532);
        vm.expectRevert("Unsupported execution network: must run on Unichain Sepolia (1301)");
        deployDestScript.run();

        // Reject Reactive Lasna (5318007)
        vm.chainId(5318007);
        vm.expectRevert("Unsupported execution network: must run on Unichain Sepolia (1301)");
        deployDestScript.run();
    }

    function testDeployReactiveRejectsUnsupportedNetwork() public {
        // Must run on Reactive Lasna (5318007); reject Ethereum Mainnet (1)
        vm.chainId(1);
        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        deployReactiveScript.run();

        // Reject Base Sepolia (84532)
        vm.chainId(84532);
        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        deployReactiveScript.run();

        // Reject Unichain Sepolia (1301)
        vm.chainId(1301);
        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        deployReactiveScript.run();
    }

    function testConfigureReactiveRejectsUnsupportedNetwork() public {
        // Must run on Reactive Lasna (5318007); reject Ethereum Mainnet (1)
        vm.chainId(1);
        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        configureScript.run();

        // Reject Base Sepolia (84532)
        vm.chainId(84532);
        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        configureScript.run();

        // Reject Unichain Sepolia (1301)
        vm.chainId(1301);
        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        configureScript.run();
    }
}

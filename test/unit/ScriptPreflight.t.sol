// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployReactive} from "../../script/DeployReactive.s.sol";
import {ConfigureReactive} from "../../script/ConfigureReactive.s.sol";

/// @title ScriptPreflightTest
/// @notice Tests verifying runtime execution network preflight guards on deployment and configuration scripts.
contract ScriptPreflightTest is Test {
    DeployReactive deployScript;
    ConfigureReactive configureScript;

    uint256 constant LASNA_CHAIN_ID = 5318007;

    function setUp() public {
        deployScript = new DeployReactive();
        configureScript = new ConfigureReactive();
    }

    function testDeployReactiveRejectsUnsupportedNetwork() public {
        // Set chain ID to non-Lasna network (e.g., Ethereum Mainnet 1 or Base Sepolia 84532)
        vm.chainId(1);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        vm.setEnv("BASE_RISK_CONTROLLER", "0x00000000000000000000000000000000000000bb");

        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        deployScript.run();

        vm.chainId(84532);
        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        deployScript.run();
    }

    function testConfigureReactiveRejectsUnsupportedNetwork() public {
        // Set chain ID to non-Lasna network
        vm.chainId(1301); // Unichain Sepolia
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        vm.setEnv("REACTIVE_CROSSGUARD", "0x00000000000000000000000000000000000000aa");
        vm.setEnv("UNICHAIN_CALLBACK_ADAPTER", "0x00000000000000000000000000000000000000cc");

        vm.expectRevert("Unsupported execution network: must run on Reactive Lasna (5318007)");
        configureScript.run();
    }
}

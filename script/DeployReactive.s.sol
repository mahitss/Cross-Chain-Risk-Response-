// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {CrossGuardReactive} from "../src/reactive/CrossGuardReactive.sol";

/// @title DeployReactive
/// @notice Deploys autonomous reactive risk engine to Reactive Lasna (5318007).
contract DeployReactive is Script {
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint64 constant CALLBACK_GAS_LIMIT = 300_000;
    uint256 constant DEFAULT_RISK_THRESHOLD_BPS = 8000; // 80%

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address baseRiskController = vm.envAddress("BASE_RISK_CONTROLLER");
        address unichainCallbackAdapter = vm.envAddress("UNICHAIN_CALLBACK_ADAPTER");

        console.log("=== Deploying CrossGuardReactive to Reactive Lasna (5318007) ===");
        console.log("Deployer Address:", deployer);
        console.log("Subscribing to RiskController on Base Sepolia:", baseRiskController);
        console.log("Targeting Callback on Unichain Sepolia:", unichainCallbackAdapter);

        vm.startBroadcast(deployerPrivateKey);

        CrossGuardReactive reactiveContract = new CrossGuardReactive(
            deployer,
            address(0), // Uses default system contract address
            BASE_SEPOLIA_CHAIN_ID,
            baseRiskController,
            UNICHAIN_SEPOLIA_CHAIN_ID,
            unichainCallbackAdapter,
            CALLBACK_GAS_LIMIT,
            DEFAULT_RISK_THRESHOLD_BPS
        );

        console.log("CrossGuardReactive successfully deployed at:", address(reactiveContract));

        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {CrossGuardReactive} from "../src/reactive/CrossGuardReactive.sol";

/// @title DeployReactive
/// @notice Deploys autonomous reactive risk engine to Reactive Lasna (5318007).
///         Subscribes to Base Sepolia RiskController; destination callback can be configured
///         at deployment or linked post-destination deployment via setDestinationConfig.
contract DeployReactive is Script {
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint64 constant CALLBACK_GAS_LIMIT = 300_000;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address baseRiskController = vm.envAddress("BASE_RISK_CONTROLLER");
        if (baseRiskController == address(0)) {
            revert("BASE_RISK_CONTROLLER cannot be zero address");
        }
        if (baseRiskController == deployer) {
            revert("BASE_RISK_CONTROLLER cannot be deployer EOA: must be deployed RiskController contract address");
        }

        // Optional: destination callback adapter if already deployed; otherwise address(0) to link post-deploy
        address unichainCallbackAdapter = vm.envOr("UNICHAIN_CALLBACK_ADAPTER", address(0));

        console.log("=== Deploying CrossGuardReactive to Reactive Lasna (5318007) ===");
        console.log("Deployer Address:", deployer);
        console.log("Subscribing to RiskController on Base Sepolia:", baseRiskController);
        console.log("Initial Callback on Unichain Sepolia:", unichainCallbackAdapter);

        vm.startBroadcast(deployerPrivateKey);

        CrossGuardReactive reactiveContract = new CrossGuardReactive(
            deployer,
            address(0), // Uses default Omni system contract (0x8888888888888888888888888888888888888888)
            BASE_SEPOLIA_CHAIN_ID,
            baseRiskController,
            UNICHAIN_SEPOLIA_CHAIN_ID,
            unichainCallbackAdapter,
            unichainCallbackAdapter == address(0) ? 0 : CALLBACK_GAS_LIMIT
        );

        console.log("CrossGuardReactive successfully deployed at:", address(reactiveContract));

        vm.stopBroadcast();

        // Verification
        require(reactiveContract.originRiskController() == baseRiskController, "Origin controller mismatch");
        require(reactiveContract.originChainId() == BASE_SEPOLIA_CHAIN_ID, "Origin chain mismatch");

        if (unichainCallbackAdapter == address(0)) {
            console.log("NOTE: UNICHAIN_CALLBACK_ADAPTER is address(0).");
            console.log("Next: Deploy destination contracts using CrossGuardReactive address,");
            console.log("then call ConfigureReactive script to link the destination callback.");
        } else {
            require(reactiveContract.destinationCallback() == unichainCallbackAdapter, "Destination callback mismatch");
            require(reactiveContract.callbackGasLimit() == CALLBACK_GAS_LIMIT, "Gas limit mismatch");
            console.log("Destination callback configured and verified.");
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {CrossGuardReactive} from "../src/reactive/CrossGuardReactive.sol";

/// @title ConfigureReactive
/// @notice Links the deployed Unichain Sepolia destination callback adapter into CrossGuardReactive on Lasna
///         while verifying origin identity domain configuration is non-zero and anchored to Base Sepolia (84532).
contract ConfigureReactive is Script {
    uint256 constant REACTIVE_LASNA_CHAIN_ID = 5318007;
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint64 constant CALLBACK_GAS_LIMIT = 300_000;

    function run() external {
        // Fail-closed execution network preflight guard
        require(
            block.chainid == REACTIVE_LASNA_CHAIN_ID,
            "Unsupported execution network: must run on Reactive Lasna (5318007)"
        );

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address reactiveContractAddress = vm.envAddress("REACTIVE_CROSSGUARD");
        address unichainCallbackAdapter = vm.envAddress("UNICHAIN_CALLBACK_ADAPTER");

        if (reactiveContractAddress == address(0) || unichainCallbackAdapter == address(0)) {
            revert("Target addresses cannot be zero");
        }
        if (reactiveContractAddress == deployer) {
            revert("REACTIVE_CROSSGUARD cannot be deployer EOA: must be deployed CrossGuardReactive contract address");
        }
        if (unichainCallbackAdapter == deployer) {
            revert(
                "UNICHAIN_CALLBACK_ADAPTER cannot be deployer EOA: must be deployed CrossGuardCallback contract address"
            );
        }
        if (CALLBACK_GAS_LIMIT == 0) {
            revert("CALLBACK_GAS_LIMIT cannot be zero");
        }

        console.log("=== Linking Destination Callback to CrossGuardReactive on Lasna ===");
        console.log("Reactive Contract:", reactiveContractAddress);
        console.log("Destination Callback Adapter:", unichainCallbackAdapter);
        console.log("Destination Chain ID:", UNICHAIN_SEPOLIA_CHAIN_ID);
        console.log("Callback Gas Limit:", CALLBACK_GAS_LIMIT);

        CrossGuardReactive reactive = CrossGuardReactive(payable(reactiveContractAddress));
        require(reactive.originChainId() == BASE_SEPOLIA_CHAIN_ID, "Reactive origin chain mismatch");
        require(reactive.originRiskController() != address(0), "Reactive origin RiskController not configured");
        require(reactive.originCollateralVault() != address(0), "Reactive origin CollateralVault not configured");

        vm.startBroadcast(deployerPrivateKey);
        reactive.setDestinationConfig(UNICHAIN_SEPOLIA_CHAIN_ID, unichainCallbackAdapter, CALLBACK_GAS_LIMIT);
        vm.stopBroadcast();

        // Independent state confirmation
        require(reactive.destinationCallback() == unichainCallbackAdapter, "Callback linking failed: mismatch");
        require(reactive.destinationChainId() == UNICHAIN_SEPOLIA_CHAIN_ID, "Chain ID linking failed: mismatch");
        require(reactive.callbackGasLimit() == CALLBACK_GAS_LIMIT, "Gas limit linking failed: mismatch");
        console.log("Successfully linked destination callback to CrossGuardReactive");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {CrossGuardReactive} from "../src/reactive/CrossGuardReactive.sol";

/// @title ConfigureReactive
/// @notice Links the deployed Unichain Sepolia destination callback adapter into CrossGuardReactive on Lasna.
contract ConfigureReactive is Script {
    uint256 constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint64 constant CALLBACK_GAS_LIMIT = 300_000;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address reactiveContractAddress = vm.envAddress("REACTIVE_CROSSGUARD");
        address unichainCallbackAdapter = vm.envAddress("UNICHAIN_CALLBACK_ADAPTER");

        if (reactiveContractAddress == address(0) || unichainCallbackAdapter == address(0)) {
            revert("Target addresses cannot be zero");
        }
        if (unichainCallbackAdapter == deployer) {
            revert("UNICHAIN_CALLBACK_ADAPTER cannot be deployer EOA");
        }

        console.log("=== Linking Destination Callback to CrossGuardReactive on Lasna ===");
        console.log("Reactive Contract:", reactiveContractAddress);
        console.log("Destination Callback Adapter:", unichainCallbackAdapter);

        vm.startBroadcast(deployerPrivateKey);

        CrossGuardReactive reactive = CrossGuardReactive(payable(reactiveContractAddress));
        reactive.setDestinationConfig(UNICHAIN_SEPOLIA_CHAIN_ID, unichainCallbackAdapter, CALLBACK_GAS_LIMIT);

        vm.stopBroadcast();

        require(reactive.destinationCallback() == unichainCallbackAdapter, "Callback linking failed");
        require(reactive.destinationChainId() == UNICHAIN_SEPOLIA_CHAIN_ID, "Chain ID linking failed");
        require(reactive.callbackGasLimit() == CALLBACK_GAS_LIMIT, "Gas limit linking failed");
        console.log("Successfully linked destination callback to CrossGuardReactive");
    }
}

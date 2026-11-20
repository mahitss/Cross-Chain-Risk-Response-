// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BorrowingController} from "../src/destination/BorrowingController.sol";
import {CrossGuardCallback} from "../src/destination/CrossGuardCallback.sol";

/// @title DeployDestination
/// @notice Deploys destination borrowing & callback infrastructure to Unichain Sepolia (1301).
///         Strictly requires the deployed CrossGuardReactive contract address; rejects zero or EOA fallbacks.
contract DeployDestination is Script {
    uint256 constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    // Official Callback Proxy on Unichain Sepolia
    address constant UNICHAIN_CALLBACK_PROXY = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Required: Actual deployed CrossGuardReactive contract address on Lasna
        address authorizedReactiveSender = vm.envAddress("REACTIVE_CROSSGUARD");

        // Reject zero or EOA fallback authorization
        if (authorizedReactiveSender == address(0)) {
            revert("REACTIVE_CROSSGUARD cannot be zero address");
        }
        if (authorizedReactiveSender == deployer) {
            revert("REACTIVE_CROSSGUARD cannot be deployer EOA: must be deployed CrossGuardReactive contract address");
        }
        if (UNICHAIN_CALLBACK_PROXY == address(0)) {
            revert("UNICHAIN_CALLBACK_PROXY cannot be zero address");
        }

        console.log("=== Deploying Destination Contracts to Unichain Sepolia (1301) ===");
        console.log("Deployer Address:", deployer);
        console.log("Configured Reactive Sender (Lasna Contract):", authorizedReactiveSender);
        console.log("Configured Callback Proxy:", UNICHAIN_CALLBACK_PROXY);

        // Fail-closed execution network preflight guard
        require(
            block.chainid == UNICHAIN_SEPOLIA_CHAIN_ID,
            "Unsupported execution network: must run on Unichain Sepolia (1301)"
        );

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Borrowing Controller
        BorrowingController borrowingController = new BorrowingController(deployer);
        console.log("BorrowingController deployed at:", address(borrowingController));

        // 2. Deploy CrossGuardCallback Receiver (rejects zero address or unconfigured sender)
        CrossGuardCallback callbackReceiver = new CrossGuardCallback(
            deployer, UNICHAIN_CALLBACK_PROXY, address(borrowingController), authorizedReactiveSender
        );
        console.log("CrossGuardCallback deployed at:", address(callbackReceiver));

        // 3. Link Callback Receiver as authorized adapter in Borrowing Controller
        borrowingController.setCallbackAdapter(address(callbackReceiver));
        console.log("CrossGuardCallback authorized in BorrowingController");

        vm.stopBroadcast();

        // 4. Verify callback proxy and Reactive sender configuration
        require(callbackReceiver.authorizedReactiveSender() == authorizedReactiveSender, "Reactive sender mismatch");
        require(callbackReceiver.callbackProxy() == UNICHAIN_CALLBACK_PROXY, "Callback proxy mismatch");
        require(borrowingController.callbackAdapter() == address(callbackReceiver), "Callback adapter mismatch");
        console.log("Configuration successfully verified on-chain");
    }
}

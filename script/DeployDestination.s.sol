// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BorrowingController} from "../src/destination/BorrowingController.sol";
import {CrossGuardCallback} from "../src/destination/CrossGuardCallback.sol";

/// @title DeployDestination
/// @notice Deploys destination borrowing & callback infrastructure to Unichain Sepolia (1301).
contract DeployDestination is Script {
    // Official Callback Proxy on Unichain Sepolia
    address constant UNICHAIN_CALLBACK_PROXY = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Optional pre-configured reactive sender; defaults to deployer until updated
        address authorizedReactiveSender = vm.envOr("REACTIVE_CROSSGUARD", deployer);

        console.log("=== Deploying Destination Contracts to Unichain Sepolia (1301) ===");
        console.log("Deployer Address:", deployer);
        console.log("Initial Authorized Reactive Sender:", authorizedReactiveSender);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Borrowing Controller
        BorrowingController borrowingController = new BorrowingController(deployer);
        console.log("BorrowingController deployed at:", address(borrowingController));

        // 2. Deploy CrossGuardCallback Receiver (rejects zero address)
        CrossGuardCallback callbackReceiver = new CrossGuardCallback(
            deployer, UNICHAIN_CALLBACK_PROXY, address(borrowingController), authorizedReactiveSender
        );
        console.log("CrossGuardCallback deployed at:", address(callbackReceiver));

        // 3. Link Callback Receiver as authorized adapter in Borrowing Controller
        borrowingController.setCallbackAdapter(address(callbackReceiver));
        console.log("CrossGuardCallback authorized in BorrowingController");

        vm.stopBroadcast();
    }
}

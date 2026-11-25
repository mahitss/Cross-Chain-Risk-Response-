// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BorrowingController} from "../src/destination/BorrowingController.sol";
import {CrossGuardCallback} from "../src/destination/CrossGuardCallback.sol";

/// @title DeployDestination
/// @notice Deploys destination borrowing & callback infrastructure to Unichain Sepolia (1301).
///         Strictly binds trusted Base Sepolia origin identity domain (chain 84532, RiskController, CollateralVault)
///         and the deployed CrossGuardReactive sender; fails closed on missing or EOA fallback configuration.
/// @dev Executing on Unichain Sepolia (1301) cannot inspect bytecode on Base Sepolia (84532) or Reactive Lasna
///      (5318007) directly; operators must verify cross-chain contract bytecodes with crossguard_healthcheck.py.
contract DeployDestination is Script {
    uint256 constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;

    // Official Callback Proxy on Unichain Sepolia
    address constant UNICHAIN_CALLBACK_PROXY = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

    function run() external {
        // Fail-closed execution network preflight guard
        require(
            block.chainid == UNICHAIN_SEPOLIA_CHAIN_ID,
            "Unsupported execution network: must run on Unichain Sepolia (1301)"
        );

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Required cross-chain trust anchors
        address authorizedReactiveSender = vm.envAddress("REACTIVE_CROSSGUARD");
        address baseRiskController = vm.envAddress("BASE_RISK_CONTROLLER");
        address baseCollateralVault = vm.envAddress("BASE_COLLATERAL_VAULT");

        if (authorizedReactiveSender == address(0)) {
            revert("REACTIVE_CROSSGUARD cannot be zero address");
        }
        if (baseRiskController == address(0)) {
            revert("BASE_RISK_CONTROLLER cannot be zero address");
        }
        if (baseCollateralVault == address(0)) {
            revert("BASE_COLLATERAL_VAULT cannot be zero address");
        }
        if (authorizedReactiveSender == deployer) {
            revert("REACTIVE_CROSSGUARD cannot be deployer EOA: must be deployed CrossGuardReactive contract address");
        }
        if (baseRiskController == deployer) {
            revert("BASE_RISK_CONTROLLER cannot be deployer EOA: must be deployed RiskController contract address");
        }
        if (baseCollateralVault == deployer) {
            revert("BASE_COLLATERAL_VAULT cannot be deployer EOA: must be deployed CollateralVault contract address");
        }
        if (baseCollateralVault == baseRiskController) {
            revert("BASE_COLLATERAL_VAULT cannot equal BASE_RISK_CONTROLLER");
        }
        if (UNICHAIN_CALLBACK_PROXY == address(0)) {
            revert("UNICHAIN_CALLBACK_PROXY cannot be zero address");
        }

        console.log("=== Deploying Destination Contracts to Unichain Sepolia (1301) ===");
        console.log("Deployer Address:", deployer);
        console.log("Trusted Origin Chain ID (Base Sepolia):", BASE_SEPOLIA_CHAIN_ID);
        console.log("Trusted Origin RiskController:", baseRiskController);
        console.log("Trusted Origin CollateralVault:", baseCollateralVault);
        console.log("Configured Reactive Sender (Lasna Contract):", authorizedReactiveSender);
        console.log("Configured Callback Proxy:", UNICHAIN_CALLBACK_PROXY);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Borrowing Controller bound immutably to trusted origin domain
        BorrowingController borrowingController =
            new BorrowingController(deployer, BASE_SEPOLIA_CHAIN_ID, baseRiskController, baseCollateralVault);
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

        require(UNICHAIN_CALLBACK_PROXY.code.length > 0, "CallbackProxy has no bytecode on Unichain Sepolia");
        require(callbackReceiver.authorizedReactiveSender() == authorizedReactiveSender, "Reactive sender mismatch");
        require(callbackReceiver.callbackProxy() == UNICHAIN_CALLBACK_PROXY, "Callback proxy mismatch");
        require(borrowingController.callbackAdapter() == address(callbackReceiver), "Callback adapter mismatch");
        require(borrowingController.trustedOriginChainId() == BASE_SEPOLIA_CHAIN_ID, "Origin chain mismatch");
        require(
            borrowingController.trustedOriginRiskController() == baseRiskController, "Origin RiskController mismatch"
        );
        require(borrowingController.trustedOriginVault() == baseCollateralVault, "Origin vault mismatch");
        console.log("Destination configuration successfully verified on-chain");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TestValuationSource} from "../src/origin/TestValuationSource.sol";
import {RiskController} from "../src/origin/RiskController.sol";
import {CollateralVault} from "../src/origin/CollateralVault.sol";

/// @title DeployOrigin
/// @notice Deploys origin risk & collateral infrastructure to Base Sepolia (84532)
///         with M007.1 canonical position identity domain wiring.
contract DeployOrigin is Script {
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;

    function run() external {
        // Fail-closed execution network preflight guard
        require(
            block.chainid == BASE_SEPOLIA_CHAIN_ID, "Unsupported execution network: must run on Base Sepolia (84532)"
        );

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying Origin Contracts to Base Sepolia (84532) ===");
        console.log("Deployer Address:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Test Valuation Oracle
        TestValuationSource oracle = new TestValuationSource(deployer);
        console.log("TestValuationSource deployed at:", address(oracle));

        // 2. Deploy Risk Controller (Default 8000 bps = 80% LTV)
        RiskController riskController = new RiskController(deployer, 8000);
        console.log("RiskController deployed at:", address(riskController));

        // 3. Deploy Collateral Vault
        CollateralVault vault = new CollateralVault(deployer, address(oracle), address(riskController));
        console.log("CollateralVault deployed at:", address(vault));

        // 4. Authorize Vault in Risk Controller
        riskController.setAuthorizedVault(address(vault), true);
        console.log("CollateralVault authorized in RiskController");

        vm.stopBroadcast();

        require(riskController.authorizedVaults(address(vault)), "Vault authorization failed");
        require(address(vault.riskController()) == address(riskController), "RiskController mismatch");
        require(vault.IDENTITY_VERSION() == riskController.IDENTITY_VERSION(), "Identity version mismatch");
    }
}

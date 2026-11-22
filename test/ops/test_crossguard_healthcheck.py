#!/usr/bin/env python3
"""
Unit tests for CrossGuard Operational Health-Check and Diagnostics Tool.
Part of Mission M005 — Cross-Chain Operational Observability & Failure Diagnosis.

Covers all 20 required scenarios offline using mocked RPC runner:
  1. All three correct chain IDs.
  2. Incorrect chain ID.
  3. RPC unavailable.
  4. Missing contract code.
  5. Correct contract address wiring.
  6. Incorrect Reactive callback address.
  7. Incorrect authorized Reactive sender.
  8. Incorrect borrowing controller adapter.
  9. Nonzero Reactive debt.
  10. Nonzero callback proxy debt.
  11. Zero reserves with no debt.
  12. Callback gas below 100,000.
  13. Callback gas at or above 100,000.
  14. Empty callback records.
  15. Successful callback record.
  16. Failed callback record with error data.
  17. Malformed RPC or ABI output.
  18. Missing environment configuration.
  19. JSON output validity.
  20. No write-capable command execution.
"""

import json
import os
import sys
import unittest
from typing import Any, Dict, List, Optional, Tuple

# Add repository root to path
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from script.ops.crossguard_healthcheck import (
    BASE_SEPOLIA_CHAIN_ID,
    DEFAULT_CALLBACK_PROXY,
    DEFAULT_SYSTEM_CONTRACT,
    REACTIVE_LASNA_CHAIN_ID,
    UNICHAIN_SEPOLIA_CHAIN_ID,
    CastRpcRunner,
    CheckCategory,
    CrossGuardHealthChecker,
    RpcRunner,
    Status,
)


class MockRpcRunner(RpcRunner):
    """In-memory mocked RPC runner providing deterministic responses for offline testing."""

    def __init__(self):
        self.chain_ids: Dict[str, int] = {}
        self.code_map: Dict[Tuple[str, str], str] = {}
        self.call_map: Dict[Tuple[str, str, str], str] = {}
        self.balances: Dict[Tuple[str, str], int] = {}
        self.exceptions: Dict[str, Exception] = {}

    def get_chain_id(self, rpc_url: str) -> int:
        if rpc_url in self.exceptions:
            raise self.exceptions[rpc_url]
        return self.chain_ids.get(rpc_url, 0)

    def get_code(self, address: str, rpc_url: str) -> str:
        key = (address.lower(), rpc_url)
        if key in self.exceptions:
            raise self.exceptions[key]
        return self.code_map.get(key, "0x")

    def call(self, address: str, signature: str, args: List[str], rpc_url: str) -> str:
        key = (address.lower(), signature, rpc_url)
        if key in self.exceptions:
            raise self.exceptions[key]
        if key in self.call_map:
            return self.call_map[key]
        return "0x0"

    def get_balance(self, address: str, rpc_url: str) -> int:
        key = (address.lower(), rpc_url)
        if key in self.exceptions:
            raise self.exceptions[key]
        return self.balances.get(key, 0)


def create_base_config() -> Dict[str, Any]:
    return {
        "base_rpc": "https://base-sepolia.rpc.test",
        "reactive_rpc": "https://reactive-lasna.rpc.test",
        "unichain_rpc": "https://unichain-sepolia.rpc.test",
        "origin_risk_controller": "0x1111111111111111111111111111111111111111",
        "reactive_address": "0x2222222222222222222222222222222222222222",
        "callback_address": "0x3333333333333333333333333333333333333333",
        "borrowing_controller_address": "0x4444444444444444444444444444444444444444",
        "system_contract": DEFAULT_SYSTEM_CONTRACT,
        "callback_proxy": DEFAULT_CALLBACK_PROXY,
    }


def populate_healthy_runner(config: Dict[str, Any]) -> MockRpcRunner:
    runner = MockRpcRunner()
    # 1. Chain IDs
    runner.chain_ids[config["base_rpc"]] = BASE_SEPOLIA_CHAIN_ID
    runner.chain_ids[config["reactive_rpc"]] = REACTIVE_LASNA_CHAIN_ID
    runner.chain_ids[config["unichain_rpc"]] = UNICHAIN_SEPOLIA_CHAIN_ID

    # 2. Deployed Bytecodes (non-empty)
    dummy_code = "0x608060405234801561001057600080fd5b50"
    runner.code_map[(config["origin_risk_controller"].lower(), config["base_rpc"])] = dummy_code
    runner.code_map[(config["reactive_address"].lower(), config["reactive_rpc"])] = dummy_code
    runner.code_map[(config["callback_address"].lower(), config["unichain_rpc"])] = dummy_code
    runner.code_map[(config["borrowing_controller_address"].lower(), config["unichain_rpc"])] = dummy_code
    runner.code_map[(config["callback_proxy"].lower(), config["unichain_rpc"])] = dummy_code

    # 3. Configurations
    r_addr = config["reactive_address"].lower()
    r_rpc = config["reactive_rpc"]
    runner.call_map[(r_addr, "originChainId()", r_rpc)] = hex(BASE_SEPOLIA_CHAIN_ID)
    runner.call_map[(r_addr, "originRiskController()", r_rpc)] = config["origin_risk_controller"]
    runner.call_map[(r_addr, "destinationChainId()", r_rpc)] = hex(UNICHAIN_SEPOLIA_CHAIN_ID)
    runner.call_map[(r_addr, "destinationCallback()", r_rpc)] = config["callback_address"]
    runner.call_map[(r_addr, "callbackGasLimit()", r_rpc)] = hex(300_000)
    runner.call_map[(r_addr, "systemContract()", r_rpc)] = config["system_contract"]

    c_addr = config["callback_address"].lower()
    u_rpc = config["unichain_rpc"]
    runner.call_map[(c_addr, "callbackProxy()", u_rpc)] = config["callback_proxy"]
    runner.call_map[(c_addr, "authorizedReactiveSender()", u_rpc)] = config["reactive_address"]
    runner.call_map[(c_addr, "borrowingController()", u_rpc)] = config["borrowing_controller_address"]

    b_addr = config["borrowing_controller_address"].lower()
    runner.call_map[(b_addr, "callbackAdapter()", u_rpc)] = config["callback_address"]

    # 4. Funding & Debt
    sys_addr = config["system_contract"].lower()
    proxy_addr = config["callback_proxy"].lower()
    runner.call_map[(sys_addr, "debt(address)", r_rpc)] = "0"
    runner.call_map[(sys_addr, "reserves(address)", r_rpc)] = "1000000000000000000"  # 1 REACT
    runner.balances[(r_addr, r_rpc)] = 500_000_000_000_000_000  # 0.5 REACT

    runner.call_map[(proxy_addr, "debt(address)", u_rpc)] = "0"
    runner.call_map[(proxy_addr, "reserves(address)", u_rpc)] = "500000000000000000"  # 0.5 ETH
    runner.balances[(c_addr, u_rpc)] = 200_000_000_000_000_000  # 0.2 ETH

    return runner


class TestCrossGuardHealthChecker(unittest.TestCase):

    # 1. All three correct chain IDs
    def test_01_all_three_correct_chain_ids(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        net_checks = [c for c in report["checks"] if c["category"] == CheckCategory.NETWORK.value]
        self.assertEqual(len(net_checks), 3)
        for check in net_checks:
            self.assertEqual(check["status"], Status.PASS.value)

    # 2. Incorrect chain ID
    def test_02_incorrect_chain_id(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        # Corrupt Base Sepolia chain ID
        runner.chain_ids[config["base_rpc"]] = 1  # Ethereum mainnet
        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        base_check = next(c for c in report["checks"] if c["name"] == "network_base_sepolia")
        self.assertEqual(base_check["status"], Status.CRITICAL.value)
        self.assertIn("mismatch", base_check["message"])
        self.assertEqual(report["overall_status"], Status.CRITICAL.value)

    # 3. RPC unavailable
    def test_03_rpc_unavailable(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        runner.exceptions[config["reactive_rpc"]] = ConnectionError("Connection refused by RPC host")
        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        lasna_check = next(c for c in report["checks"] if c["name"] == "network_reactive_lasna")
        self.assertEqual(lasna_check["status"], Status.ERROR.value)
        self.assertIn("Connection refused", lasna_check["message"])
        self.assertIn(report["overall_status"], (Status.CRITICAL.value, Status.ERROR.value))

    # 4. Missing contract code
    def test_04_missing_contract_code(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        # Set reactive contract bytecode to empty '0x'
        runner.code_map[(config["reactive_address"].lower(), config["reactive_rpc"])] = "0x"
        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        deploy_check = next(c for c in report["checks"] if c["name"] == "deployment_reactive_crossguard")
        self.assertEqual(deploy_check["status"], Status.CRITICAL.value)
        self.assertIn("NO deployed bytecode", deploy_check["message"])
        self.assertEqual(report["overall_status"], Status.CRITICAL.value)

    # 5. Correct contract address wiring
    def test_05_correct_contract_address_wiring(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        config_checks = [c for c in report["checks"] if c["category"] == CheckCategory.CONFIGURATION.value]
        self.assertGreater(len(config_checks), 0)
        for check in config_checks:
            self.assertEqual(check["status"], Status.PASS.value)
        self.assertEqual(report["overall_status"], Status.PASS.value)

    # 6. Incorrect Reactive callback address
    def test_06_incorrect_reactive_callback_address(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        # Reactive destinationCallback points to wrong address
        r_addr = config["reactive_address"].lower()
        runner.call_map[(r_addr, "destinationCallback()", config["reactive_rpc"])] = "0x9999999999999999999999999999999999999999"

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        check = next(c for c in report["checks"] if c["name"] == "config_reactive_dest_callback")
        self.assertEqual(check["status"], Status.CRITICAL.value)
        self.assertIn("Address mismatch", check["message"])

    # 7. Incorrect authorized Reactive sender
    def test_07_incorrect_authorized_reactive_sender(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        # CrossGuardCallback points to wrong authorizedReactiveSender
        c_addr = config["callback_address"].lower()
        runner.call_map[(c_addr, "authorizedReactiveSender()", config["unichain_rpc"])] = "0xBAD0000000000000000000000000000000000000"

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        check = next(c for c in report["checks"] if c["name"] == "config_callback_authorized_reactive")
        self.assertEqual(check["status"], Status.CRITICAL.value)
        self.assertIn("Address mismatch", check["message"])

    # 8. Incorrect borrowing controller adapter
    def test_08_incorrect_borrowing_controller_adapter(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        # BorrowingController callbackAdapter points to wrong address
        b_addr = config["borrowing_controller_address"].lower()
        runner.call_map[(b_addr, "callbackAdapter()", config["unichain_rpc"])] = "0xBADADAPTER000000000000000000000000000000"

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        check = next(c for c in report["checks"] if c["name"] == "config_controller_callback_adapter")
        self.assertEqual(check["status"], Status.CRITICAL.value)
        self.assertIn("Address mismatch", check["message"])

    # 9. Nonzero Reactive debt
    def test_09_nonzero_reactive_debt(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        # Set unpaid debt on System Contract
        runner.call_map[(sys_addr, "debt(address)", config["reactive_rpc"])] = "50000000000000000"  # 0.05 REACT

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        check = next(c for c in report["checks"] if c["name"] == "funding_reactive_system_debt")
        self.assertEqual(check["status"], Status.CRITICAL.value)
        self.assertIn("OUTSTANDING DEBT", check["message"])
        self.assertEqual(report["overall_status"], Status.CRITICAL.value)

    # 10. Nonzero callback proxy debt
    def test_10_nonzero_callback_proxy_debt(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        proxy_addr = config["callback_proxy"].lower()
        runner.call_map[(proxy_addr, "debt(address)", config["unichain_rpc"])] = "1000000000000000"  # 0.001 ETH

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        check = next(c for c in report["checks"] if c["name"] == "funding_callback_proxy_debt")
        self.assertEqual(check["status"], Status.CRITICAL.value)
        self.assertIn("OUTSTANDING DEBT", check["message"])
        self.assertEqual(report["overall_status"], Status.CRITICAL.value)

    # 11. Zero reserves with no debt
    def test_11_zero_reserves_with_no_debt(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        proxy_addr = config["callback_proxy"].lower()
        # Zero debt, but zero reserves
        runner.call_map[(sys_addr, "debt(address)", config["reactive_rpc"])] = "0"
        runner.call_map[(sys_addr, "reserves(address)", config["reactive_rpc"])] = "0"
        runner.call_map[(proxy_addr, "debt(address)", config["unichain_rpc"])] = "0"
        runner.call_map[(proxy_addr, "reserves(address)", config["unichain_rpc"])] = "0"

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        r_reserves = next(c for c in report["checks"] if c["name"] == "funding_reactive_system_reserves")
        p_reserves = next(c for c in report["checks"] if c["name"] == "funding_callback_proxy_reserves")
        self.assertEqual(r_reserves["status"], Status.WARNING.value)
        self.assertEqual(p_reserves["status"], Status.WARNING.value)
        self.assertEqual(report["overall_status"], Status.WARNING.value)

    # 12. Callback gas below 100,000
    def test_12_callback_gas_below_100k(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        r_addr = config["reactive_address"].lower()
        runner.call_map[(r_addr, "callbackGasLimit()", config["reactive_rpc"])] = hex(75_000)  # Invalid

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        gas_check = next(c for c in report["checks"] if c["name"] == "callback_gas_limit_check")
        self.assertEqual(gas_check["status"], Status.CRITICAL.value)
        self.assertIn("BELOW required Reactive minimum", gas_check["message"])

    # 13. Callback gas at or above 100,000
    def test_13_callback_gas_at_or_above_100k(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        r_addr = config["reactive_address"].lower()
        runner.call_map[(r_addr, "callbackGasLimit()", config["reactive_rpc"])] = hex(100_000)

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        gas_check = next(c for c in report["checks"] if c["name"] == "callback_gas_limit_check")
        self.assertEqual(gas_check["status"], Status.PASS.value)
        self.assertIn("100000 gas", gas_check["message"])

    # 14. Empty callback records
    def test_14_empty_callback_records(self):
        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        # Empty array returned by getCallbacks
        runner.call_map[(sys_addr, "getCallbacks(uint256)", config["reactive_rpc"])] = "0x"

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.UNKNOWN.value)
        self.assertIn("pending, not yet recorded, or unavailable", rec_check["message"])
        self.assertEqual(rec_check["evidence"]["state"], "PENDING_OR_UNAVAILABLE")

    # 15. Successful callback record
    def test_15_successful_callback_record(self):
        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        # Simulated formatted cast response for successful callback
        runner.call_map[(sys_addr, "getCallbacks(uint256)", config["reactive_rpc"])] = (
            "[(1301, 0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890, true, 0x)]"
        )

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.PASS.value)
        self.assertIn("recorded as SUCCESS", rec_check["message"])

    # 16. Failed callback record with error data
    def test_16_failed_callback_record_with_error_data(self):
        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        # Simulated formatted cast response for failed callback with revert data
        runner.call_map[(sys_addr, "getCallbacks(uint256)", config["reactive_rpc"])] = (
            "[(1301, 0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890, false, 0x4e487b71)]"
        )

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.CRITICAL.value)
        self.assertIn("recorded as FAILED", rec_check["message"])
        self.assertIn("0x4e487b71", rec_check["message"])

    # 17. Malformed RPC or ABI output
    def test_17_malformed_rpc_or_abi_output(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        r_addr = config["reactive_address"].lower()
        # Return corrupt non-integer string for originChainId
        runner.call_map[(r_addr, "originChainId()", config["reactive_rpc"])] = "MALFORMED_OUTPUT"

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        check = next(c for c in report["checks"] if c["name"] == "config_reactive_origin_chain_id")
        self.assertEqual(check["status"], Status.ERROR.value)
        self.assertIn("Failed to query", check["message"])

    # 18. Missing environment configuration
    def test_18_missing_environment_configuration(self):
        # Empty config
        config = {}
        runner = MockRpcRunner()
        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        # All network and deployment checks should report UNKNOWN without crashing
        unknown_checks = [c for c in report["checks"] if c["status"] == Status.UNKNOWN.value]
        self.assertGreater(len(unknown_checks), 0)
        self.assertEqual(report["overall_status"], Status.UNKNOWN.value)

    # 19. JSON output validity
    def test_19_json_output_validity(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        json_str = json.dumps(report)
        reloaded = json.loads(json_str)
        self.assertIn("overall_status", reloaded)
        self.assertIn("summary", reloaded)
        self.assertIn("checks", reloaded)
        self.assertIn("topology", reloaded)
        self.assertEqual(reloaded["overall_status"], Status.PASS.value)

    # 20. No write-capable command execution
    def test_20_no_write_capable_command_execution(self):
        runner = CastRpcRunner(cast_path="mock_cast")

        # Verify whitelist rejects write commands
        write_commands = ["send", "mktx", "publish", "create2", "wallet"]
        for cmd in write_commands:
            with self.assertRaises(PermissionError):
                runner._execute(cmd, ["--rpc-url", "http://localhost:8545"])

        # Verify forbidden flags are rejected even with whitelisted subcommands
        forbidden_flags = ["--private-key", "--ledger", "--trezor", "--interactive", "--broadcast"]
        for flag in forbidden_flags:
            with self.assertRaises(PermissionError):
                runner._execute("call", ["0x1234", "test()", flag, "--rpc-url", "http://localhost:8545"])


if __name__ == "__main__":
    unittest.main()

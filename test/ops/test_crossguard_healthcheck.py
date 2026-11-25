#!/usr/bin/env python3
"""
Unit tests for CrossGuard Operational Health-Check and Diagnostics Tool.
Part of Mission M005 / M005.1 — Operational Safety, ABI Correctness & Diagnostics Patch.

Comprehensive test coverage across:
  - Base M005 checks (network, bytecode, wiring, reserves/debt, gas limit)
  - Critical Fix A: Centralized RPC credential redaction across all output surfaces
  - Critical Fix B: Correct getCallbacks ABI decoding (six-field tuple, raw hex, mixed outcomes, malformed data)
  - Critical Fix C: Correct funding recovery instructions (depositTo routing)
  - Critical Fix D: Strict exit code behavior (0 for HEALTHY, 1 for all others)
  - Reliability: Bounded subprocess timeout handling
  - Security: Rejection of write-capable cast commands
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
    CALLBACK_DISPATCH_DEFERRED_TOPIC,
    CALLBACK_DISPATCH_SUBMITTED_TOPIC,
    CALLBACK_REQUEST_TOPIC,
    CALLBACK_RETRY_REQUESTED_TOPIC,
    DEFAULT_CALLBACK_PROXY,
    DEFAULT_SYSTEM_CONTRACT,
    PENDING_CALLBACK_SUPERSEDED_TOPIC,
    REACTIVE_BREACH_PROCESSED_TOPIC,
    REACTIVE_LASNA_CHAIN_ID,
    REACTIVE_RESOLVED_PROCESSED_TOPIC,
    UNICHAIN_SEPOLIA_CHAIN_ID,
    UNSUPPORTED_LEGACY_CALLBACK_REQUESTED_V1_TOPIC,
    CastRpcRunner,
    CheckCategory,
    CrossGuardHealthChecker,
    OverallStatus,
    RecoveryStatus,
    RpcRunner,
    Status,
    compute_exit_code,
    compute_recovery_exit_code,
    decode_address_strict,
    decode_bool_strict,
    decode_bytes_strict,
    decode_callback_records,
    decode_callback_request_data_strict,
    decode_get_latest_callback,
    decode_get_latest_callback_strict,
    decode_uint_strict,
    encode_callback_request_data,
    estimate_callback_fee_wei,
    format_recovery_preflight_terminal,
    format_terminal_report,
    keccak256,
    keccak256_topic,
    parse_arguments,
    redact_rpc_url,
    run_recovery_preflight,
    sanitize_text,
    validate_evm_address,
)


class MockRpcRunner(RpcRunner):
    """In-memory mocked RPC runner providing deterministic responses for offline testing."""

    def __init__(self):
        self.chain_ids: Dict[str, int] = {}
        self.code_map: Dict[Tuple[str, str], str] = {}
        self.call_map: Dict[Tuple[str, str, str], str] = {}
        self.balances: Dict[Tuple[str, str], int] = {}
        self.receipts: Dict[Tuple[str, str], Dict[str, Any]] = {}
        self.gas_prices: Dict[str, Any] = {}
        self.base_fees: Dict[str, Any] = {}
        self.exceptions: Dict[Any, Exception] = {}

    def get_chain_id(self, rpc_url: str) -> int:
        if ("chain-id", rpc_url) in self.exceptions:
            raise self.exceptions[("chain-id", rpc_url)]
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

    def get_receipt(self, tx_hash: str, rpc_url: str) -> Dict[str, Any]:
        key = (tx_hash.lower(), rpc_url)
        if key in self.exceptions:
            raise self.exceptions[key]
        return self.receipts.get(key, {})

    def get_gas_price(self, rpc_url: str) -> int:
        key = ("gas-price", rpc_url)
        if key in self.exceptions:
            raise self.exceptions[key]
        return self.gas_prices.get(rpc_url, 0)

    def get_base_fee(self, rpc_url: str) -> int:
        key = ("base-fee", rpc_url)
        if key in self.exceptions:
            raise self.exceptions[key]
        return self.base_fees.get(rpc_url, 0)


def create_base_config() -> Dict[str, Any]:
    return {
        "base_rpc": "https://base-sepolia.rpc.test",
        "reactive_rpc": "https://reactive-lasna.rpc.test",
        "unichain_rpc": "https://unichain-sepolia.rpc.test",
        "origin_risk_controller": "0x1111111111111111111111111111111111111111",
        "origin_collateral_vault": "0x5555555555555555555555555555555555555555",
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
    if config.get("origin_collateral_vault"):
        runner.code_map[(config["origin_collateral_vault"].lower(), config["base_rpc"])] = dummy_code
    runner.code_map[(config["reactive_address"].lower(), config["reactive_rpc"])] = dummy_code
    runner.code_map[(config["callback_address"].lower(), config["unichain_rpc"])] = dummy_code
    runner.code_map[(config["borrowing_controller_address"].lower(), config["unichain_rpc"])] = dummy_code
    runner.code_map[(config["callback_proxy"].lower(), config["unichain_rpc"])] = dummy_code

    # 3. Configurations
    if config.get("origin_collateral_vault"):
        v_addr = config["origin_collateral_vault"].lower()
        runner.call_map[(v_addr, "riskController()", config["base_rpc"])] = config["origin_risk_controller"]
        runner.call_map[(config["origin_risk_controller"].lower(), "authorizedVaults(address)", config["base_rpc"])] = "true"

    r_addr = config["reactive_address"].lower()
    r_rpc = config["reactive_rpc"]
    runner.call_map[(r_addr, "originChainId()", r_rpc)] = hex(BASE_SEPOLIA_CHAIN_ID)
    runner.call_map[(r_addr, "originRiskController()", r_rpc)] = config["origin_risk_controller"]
    if config.get("origin_collateral_vault"):
        runner.call_map[(r_addr, "originCollateralVault()", r_rpc)] = config["origin_collateral_vault"]
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
    runner.call_map[(b_addr, "trustedOriginChainId()", u_rpc)] = hex(BASE_SEPOLIA_CHAIN_ID)
    runner.call_map[(b_addr, "trustedOriginRiskController()", u_rpc)] = config["origin_risk_controller"]
    if config.get("origin_collateral_vault"):
        runner.call_map[(b_addr, "trustedOriginVault()", u_rpc)] = config["origin_collateral_vault"]

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


def encode_abi_callback_array(records: List[Tuple[int, str, int, int, int, str]]) -> str:
    """Helper to produce raw ABI-encoded hex string for:
       getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])
       Field order:
         1. uint256 blockNumber
         2. address reactiveContract
         3. uint256 callbackIndex
         4. uint256 destinationChainId
         5. uint256 destinationTxHash
         6. bytes error
    """
    out = []
    out.append((32).to_bytes(32, "big"))  # offset to array
    out.append(len(records).to_bytes(32, "big"))  # array length
    if len(records) == 0:
        return "0x" + b"".join(out).hex()

    head_len = len(records) * 32
    element_payloads = []
    for r in records:
        block_num, reactive_addr, callback_idx, dest_chain_id, dest_tx_hash, err_hex = r
        if err_hex.startswith("0x"):
            err_hex = err_hex[2:]
        err_bytes = bytes.fromhex(err_hex)

        clean_addr = reactive_addr[2:] if reactive_addr.startswith("0x") else reactive_addr
        clean_addr = clean_addr.zfill(40)
        t_head = [
            block_num.to_bytes(32, "big"),
            bytes.fromhex(clean_addr).rjust(32, b"\x00"),
            callback_idx.to_bytes(32, "big"),
            dest_chain_id.to_bytes(32, "big"),
            dest_tx_hash.to_bytes(32, "big"),
            (192).to_bytes(32, "big"),  # offset to dynamic bytes within tuple
        ]
        padded_len = (len(err_bytes) + 31) // 32 * 32
        t_tail = [
            len(err_bytes).to_bytes(32, "big"),
            err_bytes.ljust(padded_len, b"\x00"),
        ]
        element_payloads.append(b"".join(t_head) + b"".join(t_tail))

    cur_offset = head_len
    for payload in element_payloads:
        out.append(cur_offset.to_bytes(32, "big"))
        cur_offset += len(payload)
    for payload in element_payloads:
        out.append(payload)

    return "0x" + b"".join(out).hex()


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
        self.assertEqual(report["overall_status"], OverallStatus.HEALTHY.value)

    # 2. Incorrect chain ID
    def test_02_incorrect_chain_id(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        runner.chain_ids[config["base_rpc"]] = 1  # Ethereum mainnet
        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        base_check = next(c for c in report["checks"] if c["name"] == "network_base_sepolia")
        self.assertEqual(base_check["status"], Status.CRITICAL.value)
        self.assertIn("mismatch", base_check["message"])
        self.assertEqual(report["overall_status"], OverallStatus.CRITICAL.value)

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
        self.assertIn(report["overall_status"], (OverallStatus.CRITICAL.value, OverallStatus.ERROR.value))

    # 4. Missing contract code
    def test_04_missing_contract_code(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        runner.code_map[(config["reactive_address"].lower(), config["reactive_rpc"])] = "0x"
        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        deploy_check = next(c for c in report["checks"] if c["name"] == "deployment_reactive_crossguard")
        self.assertEqual(deploy_check["status"], Status.CRITICAL.value)
        self.assertIn("NO deployed bytecode", deploy_check["message"])
        self.assertEqual(report["overall_status"], OverallStatus.CRITICAL.value)

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
        self.assertEqual(report["overall_status"], OverallStatus.HEALTHY.value)

    # 6. Incorrect Reactive callback address
    def test_06_incorrect_reactive_callback_address(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
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
        runner.call_map[(sys_addr, "debt(address)", config["reactive_rpc"])] = "50000000000000000"  # 0.05 REACT

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        check = next(c for c in report["checks"] if c["name"] == "funding_reactive_system_debt")
        self.assertEqual(check["status"], Status.CRITICAL.value)
        self.assertIn("OUTSTANDING DEBT", check["message"])
        self.assertIn("depositTo(reactiveContract)", check["remediation"])
        self.assertEqual(report["overall_status"], OverallStatus.CRITICAL.value)

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
        self.assertIn("depositTo(callbackContract)", check["remediation"])
        self.assertEqual(report["overall_status"], OverallStatus.CRITICAL.value)

    # 11. Zero reserves with no debt
    def test_11_zero_reserves_with_no_debt(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        proxy_addr = config["callback_proxy"].lower()
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
        self.assertEqual(report["overall_status"], OverallStatus.WARNING.value)

    # 12. Callback gas below 100,000
    def test_12_callback_gas_below_100k(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        r_addr = config["reactive_address"].lower()
        runner.call_map[(r_addr, "callbackGasLimit()", config["reactive_rpc"])] = hex(75_000)

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

    # 14. Empty callback records (Pending / Unrecorded)
    def test_14_empty_callback_records(self):
        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_addr, sig, config["reactive_rpc"])] = "0x"

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.UNKNOWN.value)
        self.assertIn("pending, not yet recorded, or unavailable", rec_check["message"])
        self.assertEqual(rec_check["evidence"]["state"], "PENDING_OR_UNAVAILABLE")

    # 15. Successful callback record (Documented 6-field schema with empty error and valid tx hash)
    def test_15_successful_callback_record(self):
        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        # 6 fields: blockNumber, reactiveContract, callbackIndex, destinationChainId, destinationTxHash, error
        runner.call_map[(sys_addr, sig, config["reactive_rpc"])] = (
            f"[(5000000, {config['reactive_address']}, 1, 1301, 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef, 0x)]"
        )

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.PASS.value)
        self.assertIn("recorded as SUCCESS", rec_check["message"])

    # 16. Failed callback record with error data (Revert bytes)
    def test_16_failed_callback_record_with_error_data(self):
        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_addr, sig, config["reactive_rpc"])] = (
            f"[(5000000, {config['reactive_address']}, 1, 1301, 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef, 0x4e487b71)]"
        )

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.CRITICAL.value)
        self.assertIn("recorded as FAILED", rec_check["message"])
        self.assertIn("0x4e487b71", rec_check["message"])
        self.assertEqual(rec_check["evidence"]["failed_records"][0]["error"], "0x4e487b71")

    # 17. Malformed RPC or ABI output
    def test_17_malformed_rpc_or_abi_output(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        r_addr = config["reactive_address"].lower()
        runner.call_map[(r_addr, "originChainId()", config["reactive_rpc"])] = "MALFORMED_OUTPUT"

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        check = next(c for c in report["checks"] if c["name"] == "config_reactive_origin_chain_id")
        self.assertEqual(check["status"], Status.ERROR.value)
        self.assertIn("Failed to query", check["message"])

    # 18. Missing environment configuration
    def test_18_missing_environment_configuration(self):
        config = {}
        runner = MockRpcRunner()
        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        unknown_checks = [c for c in report["checks"] if c["status"] == Status.UNKNOWN.value]
        self.assertGreater(len(unknown_checks), 0)
        self.assertEqual(report["overall_status"], OverallStatus.UNKNOWN.value)
        self.assertEqual(compute_exit_code(report["overall_status"]), 1)

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
        self.assertEqual(reloaded["overall_status"], OverallStatus.HEALTHY.value)

    # 20. No write-capable command execution
    def test_20_no_write_capable_command_execution(self):
        runner = CastRpcRunner(cast_path="mock_cast")

        write_commands = ["send", "mktx", "publish", "create2", "wallet"]
        for cmd in write_commands:
            with self.assertRaises(PermissionError):
                runner._execute(cmd, ["--rpc-url", "http://localhost:8545"])

        forbidden_flags = ["--private-key", "--ledger", "--trezor", "--interactive", "--broadcast"]
        for flag in forbidden_flags:
            with self.assertRaises(PermissionError):
                runner._execute("call", ["0x1234", "test()", flag, "--rpc-url", "http://localhost:8545"])

    # -------------------------------------------------------------------------
    # NEW TESTS FOR M005.1 PATCH
    # -------------------------------------------------------------------------

    # 21. Credential redaction: URL user-info
    def test_21_credential_redaction_userinfo(self):
        raw = "https://alice:supersecretpassword123@sepolia.base.org:8545"
        redacted = redact_rpc_url(raw)
        self.assertNotIn("alice", redacted)
        self.assertNotIn("supersecretpassword123", redacted)
        self.assertEqual(redacted, "https://sepolia.base.org:8545")

    # 22. Credential redaction: Query parameter API key
    def test_22_credential_redaction_query_params(self):
        raw = "https://sepolia.unichain.org?apiKey=VERY_SECRET_KEY_999"
        redacted = redact_rpc_url(raw)
        self.assertNotIn("VERY_SECRET_KEY_999", redacted)
        self.assertEqual(redacted, "https://sepolia.unichain.org/<redacted>")

    # 23. Credential redaction: Path-based API key
    def test_23_credential_redaction_path_api_key(self):
        raw = "https://eth-sepolia.g.alchemy.com/v2/SECRET_TOKEN_ABCXYZ"
        redacted = redact_rpc_url(raw)
        self.assertNotIn("SECRET_TOKEN_ABCXYZ", redacted)
        self.assertEqual(redacted, "https://eth-sepolia.g.alchemy.com/<redacted>")

    # 24. Credential redaction: Multiple credential locations
    def test_24_credential_redaction_multiple_locations(self):
        raw = "https://operator:pass456@lasna-rpc.rnk.dev:8545/v3/my_secret_path?token=jwt_secret_token#anchor"
        redacted = redact_rpc_url(raw)
        for secret in ["operator", "pass456", "my_secret_path", "jwt_secret_token"]:
            self.assertNotIn(secret, redacted)
        self.assertEqual(redacted, "https://lasna-rpc.rnk.dev:8545/<redacted>")

    # 25. Credential redaction: Complete report contains zero raw secrets
    def test_25_no_credentials_leak_in_report_or_terminal(self):
        secret_user = "secret_user"
        secret_pass = "secret_password"
        secret_key = "secret_api_key"
        secret_token = "secret_auth_token"

        config = {
            "base_rpc": f"https://{secret_user}:{secret_pass}@sepolia.base.org:8545/v1/{secret_key}",
            "reactive_rpc": f"https://lasna-rpc.rnk.dev?auth={secret_token}",
            "unichain_rpc": "https://sepolia.unichain.org",
            "origin_risk_controller": "0x1111111111111111111111111111111111111111",
            "origin_collateral_vault": "0x5555555555555555555555555555555555555555",
            "reactive_address": "0x2222222222222222222222222222222222222222",
            "callback_address": "0x3333333333333333333333333333333333333333",
            "borrowing_controller_address": "0x4444444444444444444444444444444444444444",
            "system_contract": DEFAULT_SYSTEM_CONTRACT,
            "callback_proxy": DEFAULT_CALLBACK_PROXY,
        }

        runner = populate_healthy_runner(config)
        # Also inject an exception with the secret URL to test error sanitization
        runner.exceptions[config["base_rpc"]] = RuntimeError(f"Connection timeout to {config['base_rpc']}")

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        json_out = json.dumps(report)
        terminal_out = format_terminal_report(report)

        for secret in [secret_user, secret_pass, secret_key, secret_token]:
            self.assertNotIn(secret, json_out, f"Secret '{secret}' leaked in JSON report!")
            self.assertNotIn(secret, terminal_out, f"Secret '{secret}' leaked in terminal report!")

    # 26. Callback ABI: Properly encoded empty array (raw ABI hex)
    def test_26_callback_abi_empty_array_hex(self):
        empty_hex = encode_abi_callback_array([])
        records, err = decode_callback_records(empty_hex)
        self.assertIsNone(err)
        self.assertEqual(records, [])

    # 27. Callback ABI: Raw hex single success
    def test_27_callback_abi_single_success_hex(self):
        dest_tx = 0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890
        raw_hex = encode_abi_callback_array([
            (5000000, "0x2222222222222222222222222222222222222222", 1, 1301, dest_tx, "")
        ])
        records, err = decode_callback_records(raw_hex)
        self.assertIsNone(err)
        self.assertEqual(len(records), 1)
        r = records[0]
        self.assertEqual(r["block_number"], 5000000)
        self.assertEqual(r["reactive_contract"], "0x2222222222222222222222222222222222222222")
        self.assertEqual(r["callback_index"], 1)
        self.assertEqual(r["destination_chain_id"], 1301)
        self.assertEqual(r["destination_tx_hash"], dest_tx)
        self.assertEqual(r["error"], "0x")
        self.assertTrue(r["success"])

    # 28. Callback ABI: Raw hex single failure with exact error bytes preserved
    def test_28_callback_abi_single_failure_hex(self):
        revert_data = "0x82b42900" + "11" * 32  # Custom error with arguments
        dest_tx = 0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890
        raw_hex = encode_abi_callback_array([
            (5000000, "0x2222222222222222222222222222222222222222", 2, 1301, dest_tx, revert_data)
        ])
        records, err = decode_callback_records(raw_hex)
        self.assertIsNone(err)
        self.assertEqual(len(records), 1)
        r = records[0]
        self.assertEqual(r["destination_chain_id"], 1301)
        self.assertEqual(r["error"], revert_data.lower())
        self.assertFalse(r["success"])

    # 29. Callback ABI: Multiple callback records (all successful)
    def test_29_callback_multiple_successful_records(self):
        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_addr, sig, config["reactive_rpc"])] = (
            f"[(5000000, {config['reactive_address']}, 1, 1301, 0x1111111111111111111111111111111111111111111111111111111111111111, 0x), "
            f"(5000001, {config['reactive_address']}, 2, 1301, 0x2222222222222222222222222222222222222222222222222222222222222222, 0x)]"
        )

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.PASS.value)
        self.assertIn("2 record(s)", rec_check["message"])

    # 30. Callback ABI: Multiple records with mixed outcomes (1 success, 1 failure)
    def test_30_callback_mixed_outcomes(self):
        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_addr, sig, config["reactive_rpc"])] = (
            f"[(5000000, {config['reactive_address']}, 1, 1301, 0x1111111111111111111111111111111111111111111111111111111111111111, 0x), "
            f"(5000001, {config['reactive_address']}, 2, 1301, 0x2222222222222222222222222222222222222222222222222222222222222222, 0x08c379a0)]"
        )

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.CRITICAL.value)
        self.assertIn("recorded as FAILED", rec_check["message"])
        self.assertIn("0x08c379a0", rec_check["message"])
        self.assertEqual(report["overall_status"], OverallStatus.CRITICAL.value)

    # 31. Callback ABI: Malformed ABI response
    def test_31_callback_malformed_abi(self):
        records, err = decode_callback_records("0xCORRUPT_HEX_DATA")
        self.assertIsNone(records)
        self.assertIsNotNone(err)

        # Confirm health checker converts malformed data into ERROR, never false PASS
        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_addr, sig, config["reactive_rpc"])] = "0xCORRUPT_HEX_DATA"

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()
        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.ERROR.value)
        self.assertIn("Failed to decode callback records ABI", rec_check["message"])

    # 32. Callback ABI: Wrong destination chain ID (Field 4)
    def test_32_callback_wrong_destination_chain(self):
        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        # Record with wrong chain ID in field 4 (84532 instead of 1301)
        runner.call_map[(sys_addr, sig, config["reactive_rpc"])] = (
            f"[(5000000, {config['reactive_address']}, 1, 84532, 0x1111111111111111111111111111111111111111111111111111111111111111, 0x)]"
        )

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.CRITICAL.value)
        self.assertIn("destination chain ID mismatch", rec_check["message"])

    # 33. Callback ABI: Missing destination transaction details (Field 5 destination_tx_hash = 0)
    def test_33_callback_missing_destination_tx(self):
        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_addr, sig, config["reactive_rpc"])] = (
            f"[(5000000, {config['reactive_address']}, 1, 1301, 0, 0x)]"
        )

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.UNKNOWN.value)
        self.assertIn("destination transaction hash is zero", rec_check["message"])
        self.assertNotEqual(rec_check["status"], Status.PASS.value)

    # 34. Exit codes: Deterministic mapping for every status
    def test_34_exit_code_behavior_all_statuses(self):
        self.assertEqual(compute_exit_code(OverallStatus.HEALTHY.value), 0)
        self.assertEqual(compute_exit_code(OverallStatus.WARNING.value), 1)
        self.assertEqual(compute_exit_code(OverallStatus.CRITICAL.value), 1)
        self.assertEqual(compute_exit_code(OverallStatus.UNKNOWN.value), 1)
        self.assertEqual(compute_exit_code(OverallStatus.ERROR.value), 1)
        self.assertEqual(compute_exit_code("ANY_OTHER_STATE"), 1)

    # 35. Funding routing: System Contract & Callback Proxy depositTo instructions
    def test_35_funding_remediation_uses_deposit_to(self):
        config = create_base_config()
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        proxy_addr = config["callback_proxy"].lower()
        # Set debt on both
        runner.call_map[(sys_addr, "debt(address)", config["reactive_rpc"])] = "100"
        runner.call_map[(proxy_addr, "debt(address)", config["unichain_rpc"])] = "200"

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        sys_debt = next(c for c in report["checks"] if c["name"] == "funding_reactive_system_debt")
        proxy_debt = next(c for c in report["checks"] if c["name"] == "funding_callback_proxy_debt")

        self.assertIn("depositTo(reactiveContract)", sys_debt["remediation"])
        self.assertIn("depositTo(callbackContract)", proxy_debt["remediation"])
        self.assertNotIn("pay(", sys_debt["remediation"])

    # 36. Reliability: RPC Timeout conversion to ERROR and credential sanitization
    def test_36_timeout_handling_and_redaction(self):
        secret_rpc = "https://admin:token999@timeout-rpc.org/v1/key"
        config = create_base_config()
        config["base_rpc"] = secret_rpc
        runner = populate_healthy_runner(config)
        runner.exceptions[secret_rpc] = TimeoutError(f"Cast chain-id query timed out after 15.0s on {secret_rpc}")

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()

        net_check = next(c for c in report["checks"] if c["name"] == "network_base_sepolia")
        self.assertEqual(net_check["status"], Status.ERROR.value)
        self.assertIn("timed out", net_check["message"])
        self.assertNotIn("token999", net_check["message"])
        self.assertNotIn("token999", json.dumps(net_check["evidence"]))

    # 37. Regression Test 1: Explicit verification of six-field record order
    def test_37_callback_record_six_field_order(self):
        block_num = 7777777
        reactive_addr = "0x2222222222222222222222222222222222222222"
        cb_index = 42
        dest_chain = 1301
        dest_tx = 0x9876543210abcdef9876543210abcdef9876543210abcdef9876543210abcdef
        err_bytes = "0x"

        # Verify formatted tuple parsing
        tuple_str = f"[({block_num}, {reactive_addr}, {cb_index}, {dest_chain}, {dest_tx}, {err_bytes})]"
        records, err = decode_callback_records(tuple_str)
        self.assertIsNone(err)
        self.assertEqual(len(records), 1)
        r = records[0]
        self.assertEqual(r["block_number"], block_num)
        self.assertEqual(r["reactive_contract"], reactive_addr.lower())
        self.assertEqual(r["callback_index"], cb_index)
        self.assertEqual(r["destination_chain_id"], dest_chain)
        self.assertEqual(r["destination_tx_hash"], dest_tx)
        self.assertEqual(r["error"], "0x")
        self.assertTrue(r["success"])

        # Verify raw ABI hex decoding produces identical mapping
        raw_hex = encode_abi_callback_array([(block_num, reactive_addr, cb_index, dest_chain, dest_tx, "")])
        raw_records, raw_err = decode_callback_records(raw_hex)
        self.assertIsNone(raw_err)
        self.assertEqual(len(raw_records), 1)
        raw_r = raw_records[0]
        self.assertEqual(raw_r["block_number"], block_num)
        self.assertEqual(raw_r["reactive_contract"], reactive_addr.lower())
        self.assertEqual(raw_r["callback_index"], cb_index)
        self.assertEqual(raw_r["destination_chain_id"], dest_chain)
        self.assertEqual(raw_r["destination_tx_hash"], dest_tx)
        self.assertEqual(raw_r["error"], "0x")
        self.assertTrue(raw_r["success"])

    # 38. Regression Test 2: Destination chain validation reads field four
    def test_38_destination_chain_validation_reads_field_four(self):
        # Place 1301 in field 1 (blockNumber) but 99999 in field 4 (destinationChainId)
        tuple_str = "[(1301, 0x2222222222222222222222222222222222222222, 1, 99999, 101, 0x)]"
        records, err = decode_callback_records(tuple_str)
        self.assertIsNone(err)
        self.assertEqual(records[0]["block_number"], 1301)
        self.assertEqual(records[0]["destination_chain_id"], 99999)

        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_addr, sig, config["reactive_rpc"])] = tuple_str

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()
        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.CRITICAL.value)
        self.assertIn("destination chain ID mismatch", rec_check["message"])

    # 39. Regression Test 3: Reactive contract validation reads field two
    def test_39_reactive_contract_validation_reads_field_two(self):
        expected_addr = "0x2222222222222222222222222222222222222222"
        tuple_str = f"[(5000000, {expected_addr}, 1, 1301, 101, 0x)]"
        records, err = decode_callback_records(tuple_str)
        self.assertIsNone(err)
        self.assertEqual(records[0]["reactive_contract"], expected_addr.lower())

    # 40. Regression Test 4: Callback index reads field three (not gas limit)
    def test_40_callback_index_reads_field_three(self):
        tuple_str = "[(5000000, 0x2222222222222222222222222222222222222222, 7, 1301, 101, 0x)]"
        records, err = decode_callback_records(tuple_str)
        self.assertIsNone(err)
        self.assertEqual(records[0]["callback_index"], 7)
        self.assertNotIn("gas_limit", records[0])

    # 41. Regression Test 5: Destination transaction hash reads field five (not gas price)
    def test_41_destination_tx_hash_reads_field_five(self):
        dest_tx = 0x5555555555555555555555555555555555555555555555555555555555555555
        tuple_str = f"[(5000000, 0x2222222222222222222222222222222222222222, 1, 1301, {dest_tx}, 0x)]"
        records, err = decode_callback_records(tuple_str)
        self.assertIsNone(err)
        self.assertEqual(records[0]["destination_tx_hash"], dest_tx)
        self.assertNotIn("gas_price", records[0])

    # 42. Regression Test 11: Unexpected requesting Reactive contract triggers CRITICAL
    def test_42_unexpected_reactive_contract_triggers_critical(self):
        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        # Reactive contract in field two is an unauthorized third-party contract
        impostor_addr = "0x9999999999999999999999999999999999999999"
        runner.call_map[(sys_addr, sig, config["reactive_rpc"])] = (
            f"[(5000000, {impostor_addr}, 1, 1301, 101, 0x)]"
        )

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()
        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.CRITICAL.value)
        self.assertIn("requesting Reactive contract mismatch", rec_check["message"])

    # 43. Regression Test 15: Malformed formatted tuple (fewer than 6 fields)
    def test_43_malformed_formatted_tuple_field_count(self):
        # Only 4 fields
        tuple_str = "[(5000000, 0x2222222222222222222222222222222222222222, 1, 1301)]"
        records, err = decode_callback_records(tuple_str)
        self.assertIsNone(records)
        self.assertIn("Expected 6 fields per record", err)

        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_addr, sig, config["reactive_rpc"])] = tuple_str

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()
        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.ERROR.value)
        self.assertIn("Failed to decode callback records ABI", rec_check["message"])

    # 44. Regression Test 15b: Malformed formatted tuple (non-numeric field)
    def test_44_malformed_formatted_tuple_invalid_data(self):
        tuple_str = "[(NOT_A_NUMBER, 0x2222222222222222222222222222222222222222, 1, 1301, 101, 0x)]"
        records, err = decode_callback_records(tuple_str)
        self.assertIsNone(records)
        self.assertIn("Error parsing formatted tuple fields", err)

    # 45. Regression Test 12b: Zero destination transaction hash in raw ABI hex
    def test_45_callback_zero_destination_tx_hash_raw_hex(self):
        raw_hex = encode_abi_callback_array([
            (5000000, "0x2222222222222222222222222222222222222222", 1, 1301, 0, "")
        ])
        records, err = decode_callback_records(raw_hex)
        self.assertIsNone(err)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["destination_tx_hash"], 0)
        self.assertFalse(records[0]["success"])
        self.assertTrue(records[0]["is_pending"])

        config = create_base_config()
        config["reactive_tx_hash"] = "0x1234"
        runner = populate_healthy_runner(config)
        sys_addr = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_addr, sig, config["reactive_rpc"])] = raw_hex

        checker = CrossGuardHealthChecker(config, runner)
        report = checker.run_all_checks()
        rec_check = next(c for c in report["checks"] if c["name"] == "callback_record_inspection")
        self.assertEqual(rec_check["status"], Status.UNKNOWN.value)
        self.assertIn("destination transaction hash is zero", rec_check["message"])
        self.assertNotEqual(rec_check["status"], Status.PASS.value)


    # =========================================================================
    # Workstream D: Strict Recovery Preflight & Economics Tests (Tests 46-100)
    # =========================================================================

    def _get_test_position_id(self) -> str:
        return "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"

    def _get_test_tx_hash(self) -> str:
        return "0x" + "aa" * 32

    def _setup_preflight_runner(
        self, config: Dict[str, Any], position_id: str, tx_hash: Optional[str] = None
    ) -> MockRpcRunner:
        runner = populate_healthy_runner(config)
        origin = config["origin_risk_controller"].lower()
        reactive = config["reactive_address"].lower()
        dest = config["borrowing_controller_address"].lower()
        sys_contract = config["system_contract"].lower()
        proxy = config["callback_proxy"].lower()
        cb_adapter = config["callback_address"].lower()

        base_rpc = config["base_rpc"]
        reactive_rpc = config["reactive_rpc"]
        unichain_rpc = config["unichain_rpc"]
        txh = (tx_hash or self._get_test_tx_hash()).lower()

        # Origin state
        runner.call_map[(origin, "positionNonce(bytes32)", base_rpc)] = "1"
        runner.call_map[(origin, "isPositionBreached(bytes32)", base_rpc)] = "true"

        # Reactive state (5-tuple: nonce=1, eventType=1 (BREACH), payload=0x11223344, retryCount=0, status=2 (REQUESTED))
        runner.call_map[(reactive, "latestOriginNonce(bytes32)", reactive_rpc)] = "1"
        runner.call_map[(reactive, "getLatestCallback(bytes32)", reactive_rpc)] = "(1, 1, 0x11223344, 0, 2)"
        runner.call_map[(reactive, "destinationCallback()", reactive_rpc)] = cb_adapter
        runner.call_map[(reactive, "destinationChainId()", reactive_rpc)] = str(UNICHAIN_SEPOLIA_CHAIN_ID)
        runner.call_map[(reactive, "callbackGasLimit()", reactive_rpc)] = "300000"

        # Destination state
        runner.call_map[(dest, "lastProcessedNonce(bytes32)", unichain_rpc)] = "0"
        runner.call_map[(dest, "isBorrowingPaused(bytes32)", unichain_rpc)] = "false"
        runner.call_map[(dest, "pausedByRiskBreach(bytes32)", unichain_rpc)] = "false"
        runner.call_map[(dest, "pausedByAdmin(bytes32)", unichain_rpc)] = "false"

        # Economics & on-chain fee parameters (System Contract & Callback Proxy)
        runner.call_map[(sys_contract, "debt(address)", reactive_rpc)] = "0"
        runner.call_map[(sys_contract, "reserves(address)", reactive_rpc)] = str(10**18)
        runner.call_map[(sys_contract, "_gasPriceCoeffPer1000()", reactive_rpc)] = "1000"
        runner.call_map[(sys_contract, "_extraGas()", reactive_rpc)] = "50000"
        runner.call_map[(sys_contract, "_maxChargeGas()", reactive_rpc)] = "1000000"
        runner.gas_prices[reactive_rpc] = 1_000_000_000
        runner.base_fees[reactive_rpc] = 500_000_000

        runner.call_map[(proxy, "debt(address)", unichain_rpc)] = "0"
        runner.call_map[(proxy, "reserves(address)", unichain_rpc)] = str(10**18)
        runner.call_map[(proxy, "_gasPriceCoeffPer1000()", unichain_rpc)] = "1000"
        runner.call_map[(proxy, "_extraGas()", unichain_rpc)] = "50000"
        runner.call_map[(proxy, "_maxChargeGas()", unichain_rpc)] = "1000000"
        runner.gas_prices[unichain_rpc] = 1_000_000_000
        runner.base_fees[unichain_rpc] = 500_000_000

        # Transaction receipt on Reactive Lasna
        clean_pos = position_id.lower()
        if not clean_pos.startswith("0x"):
            clean_pos = "0x" + clean_pos
        runner.receipts[(txh, reactive_rpc)] = {
            "status": "0x1",
            "logs": [
                {
                    "address": reactive,
                    "topics": [
                        REACTIVE_BREACH_PROCESSED_TOPIC,
                        clean_pos,
                        "0x0000000000000000000000000000000000000000000000000000000000000001",
                    ],
                    "data": "0x",
                },
                {
                    "address": sys_contract,
                    "topics": [
                        CALLBACK_REQUEST_TOPIC,
                        "0x0000000000000000000000000000000000000000000000000000000000000515",
                        "0x000000000000000000000000" + reactive[2:],
                        "0x000000000000000000000000" + cb_adapter[2:],
                    ],
                    "data": encode_callback_request_data(1301, cb_adapter, 300_000, "0x11223344"),
                },
            ],
        }

        # Callback record confirming destination execution failure (nonzero dest tx hash + nonempty error)
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_contract, sig, reactive_rpc)] = (
            f"[(100, {reactive}, 1, 1301, 8888, 0x08c379a0)]"
        )

        return runner

    # 46. RETRY_ELIGIBLE requires confirmed destination failure evidence (nonzero hash + nonempty error)
    def test_46_preflight_eligible_destination_failure(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)

        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_ELIGIBLE.value)
        self.assertIsNone(report["suggested_command"])
        self.assertEqual(report["reactive_state"]["stored_callback_nonce"], 1)
        self.assertEqual(report["destination_state"]["last_processed_nonce"], 0)
        self.assertIn("confirmed destination execution failure", report["reason"])

    # 47. RETRY_ALREADY_SUCCEEDED when destination lastProcessedNonce >= expected nonce
    def test_47_preflight_already_succeeded_destination_nonce(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        dest = config["borrowing_controller_address"].lower()
        runner.call_map[(dest, "lastProcessedNonce(bytes32)", config["unichain_rpc"])] = "1"
        runner.call_map[(dest, "isBorrowingPaused(bytes32)", config["unichain_rpc"])] = "true"

        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_ALREADY_SUCCEEDED.value)
        self.assertIsNone(report["suggested_command"])
        self.assertIn("already processed nonce 1", report["reason"])

    # 48. RETRY_UNKNOWN if callback record has nonzero dest tx + empty error, yet destination nonce < expected_nonce
    def test_48_preflight_contradictory_empty_error_with_dest_behind(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        sys_contract = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_contract, sig, config["reactive_rpc"])] = (
            f"[(100, {config['reactive_address']}, 1, 1301, 999, 0x)]"
        )

        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("empty error", report["reason"])
        self.assertIn("still below 1", report["reason"])

    # 49. RETRY_PENDING when destination transaction hash is zero (0)
    def test_49_preflight_pending_zero_destination_tx_hash(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        sys_contract = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_contract, sig, config["reactive_rpc"])] = (
            f"[(100, {config['reactive_address']}, 1, 1301, 0, 0x)]"
        )

        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_PENDING.value)
        self.assertIn("pending delivery by relayer", report["reason"])

    # 50. RETRY_PENDING when callback records array is empty
    def test_50_preflight_pending_empty_callback_records(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        sys_contract = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_contract, sig, config["reactive_rpc"])] = "[]"

        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_PENDING.value)
        self.assertIn("empty or pending finalization", report["reason"])

    # 51. RETRY_BLOCKED when retry budget exhausted (3 retries)
    def test_51_preflight_blocked_retry_limit_exceeded(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        reactive = config["reactive_address"].lower()
        runner.call_map[(reactive, "getLatestCallback(bytes32)", config["reactive_rpc"])] = "(1, 1, 0x11223344, 3, 2)"

        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("Retry limit exceeded", report["reason"])

    # 52. Reactive debt (warns by default, blocks under conservative policy) vs Callback Proxy debt
    def test_52_preflight_blocked_system_contract_debt(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        sys_contract = config["system_contract"].lower()
        runner.call_map[(sys_contract, "debt(address)", config["reactive_rpc"])] = "50000"

        # Default: System Contract debt threatens automated react(), NOT destination Callback Proxy delivery -> warns visibly without false Proxy block
        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_ELIGIBLE.value)
        self.assertTrue(any("50000 wei debt on System Contract" in w for w in report["warnings"]))
        self.assertTrue(report["economics"]["reactive_event_processing_path"]["has_debt_or_low_reserves"])
        self.assertFalse(report["economics"]["destination_callback_delivery_path"]["has_debt_or_low_reserves"])

        # Explicit conservative whole-pipeline gate blocks on Reactive System Contract debt
        strict_cfg = dict(config, require_reactive_reserves=True)
        report_strict = run_recovery_preflight(
            strict_cfg, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report_strict["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("outstanding debt of 50000 wei on System Contract", report_strict["reason"])

    # 53. RETRY_BLOCKED when Callback Proxy debt is outstanding
    def test_53_preflight_blocked_callback_proxy_debt(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        proxy = config["callback_proxy"].lower()
        runner.call_map[(proxy, "debt(address)", config["unichain_rpc"])] = "75000"

        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("outstanding debt of 75000 wei on Callback Proxy", report["reason"])

    # 54. RETRY_BLOCKED when destination callback address is unconfigured (zero address)
    def test_54_preflight_blocked_destination_callback_zero(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        reactive = config["reactive_address"].lower()
        runner.call_map[(reactive, "destinationCallback()", config["reactive_rpc"])] = (
            "0x0000000000000000000000000000000000000000"
        )

        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("Destination callback contract is not configured", report["reason"])

    # 55. RETRY_BLOCKED when destination chain ID is not Unichain Sepolia (1301)
    def test_55_preflight_blocked_destination_chain_mismatch(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        reactive = config["reactive_address"].lower()
        runner.call_map[(reactive, "destinationChainId()", config["reactive_rpc"])] = "1"

        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("destination chain ID (1) is invalid", report["reason"])

    # 56. RETRY_BLOCKED when callback gas limit is below minimum 100,000
    def test_56_preflight_blocked_gas_limit_too_low(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        reactive = config["reactive_address"].lower()
        runner.call_map[(reactive, "callbackGasLimit()", config["reactive_rpc"])] = "99999"

        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("callback gas limit (99999) is below minimum", report["reason"])

    # 57. RETRY_BLOCKED when no callback payload is stored for position
    def test_57_preflight_blocked_no_stored_payload(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        reactive = config["reactive_address"].lower()
        runner.call_map[(reactive, "getLatestCallback(bytes32)", config["reactive_rpc"])] = "(0, 0, 0x, 0, 0)"

        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("No callback payload stored", report["reason"])

    # 58. RETRY_SUPERSEDED when origin has advanced to a newer nonce
    def test_58_preflight_superseded_newer_origin_nonce(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        origin = config["origin_risk_controller"].lower()
        runner.call_map[(origin, "positionNonce(bytes32)", config["base_rpc"])] = "2"
        runner.call_map[(origin, "isPositionBreached(bytes32)", config["base_rpc"])] = "false"

        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_SUPERSEDED.value)
        self.assertIn("superseded by newer state", report["reason"])

    # 59. RETRY_UNKNOWN on unexpected RPC exception
    def test_59_preflight_unknown_on_rpc_exception(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        origin = config["origin_risk_controller"].lower()
        runner.exceptions[(origin, "positionNonce(bytes32)", config["base_rpc"])] = (
            RuntimeError("Connection timeout to Base Sepolia")
        )

        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("Failed to query origin state", report["reason"])

    # 60. RETRY_UNKNOWN on invalid position ID format
    def test_60_preflight_invalid_position_id_format(self):
        config = create_base_config()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, "0x1234", tx_hash)

        report = run_recovery_preflight(
            config, position_id="not-a-valid-32byte-hex", expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("Invalid position ID format", report["reason"])

    # 61. RETRY_UNKNOWN on missing configuration
    def test_61_preflight_missing_config(self):
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = MockRpcRunner()
        incomplete_config = {"base_rpc": None}

        report = run_recovery_preflight(
            incomplete_config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(report["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("Missing required", report["reason"])

    # 62. CastRpcRunner whitelist allows read-only subcommands only
    def test_62_cast_runner_allows_read_only_subcommands(self):
        self.assertIn("receipt", CastRpcRunner.ALLOWED_SUBCOMMANDS)
        self.assertIn("gas-price", CastRpcRunner.ALLOWED_SUBCOMMANDS)
        self.assertIn("base-fee", CastRpcRunner.ALLOWED_SUBCOMMANDS)

    # 63. CastRpcRunner rejects forbidden subcommands or flags
    def test_63_cast_runner_rejects_forbidden_subcommands_or_flags(self):
        runner = CastRpcRunner(cast_path="cast")
        with self.assertRaises(PermissionError):
            runner._execute("send", ["0x1234", "--rpc-url", "https://rpc.test"])
        with self.assertRaises(PermissionError):
            runner._execute("call", ["0x1234", "--private-key", "0xabc"])
        with self.assertRaises(PermissionError):
            runner._execute("mktx", ["0x1234", "--rpc-url", "https://rpc.test"])

    # 64. MockRpcRunner supports get_receipt, get_gas_price, get_base_fee
    def test_64_mock_runner_supports_receipt_and_fee_queries(self):
        runner = MockRpcRunner()
        runner.receipts[("0xabc", "https://rpc.test")] = {"status": "0x1", "logs": []}
        runner.gas_prices["https://rpc.test"] = 1_500_000_000
        runner.base_fees["https://rpc.test"] = 1_000_000_000
        self.assertEqual(runner.get_receipt("0xabc", "https://rpc.test")["status"], "0x1")
        self.assertEqual(runner.get_gas_price("https://rpc.test"), 1_500_000_000)
        self.assertEqual(runner.get_base_fee("https://rpc.test"), 1_000_000_000)

    # 65. Credential redaction in preflight terminal and JSON output
    def test_65_credential_redaction_in_preflight_terminal_and_json(self):
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        config = {
            "base_rpc": "https://api_key_secret_base@base-sepolia.rpc.test/v1/sec123",
            "reactive_rpc": "https://user:pass@reactive-lasna.rpc.test/v1/sec456",
            "unichain_rpc": "https://unichain-sepolia.rpc.test/?apikey=secret789",
            "origin_risk_controller": "0x1111111111111111111111111111111111111111",
            "origin_collateral_vault": "0x5555555555555555555555555555555555555555",
            "reactive_address": "0x2222222222222222222222222222222222222222",
            "callback_address": "0x3333333333333333333333333333333333333333",
            "borrowing_controller_address": "0x4444444444444444444444444444444444444444",
            "system_contract": DEFAULT_SYSTEM_CONTRACT,
            "callback_proxy": DEFAULT_CALLBACK_PROXY,
        }
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )

        report_json = json.dumps(report)
        self.assertNotIn("sec123", report_json)
        self.assertNotIn("pass", report_json)
        self.assertNotIn("secret789", report_json)

        term_report = format_recovery_preflight_terminal(report)
        self.assertNotIn("sec123", term_report)
        self.assertNotIn("pass", term_report)
        self.assertNotIn("secret789", term_report)
        self.assertNotIn("cast send", term_report)

    # 66. Preflight report contains explicit safety disclaimers and NO cast send command
    def test_66_preflight_report_safety_disclaimer_and_no_cast_send(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        report = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )

        self.assertIsNone(report["suggested_command"])
        self.assertEqual(report["execution"], "NOT PERFORMED (read-only preflight diagnostic)")
        term_text = format_recovery_preflight_terminal(report)
        self.assertIn("Execution: NOT PERFORMED (read-only preflight diagnostic)", term_text)
        self.assertIn("No private keys used, no transactions broadcast, no state mutated", term_text)
        self.assertIn("does not guarantee future callback delivery", term_text)
        self.assertNotIn("cast send", term_text)

    # 67. Recovery exit code behavior (all 7 states)
    def test_67_recovery_exit_code_behavior(self):
        self.assertEqual(compute_recovery_exit_code(RecoveryStatus.DISPATCH_REQUIRED.value), 0)
        self.assertEqual(compute_recovery_exit_code(RecoveryStatus.RETRY_ELIGIBLE.value), 0)
        self.assertEqual(compute_recovery_exit_code(RecoveryStatus.RETRY_ALREADY_SUCCEEDED.value), 0)
        self.assertEqual(compute_recovery_exit_code(RecoveryStatus.RETRY_BLOCKED.value), 1)
        self.assertEqual(compute_recovery_exit_code(RecoveryStatus.RETRY_PENDING.value), 1)
        self.assertEqual(compute_recovery_exit_code(RecoveryStatus.RETRY_SUPERSEDED.value), 1)
        self.assertEqual(compute_recovery_exit_code(RecoveryStatus.RETRY_UNKNOWN.value), 1)

    # 68. Missing mandatory inputs return RETRY_UNKNOWN
    def test_68_missing_mandatory_inputs_return_unknown(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)

        r1 = run_recovery_preflight(config, position_id=None, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(r1["status"], RecoveryStatus.RETRY_UNKNOWN.value)

        r2 = run_recovery_preflight(config, position_id=pos_id, expected_nonce=None, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(r2["status"], RecoveryStatus.RETRY_UNKNOWN.value)

        r3 = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=None, runner=runner)
        self.assertEqual(r3["status"], RecoveryStatus.RETRY_UNKNOWN.value)

        r4 = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash="0xbad", runner=runner)
        self.assertEqual(r4["status"], RecoveryStatus.RETRY_UNKNOWN.value)

    # 69. Receipt missing or status zero (reverted) -> RETRY_UNKNOWN
    def test_69_receipt_missing_or_reverted(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)

        # Status 0
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["status"] = "0x0"
        rep0 = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep0["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("reverted on Reactive Lasna", rep0["reason"])

        # Missing receipt (empty {})
        del runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]
        rep_miss = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_miss["status"], RecoveryStatus.RETRY_UNKNOWN.value)

    # 70. Malformed receipt JSON -> RETRY_UNKNOWN
    def test_70_malformed_receipt_json(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])] = {"status": "0x1", "logs": "not-a-list"}

        rep = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_UNKNOWN.value)

    # 71. Receipt position mismatch -> RETRY_UNKNOWN
    def test_71_receipt_position_mismatch(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        other_pos = "0x" + "ff" * 32
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][0]["topics"][1] = other_pos

        rep = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("does not match expected position ID", rep["reason"])

    # 72. Receipt nonce mismatch -> RETRY_UNKNOWN
    def test_72_receipt_nonce_mismatch(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][0]["topics"][2] = (
            "0x0000000000000000000000000000000000000000000000000000000000000009"
        )

        rep = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("does not match expected nonce", rep["reason"])

    # 73. Receipt containing multiple conflicting CrossGuard events -> RETRY_UNKNOWN
    def test_73_receipt_multiple_conflicting_events(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        reactive = config["reactive_address"].lower()
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"].append({
            "address": reactive,
            "topics": [
                REACTIVE_RESOLVED_PROCESSED_TOPIC,
                pos_id,
                "0x0000000000000000000000000000000000000000000000000000000000000002",
            ],
            "data": "0x",
        })

        rep = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("conflicting CrossGuardReactive operational events", rep["reason"])

    # 74. Receipt missing CallbackRequest or emitted by wrong System Contract or targeting wrong recipient/chain
    def test_74_receipt_callback_request_validation_failures(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()

        # Case A: Wrong System Contract emitter
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["address"] = "0x9999999999999999999999999999999999999999"
        rep_sys = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_sys["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("unexpected contract", rep_sys["reason"])

        # Case B: Wrong destination chain ID in CallbackRequest (e.g. 1 instead of 1301) -> BLOCKED
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        cb_adapter = config["callback_address"].lower()
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["topics"][1] = (
            "0x0000000000000000000000000000000000000000000000000000000000000001"
        )
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["data"] = (
            encode_callback_request_data(1, cb_adapter, 300_000, "0x11223344")
        )
        rep_cid = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_cid["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("unsupported destination chain ID 1", rep_cid["reason"])

        # Case C: Wrong recipient in CallbackRequest -> UNKNOWN
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        wrong_rcp = "0x9999999999999999999999999999999999999999"
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["topics"][3] = (
            "0x000000000000000000000000" + wrong_rcp[2:]
        )
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["data"] = (
            encode_callback_request_data(1301, wrong_rcp, 300_000, "0x11223344")
        )
        rep_rcp = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_rcp["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("does not match configured CrossGuardCallback", rep_rcp["reason"])

        # Case D: Missing CallbackRequest entirely -> UNKNOWN
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"].pop(1)
        rep_miss = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_miss["status"], RecoveryStatus.RETRY_UNKNOWN.value)

    # 75. DISPATCH_REQUIRED when CallbackDispatchDeferred matches PENDING_DISPATCH state
    def test_75_dispatch_required_on_deferred_event(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        reactive = config["reactive_address"].lower()
        sys_contract = config["system_contract"].lower()

        runner.call_map[(reactive, "getLatestCallback(bytes32)", config["reactive_rpc"])] = "(1, 1, 0x11223344, 0, 1)"
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])] = {
            "status": "0x1",
            "logs": [{
                "address": reactive,
                "topics": [
                    CALLBACK_DISPATCH_DEFERRED_TOPIC,
                    pos_id,
                    "0x0000000000000000000000000000000000000000000000000000000000000001",
                    "0x0000000000000000000000000000000000000000000000000000000000000001",
                ],
                "data": "0x",
            }],
        }
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_contract, sig, config["reactive_rpc"])] = "[]"

        rep = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(rep["status"], RecoveryStatus.DISPATCH_REQUIRED.value)
        self.assertIsNone(rep["suggested_command"])
        self.assertIn("dispatchPendingCallback", rep["remediation"])

    # 76. Deferred receipt with superseded or mismatching status -> SUPERSEDED / UNKNOWN
    def test_76_deferred_receipt_superseded_and_mismatch_states(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        reactive = config["reactive_address"].lower()
        origin = config["origin_risk_controller"].lower()

        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])] = {
            "status": "0x1",
            "logs": [{
                "address": reactive,
                "topics": [
                    CALLBACK_DISPATCH_DEFERRED_TOPIC,
                    pos_id,
                    "0x0000000000000000000000000000000000000000000000000000000000000001",
                    "0x0000000000000000000000000000000000000000000000000000000000000001",
                ],
                "data": "0x",
            }],
        }

        # Case A: Mismatch - stored status is REQUESTED (2) while receipt says Deferred -> UNKNOWN
        rep_mis = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(rep_mis["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("expected PENDING_DISPATCH", rep_mis["reason"])

        # Case B: Superseded - origin nonce 2 while deferred nonce 1 -> RETRY_SUPERSEDED
        runner.call_map[(reactive, "getLatestCallback(bytes32)", config["reactive_rpc"])] = "(1, 1, 0x11223344, 0, 1)"
        runner.call_map[(origin, "positionNonce(bytes32)", config["base_rpc"])] = "2"
        rep_sup = run_recovery_preflight(
            config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner
        )
        self.assertEqual(rep_sup["status"], RecoveryStatus.RETRY_SUPERSEDED.value)

    # 77. Multiple callback records: unambiguous match vs ambiguous match
    def test_77_callback_records_unambiguous_and_ambiguous_matching(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        reactive = config["reactive_address"].lower()
        sys_contract = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"

        # Case A: 2 records, only 1 matches our reactive address -> unambiguous match -> RETRY_ELIGIBLE
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        other_reactive = "0x9999999999999999999999999999999999999999"
        runner.call_map[(sys_contract, sig, config["reactive_rpc"])] = (
            f"[(100, {other_reactive}, 0, 1301, 777, 0x), (100, {reactive}, 1, 1301, 8888, 0x08c379a0)]"
        )
        rep_ok = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_ok["status"], RecoveryStatus.RETRY_ELIGIBLE.value)

        # Case B: 2 records matching same reactive address & chain -> ambiguous -> RETRY_UNKNOWN
        runner.call_map[(sys_contract, sig, config["reactive_rpc"])] = (
            f"[(100, {reactive}, 0, 1301, 777, 0x08c379a0), (100, {reactive}, 1, 1301, 8888, 0x08c379a0)]"
        )
        rep_amb = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_amb["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("ambiguous", rep_amb["reason"])

    # 78. Error bytes present with zero destination tx hash -> NEVER RETRY_ELIGIBLE (RETRY_UNKNOWN)
    def test_78_error_bytes_with_zero_destination_tx_hash(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        sys_contract = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_contract, sig, config["reactive_rpc"])] = (
            f"[(100, {config['reactive_address']}, 1, 1301, 0, 0xdeadbeef)]"
        )

        rep = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertNotEqual(rep["status"], RecoveryStatus.RETRY_ELIGIBLE.value)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_UNKNOWN.value)

    # 79. Fail-closed economic queries (failed or malformed debt/reserves/fee params/gas-price/base-fee)
    def test_79_economic_queries_fail_closed_never_zero(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        sys_contract = config["system_contract"].lower()
        proxy = config["callback_proxy"].lower()
        r_rpc = config["reactive_rpc"]
        u_rpc = config["unichain_rpc"]

        failing_calls = [
            (sys_contract, "debt(address)", r_rpc),
            (sys_contract, "reserves(address)", r_rpc),
            (sys_contract, "_gasPriceCoeffPer1000()", r_rpc),
            (sys_contract, "_extraGas()", r_rpc),
            (sys_contract, "_maxChargeGas()", r_rpc),
            (proxy, "debt(address)", u_rpc),
            (proxy, "reserves(address)", u_rpc),
            (proxy, "_gasPriceCoeffPer1000()", u_rpc),
            (proxy, "_extraGas()", u_rpc),
            (proxy, "_maxChargeGas()", u_rpc),
        ]

        for key in failing_calls:
            runner = self._setup_preflight_runner(config, pos_id, tx_hash)
            runner.exceptions[key] = RuntimeError("RPC error")
            rep = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
            self.assertEqual(rep["status"], RecoveryStatus.RETRY_UNKNOWN.value, f"Expected RETRY_UNKNOWN when {key} fails")

            # Also malformed value
            runner = self._setup_preflight_runner(config, pos_id, tx_hash)
            runner.call_map[key] = "not-a-number"
            rep_bad = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
            self.assertEqual(rep_bad["status"], RecoveryStatus.RETRY_UNKNOWN.value, f"Expected RETRY_UNKNOWN when {key} malformed")

        # Also test missing / failed gas-price and base-fee
        for fee_key in [("gas-price", u_rpc), ("base-fee", u_rpc), ("gas-price", r_rpc), ("base-fee", r_rpc)]:
            runner = self._setup_preflight_runner(config, pos_id, tx_hash)
            runner.exceptions[fee_key] = RuntimeError("RPC timeout")
            rep_fee = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
            self.assertEqual(rep_fee["status"], RecoveryStatus.RETRY_UNKNOWN.value, f"Expected RETRY_UNKNOWN when {fee_key} fails")

    # 80. Zero reserves or insufficient reserves below conservative fee estimate -> RETRY_BLOCKED
    def test_80_insufficient_or_zero_reserves_blocked(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        proxy = config["callback_proxy"].lower()
        sys_contract = config["system_contract"].lower()

        # Zero Callback Proxy reserves -> BLOCKED
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.call_map[(proxy, "reserves(address)", config["unichain_rpc"])] = "0"
        rep0 = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep0["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("Insufficient Callback Proxy reserves", rep0["reason"])

        # Nonzero but insufficient proxy reserves (e.g. 1 wei) -> BLOCKED (no false reserves > 0 == ok!)
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.call_map[(proxy, "reserves(address)", config["unichain_rpc"])] = "1"
        rep1 = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep1["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("conservative estimate", rep1["reason"])

        # Insufficient Reactive System reserves (1 wei) -> emits REACTIVE_PATH_WARNING by default; RETRY_BLOCKED only if require_reactive_reserves=True
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.call_map[(sys_contract, "reserves(address)", config["reactive_rpc"])] = "1"
        rep_sys_warn = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_sys_warn["status"], RecoveryStatus.RETRY_ELIGIBLE.value)
        self.assertTrue(any("Reactive System Contract reserves (1 wei)" in w for w in rep_sys_warn["warnings"]))

        strict_cfg = dict(config, require_reactive_reserves=True)
        rep_sys_strict = run_recovery_preflight(strict_cfg, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_sys_strict["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("Insufficient Reactive System Contract reserves", rep_sys_strict["reason"])

    # 81. Reserve fee estimator formula, _maxChargeGas separation & assumptions verification
    def test_81_fee_estimator_formula_and_assumptions(self):
        # fee = p_base * (C/1000) * (g_used + K)
        # With p_base=2e9, C=1500 (1.5x), g_used=300_000, K=50_000 -> fee = 2e9 * 1.5 * 350_000 = 1_050_000_000_000_000 wei
        est = estimate_callback_fee_wei(
            gas_limit=300_000,
            p_base_wei=2_000_000_000,
            coeff_per_1000=1500,
            extra_gas=50_000,
            max_charge_gas=50_000,
            safety_multiplier=2,
            settlement_gas_requirement=50_000,
        )
        self.assertEqual(est["estimated_single_callback_fee_wei"], 1_050_000_000_000_000)
        self.assertEqual(est["recommended_min_reserve_wei"], 2_100_000_000_000_000)
        self.assertNotIn("exceeds_max_charge_gas", est)
        self.assertFalse(est["max_charge_gas_in_fee_formula"])
        self.assertEqual(est["settlement_gas_status"], "AT_REQUIREMENT")
        self.assertTrue(est["settlement_gas_sufficient"])
        self.assertIsNone(est["effective_forwarded_gas_exact"])
        self.assertFalse(est["guarantees_future_delivery"])
        self.assertTrue(len(est["assumptions"]) >= 4)

    # 82. 3-State correlation contradictions return RETRY_UNKNOWN (never RETRY_ELIGIBLE)
    def test_82_three_state_contradictions_return_unknown(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        origin = config["origin_risk_controller"].lower()
        reactive = config["reactive_address"].lower()

        # Origin breached=false contradicts BREACH stored callback at matching nonce 1
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.call_map[(origin, "isPositionBreached(bytes32)", config["base_rpc"])] = "false"
        rep_o = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_o["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("contradicts", rep_o["reason"])

        # Stored callback type RESOLVED (2) contradicts ReactiveBreachProcessed receipt topic
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.call_map[(reactive, "getLatestCallback(bytes32)", config["reactive_rpc"])] = "(1, 2, 0x11223344, 0, 2)"
        rep_t = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_t["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("contradicts", rep_t["reason"])

        # Non-deferred receipt while stored status is PENDING_DISPATCH (1) -> RETRY_UNKNOWN
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.call_map[(reactive, "getLatestCallback(bytes32)", config["reactive_rpc"])] = "(1, 1, 0x11223344, 0, 1)"
        rep_s = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_s["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("Contradictory dispatch state", rep_s["reason"])

    # 83. Cross-contract destination wiring mismatch blocks retry (RETRY_BLOCKED)
    def test_83_destination_wiring_mismatch_blocked(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        cb_adapter = config["callback_address"].lower()
        runner.call_map[(cb_adapter, "authorizedReactiveSender()", config["unichain_rpc"])] = "0x9999999999999999999999999999999999999999"

        rep = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("authorizedReactiveSender mismatch", rep["reason"])

    # 84. Ethereum Keccak-256 verification (distinct from NIST SHA3-256)
    def test_84_ethereum_keccak256_event_signature_verification(self):
        import hashlib
        sig = "ReactiveBreachProcessed(bytes32,uint256,uint256,uint256)"
        eth_topic = keccak256_topic(sig)
        nist_sha3 = "0x" + hashlib.sha3_256(sig.encode("utf-8")).hexdigest()
        self.assertNotEqual(eth_topic, nist_sha3)
        self.assertEqual(eth_topic, "0xb44a2925d48889fa1efb56042835dcead754facb2fe908899dc1880829fc1bfd")
        self.assertEqual(CALLBACK_DISPATCH_DEFERRED_TOPIC, keccak256_topic("CallbackDispatchDeferred(bytes32,uint256,uint8,string)"))
        self.assertEqual(CALLBACK_DISPATCH_SUBMITTED_TOPIC, keccak256_topic("CallbackDispatchSubmitted(bytes32,uint256,uint8)"))
        self.assertEqual(CALLBACK_RETRY_REQUESTED_TOPIC, keccak256_topic("CallbackRetryRequested(bytes32,uint256,uint8,bytes32)"))
        self.assertEqual(CALLBACK_REQUEST_TOPIC, keccak256_topic("CallbackRequest(uint256,address,address,uint8,bytes)"))
        self.assertEqual(keccak256(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

    # 85. Strict decoders unit tests (uint, bool, address, bytes, 5-tuple ABI)
    def test_85_strict_decoders(self):
        self.assertEqual(decode_uint_strict("300000 [3e5]"), 300000)
        self.assertEqual(decode_uint_strict("0x0515"), 1301)
        for bad_u in (None, "", "0x", "-1", "abc", "10 junk", True):
            with self.assertRaises(ValueError):
                decode_uint_strict(bad_u)

        self.assertTrue(decode_bool_strict("true"))
        self.assertFalse(decode_bool_strict("false"))
        self.assertTrue(decode_bool_strict("0x" + "0" * 63 + "1"))
        self.assertFalse(decode_bool_strict("0x" + "0" * 64))
        for bad_b in (None, "", "0x", "maybe", "2"):
            with self.assertRaises(ValueError):
                decode_bool_strict(bad_b)

        addr = decode_address_strict("0x" + "0" * 24 + "AbCd" * 10)
        self.assertEqual(addr, "0x" + "abcd" * 10)
        with self.assertRaises(ValueError):
            decode_address_strict("0x" + "1" * 24 + "abcd" * 10)  # dirty upper ABI word bits
        with self.assertRaises(ValueError):
            decode_address_strict("0x1234")  # short address

        self.assertEqual(decode_bytes_strict("0xAABB"), "0xaabb")
        with self.assertRaises(ValueError):
            decode_bytes_strict("0xabc")  # odd length

        # 5-tuple raw ABI hex encoding test for getLatestCallback
        raw_abi = (
            "0x"
            + (2).to_bytes(32, "big").hex()     # nonce = 2
            + (1).to_bytes(32, "big").hex()     # eventType = 1 (BREACH)
            + (160).to_bytes(32, "big").hex()   # bytes offset = 160
            + (1).to_bytes(32, "big").hex()     # retryCount = 1
            + (2).to_bytes(32, "big").hex()     # status = 2 (REQUESTED)
            + (4).to_bytes(32, "big").hex()     # payload length = 4
            + b"\xde\xad\xbe\xef".ljust(32, b"\x00").hex()
        )
        n, t, p, r, s = decode_get_latest_callback_strict(raw_abi)
        self.assertEqual((n, t, p, r, s), (2, 1, "0xdeadbeef", 1, 2))
        with self.assertRaises(ValueError):
            decode_get_latest_callback_strict("0x1234")  # truncated ABI hex

    # 86. Callback lookup exception and malformed callback ABI in preflight -> RETRY_UNKNOWN
    def test_86_callback_lookup_exception_and_malformed_abi(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        sys_contract = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"

        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.exceptions[(sys_contract, sig, config["reactive_rpc"])] = RuntimeError("getCallbacks timeout")
        rep_exc = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_exc["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("Failed to query getCallbacks", rep_exc["reason"])

        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.call_map[(sys_contract, sig, config["reactive_rpc"])] = "0x1234"  # malformed ABI
        rep_mal = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_mal["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("Failed to parse callback records ABI", rep_mal["reason"])

    # 87. Wrong CrossGuard emitter & multiple CallbackRequests in receipt -> RETRY_UNKNOWN
    def test_87_wrong_crossguard_emitter_and_multiple_callback_requests(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        sys_contract = config["system_contract"].lower()
        reactive = config["reactive_address"].lower()
        cb_adapter = config["callback_address"].lower()

        # Wrong CrossGuard emitter
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][0]["address"] = "0x9999999999999999999999999999999999999999"
        rep_emit = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_emit["status"], RecoveryStatus.RETRY_UNKNOWN.value)

        # Multiple CallbackRequest logs from System Contract -> ambiguous -> RETRY_UNKNOWN
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"].append({
            "address": sys_contract,
            "topics": [
                CALLBACK_REQUEST_TOPIC,
                "0x0000000000000000000000000000000000000000000000000000000000000515",
                "0x000000000000000000000000" + reactive[2:],
                "0x000000000000000000000000" + cb_adapter[2:],
            ],
            "data": encode_callback_request_data(1301, cb_adapter, 300_000, "0x11223344"),
        })
        rep_multi = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_multi["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("CallbackRequest logs", rep_multi["reason"])

    # 88. CallbackDispatchSubmitted, CallbackRetryRequested, and deferred RESOLVED correlation
    def test_88_dispatch_submitted_retry_and_deferred_resolved_correlation(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        origin = config["origin_risk_controller"].lower()
        reactive = config["reactive_address"].lower()
        sys_contract = config["system_contract"].lower()
        cb_adapter = config["callback_address"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"

        # Case A: CallbackRetryRequested receipt with failure record -> RETRY_ELIGIBLE
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.call_map[(reactive, "getLatestCallback(bytes32)", config["reactive_rpc"])] = "(1, 1, 0x11223344, 1, 2)"
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][0]["topics"] = [
            CALLBACK_RETRY_REQUESTED_TOPIC,
            pos_id,
            "0x0000000000000000000000000000000000000000000000000000000000000001",
        ]
        rep_retried = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_retried["status"], RecoveryStatus.RETRY_ELIGIBLE.value)

        # Case B: Deferred RESOLVED (eventType=2, origin_breached=false) -> DISPATCH_REQUIRED
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.call_map[(origin, "isPositionBreached(bytes32)", config["base_rpc"])] = "false"
        runner.call_map[(reactive, "getLatestCallback(bytes32)", config["reactive_rpc"])] = "(1, 2, 0x55667788, 0, 1)"
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])] = {
            "status": "0x1",
            "logs": [{
                "address": reactive,
                "topics": [
                    CALLBACK_DISPATCH_DEFERRED_TOPIC,
                    pos_id,
                    "0x0000000000000000000000000000000000000000000000000000000000000001",
                    "0x0000000000000000000000000000000000000000000000000000000000000002",
                ],
                "data": "0x",
            }],
        }
        runner.call_map[(sys_contract, sig, config["reactive_rpc"])] = "[]"
        rep_def_res = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_def_res["status"], RecoveryStatus.DISPATCH_REQUIRED.value)

        # Case C: CallbackDispatchSubmitted receipt -> valid CallbackRequest correlation -> RETRY_ELIGIBLE on failure
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])] = {
            "status": "0x1",
            "logs": [
                {
                    "address": reactive,
                    "topics": [
                        CALLBACK_DISPATCH_SUBMITTED_TOPIC,
                        pos_id,
                        "0x0000000000000000000000000000000000000000000000000000000000000001",
                        "0x0000000000000000000000000000000000000000000000000000000000000001",
                    ],
                    "data": "0x",
                },
                {
                    "address": sys_contract,
                    "topics": [
                        CALLBACK_REQUEST_TOPIC,
                        "0x0000000000000000000000000000000000000000000000000000000000000515",
                        "0x000000000000000000000000" + reactive[2:],
                        "0x000000000000000000000000" + cb_adapter[2:],
                    ],
                    "data": encode_callback_request_data(1301, cb_adapter, 300_000, "0x11223344"),
                },
            ],
        }
        rep_sub = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_sub["status"], RecoveryStatus.RETRY_ELIGIBLE.value)

    # 89. Newer Reactive nonce (even if origin unchanged) -> RETRY_SUPERSEDED & zero p_base -> UNKNOWN
    def test_89_newer_reactive_nonce_and_zero_gas_price_fail_closed(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        reactive = config["reactive_address"].lower()

        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.call_map[(reactive, "latestOriginNonce(bytes32)", config["reactive_rpc"])] = "2"
        rep_sup = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_sup["status"], RecoveryStatus.RETRY_SUPERSEDED.value)

        # Both gas price and base fee 0 -> fail-closed RETRY_UNKNOWN
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.gas_prices[config["unichain_rpc"]] = 0
        runner.base_fees[config["unichain_rpc"]] = 0
        rep_zero_p = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_zero_p["status"], RecoveryStatus.RETRY_UNKNOWN.value)

    # 90. CLI --recovery-preflight fails closed with exit code 1 when missing mandatory args
    def test_90_cli_missing_mandatory_args_exits_nonzero_with_unknown(self):
        import subprocess
        script_path = os.path.join(REPO_ROOT, "script", "ops", "crossguard_healthcheck.py")
        # Missing --expected-nonce and --reactive-tx-hash
        proc = subprocess.run(
            [sys.executable, script_path, "--recovery-preflight", "--position-id", self._get_test_position_id(), "--json"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(proc.returncode, 0)
        parsed = json.loads(proc.stdout)
        self.assertEqual(parsed["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("mandatory", parsed["reason"])

    # =========================================================================
    # M006.2 ADVERSARIAL TESTS — WORKSTREAM A (CONFIG DRIFT PROTECTION)
    # =========================================================================

    # 91. Workstream A: All 3 callback recipients match (including mixed uppercase/lowercase)
    def test_91_drift_all_three_match_and_case_insensitivity(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        # Supply mixed-case expected callback & uppercase reactive destinationCallback()
        config["callback_address"] = "0x333333333333333333333333333333333333AbCd"
        cb_norm = config["callback_address"].lower()
        reactive = config["reactive_address"].lower()
        borrow = config["borrowing_controller_address"].lower()
        sys_contract = config["system_contract"].lower()
        proxy = config["callback_proxy"].lower()

        # Re-populate wiring keys for mixed-case callback_address
        runner.code_map[(cb_norm, config["unichain_rpc"])] = "0x60806040"
        runner.call_map[(reactive, "destinationCallback()", config["reactive_rpc"])] = config["callback_address"].upper().replace("0X", "0x")
        runner.call_map[(borrow, "callbackAdapter()", config["unichain_rpc"])] = cb_norm
        runner.call_map[(cb_norm, "callbackProxy()", config["unichain_rpc"])] = proxy
        runner.call_map[(cb_norm, "authorizedReactiveSender()", config["unichain_rpc"])] = reactive
        runner.call_map[(cb_norm, "borrowingController()", config["unichain_rpc"])] = borrow
        runner.call_map[(proxy, "debt(address)", config["unichain_rpc"])] = "0"
        runner.call_map[(proxy, "reserves(address)", config["unichain_rpc"])] = str(10**18)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["topics"][3] = "0x" + "0" * 24 + cb_norm[2:]
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["data"] = encode_callback_request_data(
            1301, config["callback_address"], 300_000, "0x11223344"
        )

        rep = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_ELIGIBLE.value)
        self.assertTrue(rep["safe_to_consider_recovery"])
        self.assertTrue(rep["configuration_comparison"]["all_recipients_match"])
        self.assertFalse(rep["configuration_comparison"]["drift_detected"])
        self.assertEqual(rep["configuration_comparison"]["expected_callback"], cb_norm)

    # 92. Workstream A: Historical differs from expected (while current == expected) -> RETRY_UNKNOWN
    def test_92_drift_historical_differs_from_expected(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        other_cb = "0x7777777777777777777777777777777777777777"
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["topics"][3] = "0x" + "0" * 24 + other_cb[2:]
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["data"] = encode_callback_request_data(
            1301, other_cb, 300_000, "0x11223344"
        )
        rep = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertNotEqual(rep["status"], RecoveryStatus.RETRY_ELIGIBLE.value)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertTrue(rep["configuration_comparison"]["drift_detected"])
        self.assertFalse(rep["configuration_comparison"]["expected_matches_historical"])
        self.assertFalse(rep["safe_to_consider_recovery"])

    # 93. Workstream A: Current destinationCallback differs from expected (and drifted from historical too)
    def test_93_drift_current_differs_from_expected(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        reactive = config["reactive_address"].lower()
        drifted_cb = "0x7777777777777777777777777777777777777777"
        runner.call_map[(reactive, "destinationCallback()", config["reactive_rpc"])] = drifted_cb

        # Even when historical == current == drifted_cb while operator expects original cb, must block!
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["topics"][3] = "0x" + "0" * 24 + drifted_cb[2:]
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["data"] = encode_callback_request_data(
            1301, drifted_cb, 300_000, "0x11223344"
        )
        rep = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertFalse(rep["configuration_comparison"]["expected_matches_current"])
        self.assertFalse(rep["configuration_comparison"]["all_recipients_match"])
        self.assertIn("migration", rep["remediation"].lower())

    # 94. Workstream A (Critical P1): Historical matches expected, but current destinationCallback drifted between dispatch and retry
    def test_94_drift_between_initial_dispatch_and_later_recovery_blocks_retry(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        reactive = config["reactive_address"].lower()
        new_drifted_cb = "0x8888777766665555444433332222111100009999"

        # Historical CallbackRequest was sent to 0x3333... (expected), then owner changed destinationCallback to new_drifted_cb
        runner.call_map[(reactive, "destinationCallback()", config["reactive_rpc"])] = new_drifted_cb

        rep_orig = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_orig["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertTrue(rep_orig["configuration_comparison"]["expected_matches_historical"])
        self.assertFalse(rep_orig["configuration_comparison"]["expected_matches_current"])
        self.assertFalse(rep_orig["configuration_comparison"]["historical_matches_current"])
        self.assertIn("drift", rep_orig["reason"].lower())
        self.assertIn("migration", rep_orig["remediation"].lower())
        self.assertNotIn("RETRY_ELIGIBLE", rep_orig["status"])

        # Attempting to override CLI --callback-address to new_drifted_cb must STILL fail closed because historical != new_drifted_cb!
        override_cfg = dict(config, callback_address=new_drifted_cb)
        runner.code_map[(new_drifted_cb, config["unichain_rpc"])] = "0x60806040"
        borrow = config["borrowing_controller_address"].lower()
        runner.call_map[(borrow, "callbackAdapter()", config["unichain_rpc"])] = new_drifted_cb
        runner.call_map[(new_drifted_cb, "callbackProxy()", config["unichain_rpc"])] = config["callback_proxy"].lower()
        runner.call_map[(new_drifted_cb, "authorizedReactiveSender()", config["unichain_rpc"])] = reactive
        runner.call_map[(new_drifted_cb, "borrowingController()", config["unichain_rpc"])] = borrow
        runner.call_map[(config["callback_proxy"].lower(), "debt(address)", config["unichain_rpc"])] = "0"
        runner.call_map[(config["callback_proxy"].lower(), "reserves(address)", config["unichain_rpc"])] = str(10**18)

        rep_override = run_recovery_preflight(override_cfg, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertNotEqual(rep_override["status"], RecoveryStatus.RETRY_ELIGIBLE.value)
        self.assertEqual(rep_override["status"], RecoveryStatus.RETRY_UNKNOWN.value)

    # 95. Workstream A: Zero callback address & malformed/truncated addresses fail closed
    def test_95_drift_zero_and_malformed_truncated_addresses_fail_closed(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)

        # Truncated expected callback address
        bad_cfg = dict(config, callback_address="0x1234")
        rep_trunc = run_recovery_preflight(bad_cfg, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_trunc["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("20-byte EVM address", rep_trunc["reason"])

        # Zero expected callback address
        zero_cfg = dict(config, callback_address="0x" + "0" * 40)
        rep_zero = run_recovery_preflight(zero_cfg, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_zero["status"], RecoveryStatus.RETRY_BLOCKED.value)

        # Truncated current destinationCallback() from RPC -> RETRY_UNKNOWN
        runner.call_map[(config["reactive_address"].lower(), "destinationCallback()", config["reactive_rpc"])] = "0xdead"
        rep_rpc_trunc = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_rpc_trunc["status"], RecoveryStatus.RETRY_UNKNOWN.value)

        with self.assertRaises(ValueError):
            validate_evm_address("0x1234")

    # 96. Workstream A: DISPATCH_REQUIRED valid matching vs mismatched current destinationCallback
    def test_96_dispatch_required_current_callback_matching_and_mismatched(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        reactive = config["reactive_address"].lower()
        sys_contract = config["system_contract"].lower()

        runner.call_map[(reactive, "getLatestCallback(bytes32)", config["reactive_rpc"])] = "(1, 1, 0x11223344, 0, 1)"
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])] = {
            "status": "0x1",
            "logs": [{
                "address": reactive,
                "topics": [
                    CALLBACK_DISPATCH_DEFERRED_TOPIC,
                    pos_id,
                    "0x0000000000000000000000000000000000000000000000000000000000000001",
                    "0x0000000000000000000000000000000000000000000000000000000000000001",
                ],
                "data": "0x",
            }],
        }
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        runner.call_map[(sys_contract, sig, config["reactive_rpc"])] = "[]"

        # Valid matching current callback -> DISPATCH_REQUIRED
        rep_ok = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_ok["status"], RecoveryStatus.DISPATCH_REQUIRED.value)
        self.assertTrue(rep_ok["configuration_comparison"]["all_recipients_match"])
        self.assertIsNone(rep_ok["configuration_comparison"]["historical_callback_request_recipient"])

        # Mismatched current destinationCallback -> RETRY_BLOCKED (must not approve dispatch!)
        runner.call_map[(reactive, "destinationCallback()", config["reactive_rpc"])] = "0x9999888877776666555544443333222211110000"
        rep_mismatch = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep_mismatch["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertFalse(rep_mismatch["configuration_comparison"]["expected_matches_current"])
        self.assertIn("migration", rep_mismatch["remediation"].lower())

    # =========================================================================
    # M006.2 ADVERSARIAL TESTS — WORKSTREAM B (FEE & MAX-CHARGE MODEL)
    # =========================================================================

    # 97. Workstream B: p_base selection (gas_price > base_fee and base_fee > gas_price) & _maxChargeGas fee independence
    def test_97_fee_pbase_and_max_charge_gas_independence(self):
        # Verify _maxChargeGas never changes estimated fee
        e1 = estimate_callback_fee_wei(300_000, 1_500_000_000, 1000, 50_000, max_charge_gas=10_000, safety_multiplier=2)
        e2 = estimate_callback_fee_wei(300_000, 1_500_000_000, 1000, 50_000, max_charge_gas=5_000_000, safety_multiplier=2)
        self.assertEqual(e1["estimated_single_callback_fee_wei"], e2["estimated_single_callback_fee_wei"])
        self.assertEqual(e1["recommended_min_reserve_wei"], e2["recommended_min_reserve_wei"])

        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        # gas_price > base_fee
        r1 = self._setup_preflight_runner(config, pos_id, tx_hash)
        r1.gas_prices[config["unichain_rpc"]] = 3_000_000_000
        r1.base_fees[config["unichain_rpc"]] = 1_000_000_000
        rep1 = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=r1)
        self.assertEqual(rep1["economics"]["fee_parameters"]["callback_proxy_p_base_wei"], 3_000_000_000)

        # base_fee > gas_price
        r2 = self._setup_preflight_runner(config, pos_id, tx_hash)
        r2.gas_prices[config["unichain_rpc"]] = 1_000_000_000
        r2.base_fees[config["unichain_rpc"]] = 4_000_000_000
        rep2 = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=r2)
        self.assertEqual(rep2["economics"]["fee_parameters"]["callback_proxy_p_base_wei"], 4_000_000_000)

    # 98. Workstream B: _maxChargeGas below, equal, above settlement requirement + zero/missing _maxChargeGas
    def test_98_max_charge_gas_settlement_boundaries_and_missing(self):
        below = estimate_callback_fee_wei(300_000, 2_000_000_000, 1000, 50_000, max_charge_gas=49_999, settlement_gas_requirement=50_000)
        eq = estimate_callback_fee_wei(300_000, 2_000_000_000, 1000, 50_000, max_charge_gas=50_000, settlement_gas_requirement=50_000)
        above = estimate_callback_fee_wei(300_000, 2_000_000_000, 1000, 50_000, max_charge_gas=50_001, settlement_gas_requirement=50_000)
        self.assertFalse(below["settlement_gas_sufficient"])
        self.assertEqual(below["settlement_gas_status"], "BELOW_REQUIREMENT")
        self.assertTrue(eq["settlement_gas_sufficient"])
        self.assertEqual(eq["settlement_gas_status"], "AT_REQUIREMENT")
        self.assertTrue(above["settlement_gas_sufficient"])
        self.assertEqual(above["settlement_gas_status"], "ABOVE_REQUIREMENT")

        with self.assertRaises(ValueError):
            estimate_callback_fee_wei(300_000, 2_000_000_000, 1000, 50_000, max_charge_gas=None)

        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        proxy = config["callback_proxy"].lower()

        # Zero _maxChargeGas on Callback Proxy -> RETRY_BLOCKED
        r_zero = self._setup_preflight_runner(config, pos_id, tx_hash)
        r_zero.call_map[(proxy, "_maxChargeGas()", config["unichain_rpc"])] = "0"
        rep_zero = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=r_zero)
        self.assertEqual(rep_zero["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("_maxChargeGas", rep_zero["reason"])

        # Below configured settlement_gas_requirement -> RETRY_BLOCKED; equal -> RETRY_ELIGIBLE
        r_req = self._setup_preflight_runner(config, pos_id, tx_hash)
        r_req.call_map[(proxy, "_maxChargeGas()", config["unichain_rpc"])] = "50000"
        rep_b = run_recovery_preflight(dict(config, settlement_gas_requirement=60_000), pos_id, 1, tx_hash, runner=r_req)
        self.assertEqual(rep_b["status"], RecoveryStatus.RETRY_BLOCKED.value)
        rep_e = run_recovery_preflight(dict(config, settlement_gas_requirement=50_000), pos_id, 1, tx_hash, runner=r_req)
        self.assertEqual(rep_e["status"], RecoveryStatus.RETRY_ELIGIBLE.value)

    # 99. Workstream B: Zero/missing coefficient, invalid extraGas, arithmetic overflow & invalid types
    def test_99_fee_invalid_inputs_and_uint256_overflow(self):
        # Zero coeff
        with self.assertRaises(ValueError):
            estimate_callback_fee_wei(300_000, 1_000_000_000, 0, 50_000, 50_000)
        # Negative extraGas / invalid types / bool
        with self.assertRaises(ValueError):
            estimate_callback_fee_wei(300_000, 1_000_000_000, 1000, -1, 50_000)
        with self.assertRaises(ValueError):
            estimate_callback_fee_wei(True, 1_000_000_000, 1000, 50_000, 50_000)
        # Arithmetic overflow > uint256
        with self.assertRaises(ValueError):
            estimate_callback_fee_wei(2**255, 2**200, 1000, 50_000, 50_000)

        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        proxy = config["callback_proxy"].lower()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.call_map[(proxy, "_gasPriceCoeffPer1000()", config["unichain_rpc"])] = "0"
        rep = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_UNKNOWN.value)

    # 100. Workstream B: Configured gas limit vs unverified effective forwarded gas disclosure
    def test_100_configured_gas_vs_effective_forwarded_gas(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        rep = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertIsNone(rep["reactive_state"]["effective_forwarded_gas_exact"])
        self.assertIn("strictly less than configured", rep["economics"]["reserve_estimates"]["callback_proxy_estimate"]["assumptions"][4])
        self.assertTrue(any("NOT exact forwarded destination gas" in u for u in rep["unsafe_or_unverified_conditions"]))
        term = format_recovery_preflight_terminal(rep)
        self.assertIn("CALLBACK ADDRESS DRIFT CHECK:", term)
        self.assertIn("WARNINGS & UNSAFE / UNVERIFIED CONDITIONS:", term)

    # =========================================================================
    # M006.2 ADVERSARIAL TESTS — WORKSTREAM C (CALLBACKREQUEST ABI VALIDATION)
    # =========================================================================

    # 101. Workstream C: Valid modern event mixed with unrelated logs succeeds
    def test_101_callback_request_mixed_unrelated_logs(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        # Insert unrelated Transfer-like event logs before & after
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"].insert(0, {
            "address": "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            "topics": ["0x" + "12" * 32],
            "data": "0x1234",
        })
        rep = run_recovery_preflight(config, position_id=pos_id, expected_nonce=1, reactive_tx_hash=tx_hash, runner=runner)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_ELIGIBLE.value)
        self.assertEqual(rep["receipt_evidence"]["callback_request_decoded"]["version"], 0)
        self.assertEqual(rep["receipt_evidence"]["callback_request_decoded"]["gas_limit"], 300_000)

    # 102. Workstream C: Unsupported version, invalid config bytes, missing data & legacy CallbackRequestedV1 rejected
    def test_102_callback_request_version_config_missing_data_and_legacy_v1(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        cb_adapter = config["callback_address"].lower()
        sys_contract = config["system_contract"].lower()
        reactive = config["reactive_address"].lower()

        # Unsupported version = 1
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["data"] = encode_callback_request_data(
            1301, cb_adapter, 300_000, "0x11223344", version=1
        )
        rep_ver = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
        self.assertEqual(rep_ver["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("Unsupported CallbackVersion", rep_ver["reason"])

        # Missing event data "0x"
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["data"] = "0x"
        rep_empty = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
        self.assertEqual(rep_empty["status"], RecoveryStatus.RETRY_UNKNOWN.value)

        # Invalid/corrupted configuration bytes
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["data"] = "0x" + "00" * 96
        rep_cfg = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
        self.assertEqual(rep_cfg["status"], RecoveryStatus.RETRY_UNKNOWN.value)

        # Configuration payload mismatch vs latestCallback stored payload
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["data"] = encode_callback_request_data(
            1301, cb_adapter, 300_000, "0xdeadbeef"
        )
        rep_pay = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
        self.assertEqual(rep_pay["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("payload", rep_pay["reason"].lower())

        # Sub-100k gasLimit inside CallbackConfiguration -> RETRY_BLOCKED
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["data"] = encode_callback_request_data(
            1301, cb_adapter, 99_999, "0x11223344"
        )
        rep_gas = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
        self.assertEqual(rep_gas["status"], RecoveryStatus.RETRY_BLOCKED.value)

        # Legacy CallbackRequestedV1 signature rejected fail-closed
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1] = {
            "address": sys_contract,
            "topics": [UNSUPPORTED_LEGACY_CALLBACK_REQUESTED_V1_TOPIC, "0x" + "0" * 60 + "0515", "0x" + "0" * 24 + cb_adapter[2:]],
            "data": "0x" + "00" * 64,
        }
        rep_leg = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
        self.assertEqual(rep_leg["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("CallbackRequestedV1", rep_leg["reason"])

        # Unrecognized event signature in System Contract (only random topic) -> RETRY_UNKNOWN
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["topics"][0] = "0x" + "ab" * 32
        rep_unrec = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
        self.assertEqual(rep_unrec["status"], RecoveryStatus.RETRY_UNKNOWN.value)

        # Wrong sender in CallbackRequest -> RETRY_UNKNOWN
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["topics"][2] = "0x" + "0" * 24 + "99" * 20
        rep_snd = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
        self.assertEqual(rep_snd["status"], RecoveryStatus.RETRY_UNKNOWN.value)

        # Suppress unused variable lint
        self.assertTrue(len(reactive) == 42)

    # =========================================================================
    # M006.2 ADVERSARIAL TESTS — WORKSTREAM D (CALLBACK RECORDS CORRELATION)
    # =========================================================================

    # 103. Workstream D: Strict formatted record validation & correlation diagnostics
    def test_103_callback_records_strict_validation_and_correlation_metadata(self):
        # Truncated reactiveContract address in tuple must return error (no silent zfill!)
        recs, err = decode_callback_records("[(100, 0x1234, 1, 1301, 8888, 0x08c379a0)]")
        self.assertIsNone(recs)
        self.assertIsNotNone(err)

        # Negative field or trailing garbage tokens must return error
        recs2, err2 = decode_callback_records("[(100, 0x2222222222222222222222222222222222222222, -1, 1301, 8888, 0x)]")
        self.assertIsNone(recs2)
        self.assertIsNotNone(err2)
        recs3, err3 = decode_callback_records("[(100, 0x2222222222222222222222222222222222222222, 1, 1301, 8888, 0x)] junk")
        self.assertIsNone(recs3)
        self.assertIsNotNone(err3)

        # Verify correlation metadata in preflight output
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        rep = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
        corr = rep["callback_record_correlation"]
        self.assertTrue(corr["unambiguous_match"])
        self.assertEqual(corr["matched_records"], 1)
        self.assertEqual(rep["callback_record"]["callback_index"], 1)
        self.assertEqual(rep["callback_record"]["block_number"], 100)

    # 104. Workstream C & D: Strict CallbackRequest ABI roundtrip & non-exact topics rejection
    def test_104_callback_request_roundtrip_and_topic_count_check(self):
        encoded = encode_callback_request_data(1301, "0x3333333333333333333333333333333333333333", 300_000, "0x11223344")
        decoded = decode_callback_request_data_strict(encoded)
        self.assertEqual(decoded["version"], 0)
        self.assertEqual(decoded["chain_id"], 1301)
        self.assertEqual(decoded["recipient"], "0x3333333333333333333333333333333333333333")
        self.assertEqual(decoded["gas_limit"], 300_000)
        self.assertEqual(decoded["payload"], "0x11223344")

        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["topics"].pop()
        rep = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertIn("exactly 4 topics", rep["reason"])

    # =========================================================================
    # M006.2.1 ADVERSARIAL TESTS — CANONICAL ABI & CALLBACK RECORD BOUNDARIES
    # =========================================================================

    def _build_canonical_raw_callback_request_bytes(self, payload_hex: str = "0x11223344", gas_limit: int = 300_000) -> bytearray:
        cb_adapter = "0x3333333333333333333333333333333333333333"
        encoded = encode_callback_request_data(1301, cb_adapter, gas_limit, payload_hex)
        return bytearray(bytes.fromhex(encoded[2:]))

    def _assert_malformed_callback_request_data(self, raw_data_hex: str, label: str, expected_substr: Optional[str] = None) -> None:
        with self.subTest(case=label):
            with self.assertRaises(ValueError) as ctx:
                decode_callback_request_data_strict(raw_data_hex)
            if expected_substr:
                self.assertIn(expected_substr.lower(), str(ctx.exception).lower())

            config = create_base_config()
            pos_id = self._get_test_position_id()
            tx_hash = self._get_test_tx_hash()
            runner = self._setup_preflight_runner(config, pos_id, tx_hash)
            runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["data"] = raw_data_hex
            rep = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
            self.assertEqual(rep["status"], RecoveryStatus.RETRY_UNKNOWN.value, f"Preflight must fail closed on {label}")
            self.assertFalse(rep["safe_to_consider_recovery"], f"safe_to_consider_recovery must be False on {label}")

    # 105. Canonical V1.0 Solidity fixture parity & payload boundary lengths (31, 32, 33, 63, 64, 65 bytes)
    def test_105_canonical_callback_request_solidity_parity_and_boundary_lengths(self):
        # Exact Solidity `cast abi-encode` vector for:
        #   abi.encode(uint8(0), abi.encode(CallbackConfiguration_V_1_0(1301, 0x3333..., 300000, 0x11223344)))
        solidity_cast_hex = (
            "0x"
            + "00" * 31 + "00"
            + "00" * 31 + "40"
            + "00" * 30 + "00e0"
            + "00" * 31 + "20"
            + "00" * 30 + "0515"
            + "00" * 12 + "33" * 20
            + "00" * 29 + "0493e0"
            + "00" * 31 + "80"
            + "00" * 31 + "04"
            + "11223344" + "00" * 28
        )
        py_encoded = encode_callback_request_data(
            1301, "0x3333333333333333333333333333333333333333", 300_000, "0x11223344"
        )
        self.assertEqual(py_encoded, solidity_cast_hex)
        decoded_solidity = decode_callback_request_data_strict(solidity_cast_hex)
        self.assertEqual(decoded_solidity["payload"], "0x11223344")

        for length in (1, 4, 31, 32, 33, 63, 64, 65):
            with self.subTest(payload_bytes=length):
                payload_hex = "0x" + "".join(f"{(i * 17 + 3) % 256:02x}" for i in range(length))
                encoded = encode_callback_request_data(
                    1301, "0x3333333333333333333333333333333333333333", 300_000, payload_hex
                )
                decoded = decode_callback_request_data_strict(encoded)
                self.assertEqual(decoded["version"], 0)
                self.assertEqual(decoded["chain_id"], 1301)
                self.assertEqual(decoded["recipient"], "0x3333333333333333333333333333333333333333")
                self.assertEqual(decoded["gas_limit"], 300_000)
                self.assertEqual(decoded["payload"], payload_hex)

                # Confirm preflight accepts every valid boundary payload length cleanly
                config = create_base_config()
                pos_id = self._get_test_position_id()
                tx_hash = self._get_test_tx_hash()
                runner = self._setup_preflight_runner(config, pos_id, tx_hash)
                reactive = config["reactive_address"].lower()
                runner.call_map[(reactive, "getLatestCallback(bytes32)", config["reactive_rpc"])] = (
                    f"(1, 1, {payload_hex}, 0, 2)"
                )
                runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["data"] = encoded
                rep = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
                self.assertEqual(rep["status"], RecoveryStatus.RETRY_ELIGIBLE.value)
                self.assertTrue(rep["safe_to_consider_recovery"])

    # 106. Padding & trailing-byte attacks on outer CallbackRequest.data and inner CallbackConfiguration
    def test_106_callback_request_padding_and_trailing_byte_attacks(self):
        # A. Non-zero outer dynamic-byte padding (unaligned cfg_len=225 with 31-byte tail, dirty byte 0xff)
        base = self._build_canonical_raw_callback_request_bytes("0x11223344")
        outer_dirty = bytearray(base)
        outer_dirty[64:96] = (225).to_bytes(32, "big")
        outer_dirty.extend(b"\x00" + b"\xff" + b"\x00" * 30)
        self._assert_malformed_callback_request_data(
            "0x" + outer_dirty.hex(), "non_zero_outer_padding", "Non-zero outer dynamic-byte padding"
        )

        # B. Truncated outer padding (cfg_len=225, outer ends at 321 bytes instead of padded 352)
        outer_trunc = bytearray(base)
        outer_trunc[64:96] = (225).to_bytes(32, "big")
        outer_trunc.extend(b"\xaa")
        self._assert_malformed_callback_request_data(
            "0x" + outer_trunc.hex(), "truncated_outer_padding", "Truncated outer dynamic-byte padding"
        )

        # C. Non-zero inner payload padding (4-byte payload 0x11223344, flip byte at offset 196 within cfg -> byte 292 outer)
        inner_dirty = bytearray(base)
        inner_dirty[96 + 196] = 0x01
        self._assert_malformed_callback_request_data(
            "0x" + inner_dirty.hex(), "non_zero_inner_payload_padding", "Non-zero inner payload dynamic-byte padding"
        )
        # Also flip the very last byte of 31-byte payload padding (length 31 -> 1 padding byte at 192+31=223 -> outer 319)
        base_31 = self._build_canonical_raw_callback_request_bytes("0x" + "aa" * 31)
        inner_dirty_31 = bytearray(base_31)
        inner_dirty_31[-1] = 0x80
        self._assert_malformed_callback_request_data(
            "0x" + inner_dirty_31.hex(), "non_zero_inner_padding_len31", "Non-zero inner payload dynamic-byte padding"
        )

        # D. Truncated inner padding (cfg_len=223 for 4-byte payload needing 224 inner bytes, padded with 1 zero byte outer)
        inner_trunc = bytearray(base)
        inner_trunc[64:96] = (223).to_bytes(32, "big")
        self._assert_malformed_callback_request_data(
            "0x" + inner_trunc.hex(), "truncated_inner_padding", "Truncated inner payload dynamic-byte padding"
        )

        # E. Trailing bytes after complete outer encoding (+1 byte and +32 zero bytes)
        self._assert_malformed_callback_request_data(
            "0x" + (base + b"\xaa").hex(), "trailing_1_byte_outer", "Unexpected trailing bytes in CallbackRequest.data"
        )
        self._assert_malformed_callback_request_data(
            "0x" + (base + b"\x00" * 32).hex(), "trailing_32_zero_bytes_outer", "Unexpected trailing bytes in CallbackRequest.data"
        )

        # F. Trailing bytes inside encoded configuration (cfg_len=256 with extra 32 zero bytes, and unaligned cfg_len=225)
        trailing_inner_word = bytearray(base[:64] + (256).to_bytes(32, "big") + base[96:] + b"\x00" * 32)
        self._assert_malformed_callback_request_data(
            "0x" + trailing_inner_word.hex(), "trailing_32_bytes_inside_config", "Unexpected trailing bytes inside CallbackConfiguration_V_1_0"
        )
        trailing_inner_unaligned = bytearray(base[:64] + (225).to_bytes(32, "big") + base[96:] + b"\x00" * 32)
        self._assert_malformed_callback_request_data(
            "0x" + trailing_inner_unaligned.hex(), "trailing_1_byte_inside_config_zero_padded", "Unexpected trailing bytes inside CallbackConfiguration_V_1_0"
        )

    # 107. Non-canonical offsets, head pointers, and overlapping/aliased dynamic regions
    def test_107_callback_request_non_canonical_offsets_and_aliasing(self):
        base = self._build_canonical_raw_callback_request_bytes("0x11223344")
        cfg_bytes = base[96:]

        # A. Non-canonical outer configuration offset (96 with 32-byte zero gap)
        gapped_outer = base[0:32] + (96).to_bytes(32, "big") + b"\x00" * 32 + base[64:]
        self._assert_malformed_callback_request_data(
            "0x" + gapped_outer.hex(), "non_canonical_outer_offset_96", "Non-canonical configuration bytes offset 96"
        )

        # B. Outer configuration offset pointing into outer head / overlapping (0 and 32)
        for bad_outer_off in (0, 32):
            alias_outer = bytearray(base)
            alias_outer[32:64] = bad_outer_off.to_bytes(32, "big")
            self._assert_malformed_callback_request_data(
                "0x" + alias_outer.hex(), f"outer_offset_into_head_{bad_outer_off}", "points into outer head"
            )

        # C. Non-canonical inner tuple offset (0 = self-alias, 64 = gap)
        alias_tuple = bytearray(base)
        alias_tuple[96:128] = (0).to_bytes(32, "big")
        self._assert_malformed_callback_request_data(
            "0x" + alias_tuple.hex(), "inner_tuple_offset_0_alias", "Non-canonical outer tuple offset"
        )
        gapped_tuple_cfg = (64).to_bytes(32, "big") + b"\x00" * 32 + cfg_bytes[32:]
        gapped_tuple_outer = base[0:32] + (64).to_bytes(32, "big") + len(gapped_tuple_cfg).to_bytes(32, "big") + gapped_tuple_cfg
        self._assert_malformed_callback_request_data(
            "0x" + gapped_tuple_outer.hex(), "inner_tuple_offset_64_gap", "Non-canonical outer tuple offset"
        )

        # D. Non-canonical payload offset (160 with 32-byte zero gap before payload length)
        gapped_payload_cfg = cfg_bytes[:128] + (160).to_bytes(32, "big") + b"\x00" * 32 + cfg_bytes[160:]
        gapped_payload_outer = base[0:32] + (64).to_bytes(32, "big") + len(gapped_payload_cfg).to_bytes(32, "big") + gapped_payload_cfg
        self._assert_malformed_callback_request_data(
            "0x" + gapped_payload_outer.hex(), "non_canonical_payload_offset_160", "Non-canonical payload offset (160)"
        )

        # E. Payload offset pointing into tuple head / aliased header slots (0, 32, 64, 96)
        for bad_pay_off in (0, 32, 64, 96):
            alias_pay = bytearray(base)
            alias_pay[96 + 128 : 96 + 160] = bad_pay_off.to_bytes(32, "big")
            self._assert_malformed_callback_request_data(
                "0x" + alias_pay.hex(), f"payload_offset_into_head_{bad_pay_off}", "points into tuple head"
            )

    # 108. Bounds & field validation: version dirty upper bits, dirty address bits, gasLimit > uint64, empty payload, uint256 boundaries
    def test_108_callback_request_bounds_upper_bits_empty_payload_and_extremes(self):
        base = self._build_canonical_raw_callback_request_bytes("0x11223344")

        # A. Dirty upper bits in version word (low byte still 0)
        dirty_ver = bytearray(base)
        dirty_ver[0] = 0x01
        self._assert_malformed_callback_request_data("0x" + dirty_ver.hex(), "dirty_version_upper_bits", "Dirty upper bits")

        # B. Invalid version enum (1 and 255)
        for bad_ver in (1, 255):
            inv_ver = bytearray(base)
            inv_ver[31] = bad_ver
            self._assert_malformed_callback_request_data("0x" + inv_ver.hex(), f"unsupported_version_{bad_ver}", "Unsupported CallbackVersion")

        # C. Dirty upper 12 bytes in CallbackConfiguration.recipient
        dirty_addr = bytearray(base)
        dirty_addr[96 + 64] = 0x01
        self._assert_malformed_callback_request_data("0x" + dirty_addr.hex(), "dirty_config_recipient_upper_bits", "Dirty upper bits")

        # D. gasLimit overflows uint64 (2**64 and dirty MSB)
        for bad_gas in (2**64, 2**255):
            overflow_gas = bytearray(base)
            overflow_gas[96 + 96 : 96 + 128] = bad_gas.to_bytes(32, "big")
            self._assert_malformed_callback_request_data("0x" + overflow_gas.hex(), f"gas_limit_overflow_{bad_gas}", "overflows uint64")

        # E. Empty payload (payload_len = 0, padded 0 bytes)
        empty_cfg = base[96:96 + 160] + (0).to_bytes(32, "big")
        empty_pay_outer = base[0:32] + (64).to_bytes(32, "big") + len(empty_cfg).to_bytes(32, "big") + empty_cfg
        self._assert_malformed_callback_request_data("0x" + empty_pay_outer.hex(), "empty_payload", "empty payload")

        # F. Huge uint256 boundary lengths & offsets (must fail cleanly without OOM/hang)
        for field_name, byte_slice, huge_val in [
            ("huge_cfg_offset_max_uint256", (32, 64), 2**256 - 1),
            ("huge_cfg_len_max_uint256", (64, 96), 2**256 - 1),
            ("huge_cfg_len_2_64", (64, 96), 2**64),
            ("huge_tuple_offset_max_uint256", (96, 128), 2**256 - 1),
            ("huge_payload_offset_max_uint256", (96 + 128, 96 + 160), 2**256 - 1),
            ("huge_payload_len_max_uint256", (96 + 160, 96 + 192), 2**256 - 1),
            ("huge_payload_len_2_64", (96 + 160, 96 + 192), 2**64),
        ]:
            huge_buf = bytearray(base)
            huge_buf[byte_slice[0] : byte_slice[1]] = huge_val.to_bytes(32, "big")
            self._assert_malformed_callback_request_data("0x" + huge_buf.hex(), field_name)

        # G. Dirty upper bits in indexed CallbackRequest topics[3] (recipient) & short topics[1]
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.receipts[(tx_hash.lower(), config["reactive_rpc"])]["logs"][1]["topics"][3] = (
            "0x10" + "0" * 22 + config["callback_address"][2:].lower()
        )
        rep = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertFalse(rep["safe_to_consider_recovery"])

    # 109. Parameterized adversarial property sweep across payload lengths 1..70 (mutations fail closed)
    def test_109_parameterized_abi_mutation_sweep(self):
        for plen in (1, 15, 31, 32, 33, 48, 63, 64, 65, 70):
            payload_hex = "0x" + "".join(f"{(i + plen) % 256:02x}" for i in range(plen))
            encoded_hex = encode_callback_request_data(
                1301, "0x3333333333333333333333333333333333333333", 300_000, payload_hex
            )
            raw = bytes.fromhex(encoded_hex[2:])
            self.assertEqual(len(raw) % 32, 0)

            # Truncation mutation (-1 and -32 bytes)
            with self.assertRaises(ValueError):
                decode_callback_request_data_strict("0x" + raw[:-1].hex())
            with self.assertRaises(ValueError):
                decode_callback_request_data_strict("0x" + raw[:-32].hex())

            # Extension mutation (+1 and +32 bytes)
            with self.assertRaises(ValueError):
                decode_callback_request_data_strict("0x" + (raw + b"\x00").hex())
            with self.assertRaises(ValueError):
                decode_callback_request_data_strict("0x" + (raw + b"\x00" * 32).hex())

            # Non-zero padding mutation whenever payload length is not a multiple of 32
            pad_len = (32 - (plen % 32)) % 32
            if pad_len > 0:
                mutated = bytearray(raw)
                mutated[-1] ^= 0x01
                with self.assertRaises(ValueError):
                    decode_callback_request_data_strict("0x" + mutated.hex())

    # 110. Workstream C Regression: Uncovered raw-ABI boundary defects in decode_callback_records()
    def test_110_callback_records_raw_abi_boundary_defects(self):
        dest_tx = 0x1111111111111111111111111111111111111111111111111111111111111111
        valid_hex = encode_abi_callback_array([
            (100, "0x2222222222222222222222222222222222222222", 1, 1301, dest_tx, "0x08c379a0")
        ])
        valid_bytes = bytes.fromhex(valid_hex[2:])

        bad_cases = [
            # 1. Zero array offset + zero length word must NOT falsely return [] (empty array)
            ("zero_arr_offset_empty", "0x" + ("00" * 64)),
            # 2. Empty array offset 32, len 0 with trailing 32 junk bytes must NOT return []
            ("empty_arr_trailing_bytes", "0x" + (32).to_bytes(32, "big").hex() + ("00" * 32) + ("aa" * 32)),
            # 3. Element offset pointing back into element offset array (0 < arr_len * 32)
            ("elem_offset_into_head", "0x" + (valid_bytes[:64] + (0).to_bytes(32, "big") + valid_bytes[96:]).hex()),
            # 4. bytes_offset aliasing tuple header slot (0 -> reads blockNumber as bytes_len; 128 -> reads destTxHash/offset!)
            ("bytes_offset_0_alias", "0x" + (valid_bytes[:96 + 160] + (0).to_bytes(32, "big") + valid_bytes[96 + 192:]).hex()),
            ("bytes_offset_128_alias", "0x" + (valid_bytes[:96 + 160] + (128).to_bytes(32, "big") + valid_bytes[96 + 192:]).hex()),
            # 5. Non-zero error bytes padding (flip last padding byte of 4-byte error 0x08c379a0)
            ("dirty_error_padding", "0x" + (valid_bytes[:-1] + b"\xff").hex()),
            # 6. Truncated error padding (-1 byte)
            ("truncated_error_padding", "0x" + valid_bytes[:-1].hex()),
            # 7. Trailing bytes after valid array (+32 zero bytes)
            ("trailing_bytes_after_array", "0x" + (valid_bytes + b"\x00" * 32).hex()),
            # 8. Huge arr_len overflow (2**256 - 1)
            ("huge_arr_len", "0x" + (valid_bytes[:32] + (2**256 - 1).to_bytes(32, "big") + valid_bytes[64:]).hex()),
            # 9. Dirty upper bits in raw ABI reactiveContract address slot
            ("dirty_raw_reactive_contract_upper", "0x" + (valid_bytes[:96 + 32] + b"\x01" + valid_bytes[96 + 33:]).hex()),
        ]

        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        sys_contract = config["system_contract"].lower()
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"

        for label, bad_raw in bad_cases:
            with self.subTest(case=label):
                recs, err = decode_callback_records(bad_raw)
                self.assertIsNone(recs, f"{label} must fail decoding")
                self.assertIsNotNone(err, f"{label} must return explicit error message")

                runner = self._setup_preflight_runner(config, pos_id, tx_hash)
                runner.call_map[(sys_contract, sig, config["reactive_rpc"])] = bad_raw
                rep = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
                self.assertEqual(rep["status"], RecoveryStatus.RETRY_UNKNOWN.value)
                self.assertFalse(rep["safe_to_consider_recovery"])

        # Also verify multi-record ambiguity & zero-tx with empty error remain safe under valid canonical raw ABI
        two_matching_hex = encode_abi_callback_array([
            (100, config["reactive_address"], 1, 1301, 8888, "0x08c379a0"),
            (101, config["reactive_address"], 2, 1301, 8889, "0x08c379a0"),
        ])
        recs_two, err_two = decode_callback_records(two_matching_hex)
        self.assertIsNone(err_two)
        self.assertEqual(len(recs_two), 2)
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        runner.call_map[(sys_contract, sig, config["reactive_rpc"])] = two_matching_hex
        rep_ambig = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
        self.assertEqual(rep_ambig["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertFalse(rep_ambig["safe_to_consider_recovery"])

    # 111. M007.1: Missing, zero, or truncated origin_collateral_vault must fail closed
    def test_111_m007_missing_or_zero_origin_collateral_vault_fails_closed(self):
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()

        # Missing in healthcheck
        config_missing = create_base_config()
        runner = populate_healthy_runner(config_missing)
        del config_missing["origin_collateral_vault"]
        report = CrossGuardHealthChecker(config_missing, runner=runner).run_all_checks()
        self.assertEqual(report["overall_status"], OverallStatus.CRITICAL.value)
        chk = next(c for c in report["checks"] if c["name"] == "config_origin_collateral_vault_present")
        self.assertEqual(chk["status"], Status.CRITICAL.value)

        # Missing in preflight -> RETRY_UNKNOWN
        runner_pf = self._setup_preflight_runner(create_base_config(), pos_id, tx_hash)
        rep_missing = run_recovery_preflight(config_missing, pos_id, 1, tx_hash, runner=runner_pf)
        self.assertEqual(rep_missing["status"], RecoveryStatus.RETRY_UNKNOWN.value)
        self.assertFalse(rep_missing["safe_to_consider_recovery"])

        # Zero address in preflight -> RETRY_BLOCKED
        config_zero = create_base_config()
        config_zero["origin_collateral_vault"] = "0x0000000000000000000000000000000000000000"
        rep_zero = run_recovery_preflight(config_zero, pos_id, 1, tx_hash, runner=runner_pf)
        self.assertEqual(rep_zero["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertFalse(rep_zero["safe_to_consider_recovery"])

        # Truncated address in preflight -> RETRY_UNKNOWN
        config_trunc = create_base_config()
        config_trunc["origin_collateral_vault"] = "0x5555"
        rep_trunc = run_recovery_preflight(config_trunc, pos_id, 1, tx_hash, runner=runner_pf)
        self.assertEqual(rep_trunc["status"], RecoveryStatus.RETRY_UNKNOWN.value)

    # 112. M007.1: CrossGuardReactive.originCollateralVault() mismatch fails closed
    def test_112_m007_reactive_origin_vault_mismatch_fails_closed(self):
        config = create_base_config()
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()
        runner = self._setup_preflight_runner(config, pos_id, tx_hash)
        reactive = config["reactive_address"].lower()
        runner.call_map[(reactive, "originCollateralVault()", config["reactive_rpc"])] = (
            "0x9999999999999999999999999999999999999999"
        )

        report = CrossGuardHealthChecker(config, runner=runner).run_all_checks()
        self.assertEqual(report["overall_status"], OverallStatus.CRITICAL.value)
        chk = next(c for c in report["checks"] if c["name"] == "config_reactive_origin_collateral_vault")
        self.assertEqual(chk["status"], Status.CRITICAL.value)

        rep = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
        self.assertEqual(rep["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("originCollateralVault", rep["reason"])
        self.assertFalse(rep["safe_to_consider_recovery"])

    # 113. M007.1: BorrowingController trustedOrigin domain mismatches fail closed
    def test_113_m007_borrowing_controller_trusted_origin_domain_mismatch_fails_closed(self):
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()

        cases = [
            ("trustedOriginChainId()", "1", "config_controller_trusted_origin_chain_id", "trustedOriginChainId"),
            (
                "trustedOriginRiskController()",
                "0x9999999999999999999999999999999999999999",
                "config_controller_trusted_origin_risk_controller",
                "trustedOriginRiskController",
            ),
            (
                "trustedOriginVault()",
                "0x9999999999999999999999999999999999999999",
                "config_controller_trusted_origin_vault",
                "trustedOriginVault",
            ),
        ]

        for sig, bad_val, chk_name, reason_frag in cases:
            with self.subTest(sig=sig):
                config = create_base_config()
                runner = self._setup_preflight_runner(config, pos_id, tx_hash)
                borrow = config["borrowing_controller_address"].lower()
                runner.call_map[(borrow, sig, config["unichain_rpc"])] = bad_val

                report = CrossGuardHealthChecker(config, runner=runner).run_all_checks()
                self.assertEqual(report["overall_status"], OverallStatus.CRITICAL.value)
                chk = next(c for c in report["checks"] if c["name"] == chk_name)
                self.assertEqual(chk["status"], Status.CRITICAL.value)

                rep = run_recovery_preflight(config, pos_id, 1, tx_hash, runner=runner)
                self.assertEqual(rep["status"], RecoveryStatus.RETRY_BLOCKED.value)
                self.assertIn(reason_frag, rep["reason"])

    # 114. M007.1: Vault riskController mismatch, unauthorized vault, or missing vault bytecode fails closed
    def test_114_m007_vault_risk_controller_and_authorized_vault_mismatch_fails_closed(self):
        pos_id = self._get_test_position_id()
        tx_hash = self._get_test_tx_hash()

        # Case A: CollateralVault.riskController() mismatch
        config_a = create_base_config()
        runner_a = self._setup_preflight_runner(config_a, pos_id, tx_hash)
        runner_a.call_map[(config_a["origin_collateral_vault"].lower(), "riskController()", config_a["base_rpc"])] = (
            "0x9999999999999999999999999999999999999999"
        )
        rep_a = run_recovery_preflight(config_a, pos_id, 1, tx_hash, runner=runner_a)
        self.assertEqual(rep_a["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("riskController mismatch", rep_a["reason"])

        # Case B: RiskController.authorizedVaults(vault) == false
        config_b = create_base_config()
        runner_b = self._setup_preflight_runner(config_b, pos_id, tx_hash)
        runner_b.call_map[(config_b["origin_risk_controller"].lower(), "authorizedVaults(address)", config_b["base_rpc"])] = (
            "false"
        )
        hc_b = CrossGuardHealthChecker(config_b, runner=runner_b).run_all_checks()
        chk_b = next(c for c in hc_b["checks"] if c["name"] == "config_risk_controller_authorized_vault")
        self.assertEqual(chk_b["status"], Status.CRITICAL.value)
        rep_b = run_recovery_preflight(config_b, pos_id, 1, tx_hash, runner=runner_b)
        self.assertEqual(rep_b["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("not authorized", rep_b["reason"])

        # Case C: Missing CollateralVault bytecode
        config_c = create_base_config()
        runner_c = self._setup_preflight_runner(config_c, pos_id, tx_hash)
        runner_c.code_map[(config_c["origin_collateral_vault"].lower(), config_c["base_rpc"])] = "0x"
        rep_c = run_recovery_preflight(config_c, pos_id, 1, tx_hash, runner=runner_c)
        self.assertEqual(rep_c["status"], RecoveryStatus.RETRY_BLOCKED.value)
        self.assertIn("Origin CollateralVault", rep_c["reason"])

    # 115. M007.1: CLI flag and environment parsing for --origin-collateral-vault / BASE_COLLATERAL_VAULT
    def test_115_m007_cli_origin_collateral_vault_arg_and_env_parsing(self):
        from unittest.mock import patch

        with patch.dict(os.environ, {"BASE_COLLATERAL_VAULT": "0x5555555555555555555555555555555555555555"}):
            with patch.object(sys, "argv", ["crossguard_healthcheck.py"]):
                args_env = parse_arguments()
                self.assertEqual(
                    args_env.origin_collateral_vault, "0x5555555555555555555555555555555555555555"
                )
            with patch.object(
                sys,
                "argv",
                ["crossguard_healthcheck.py", "--origin-collateral-vault", "0x6666666666666666666666666666666666666666"],
            ):
                args_cli = parse_arguments()
                self.assertEqual(
                    args_cli.origin_collateral_vault, "0x6666666666666666666666666666666666666666"
                )


if __name__ == "__main__":
    unittest.main()

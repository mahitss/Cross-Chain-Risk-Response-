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
    DEFAULT_CALLBACK_PROXY,
    DEFAULT_SYSTEM_CONTRACT,
    REACTIVE_LASNA_CHAIN_ID,
    UNICHAIN_SEPOLIA_CHAIN_ID,
    CastRpcRunner,
    CheckCategory,
    CrossGuardHealthChecker,
    OverallStatus,
    RpcRunner,
    Status,
    compute_exit_code,
    decode_callback_records,
    format_terminal_report,
    redact_rpc_url,
    sanitize_text,
)


class MockRpcRunner(RpcRunner):
    """In-memory mocked RPC runner providing deterministic responses for offline testing."""

    def __init__(self):
        self.chain_ids: Dict[str, int] = {}
        self.code_map: Dict[Tuple[str, str], str] = {}
        self.call_map: Dict[Tuple[str, str, str], str] = {}
        self.balances: Dict[Tuple[str, str], int] = {}
        self.exceptions: Dict[Any, Exception] = {}

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


if __name__ == "__main__":
    unittest.main()

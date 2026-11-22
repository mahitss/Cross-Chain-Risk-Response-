#!/usr/bin/env python3
"""
CrossGuard Operational Health-Check and Diagnostics Tool
Part of Mission M005 — Cross-Chain Operational Observability & Failure Diagnosis.

Topology:
  - Origin: Base Sepolia (Chain ID: 84532)
  - Reactive Engine: Reactive Lasna (Chain ID: 5318007)
  - Destination: Unichain Sepolia (Chain ID: 1301)

Features:
  - Validates network reachability and chain IDs across all 3 chains
  - Verifies contract deployments and non-empty bytecodes
  - Validates cross-contract pointer configurations and topology consistency
  - Evaluates debt and reserves independently on System Contract and Callback Proxy
  - Validates callback gas configuration (>= 100,000 minimum)
  - Optionally inspects callback records via getCallbacks(uint256)
  - Strictly read-only: rejects write-capable commands, never requests private keys
"""

import argparse
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
import json
import os
import re
import shutil
import subprocess
import sys
from typing import Any, Dict, List, Optional, Tuple


# --- Constants & Expected Defaults ---
BASE_SEPOLIA_CHAIN_ID = 84532
REACTIVE_LASNA_CHAIN_ID = 5318007
UNICHAIN_SEPOLIA_CHAIN_ID = 1301

DEFAULT_SYSTEM_CONTRACT = "0x8888888888888888888888888888888888888888"
DEFAULT_CALLBACK_PROXY = "0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4"
MINIMUM_CALLBACK_GAS = 100_000


class Status(str, Enum):
    PASS = "PASS"
    WARNING = "WARNING"
    CRITICAL = "CRITICAL"
    UNKNOWN = "UNKNOWN"
    ERROR = "ERROR"


class CheckCategory(str, Enum):
    NETWORK = "NETWORK"
    DEPLOYMENT = "DEPLOYMENT"
    CONFIGURATION = "CONFIGURATION"
    FUNDING_AND_DEBT = "FUNDING_AND_DEBT"
    CALLBACK_GAS = "CALLBACK_GAS"
    CALLBACK_RECORDS = "CALLBACK_RECORDS"


@dataclass
class CheckResult:
    category: CheckCategory
    name: str
    status: Status
    message: str
    evidence: Dict[str, Any] = field(default_factory=dict)
    remediation: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "category": self.category.value,
            "name": self.name,
            "status": self.status.value,
            "message": self.message,
            "evidence": self.evidence,
            "remediation": self.remediation,
        }


# --- Address Normalization Utilities ---
def normalize_address(addr: str) -> str:
    """Normalizes address string to 0x-prefixed 40-char lowercase hex."""
    clean = addr.strip().lower()
    if clean.startswith("0x"):
        clean = clean[2:]
    if len(clean) > 40:
        # Extracted from 32-byte word (last 20 bytes = 40 hex chars)
        clean = clean[-40:]
    elif len(clean) < 40:
        clean = clean.zfill(40)
    return f"0x{clean}"


# --- RPC Runner Abstraction & Read-Only Security Guard ---
class RpcRunner:
    """Abstract interface for RPC execution, allowing deterministic offline testing."""

    def get_chain_id(self, rpc_url: str) -> int:
        raise NotImplementedError

    def get_code(self, address: str, rpc_url: str) -> str:
        raise NotImplementedError

    def call(self, address: str, signature: str, args: List[str], rpc_url: str) -> str:
        raise NotImplementedError

    def get_balance(self, address: str, rpc_url: str) -> int:
        raise NotImplementedError


class CastRpcRunner(RpcRunner):
    """Executes read-only commands using Foundry's cast CLI."""

    ALLOWED_SUBCOMMANDS = {"chain-id", "code", "call", "balance"}
    FORBIDDEN_FLAGS = {"--private-key", "--ledger", "--trezor", "--interactive", "--broadcast"}
    FORBIDDEN_COMMANDS = {"send", "mktx", "publish", "create2", "wallet"}

    def __init__(self, cast_path: Optional[str] = None):
        self.cast_path = cast_path or shutil.which("cast") or shutil.which("cast.exe")
        if not self.cast_path:
            raise FileNotFoundError("Foundry 'cast' executable not found on PATH.")

    def _execute(self, subcommand: str, cmd_args: List[str]) -> str:
        # Strict security enforcement: No write-capable commands allowed
        if subcommand not in self.ALLOWED_SUBCOMMANDS:
            raise PermissionError(f"Security violation: Command '{subcommand}' is not in read-only whitelist.")

        for arg in cmd_args:
            for forbidden in self.FORBIDDEN_FLAGS | self.FORBIDDEN_COMMANDS:
                if forbidden in arg.lower():
                    raise PermissionError(f"Security violation: Forbidden argument or token '{arg}' detected.")

        full_cmd = [self.cast_path, subcommand] + cmd_args
        try:
            res = subprocess.run(full_cmd, capture_output=True, text=True, check=True)
            return res.stdout.strip()
        except subprocess.CalledProcessError as e:
            err_msg = e.stderr.strip() or e.stdout.strip() or f"Process exited with code {e.returncode}"
            raise RuntimeError(f"Cast {subcommand} failed: {err_msg}") from e

    def get_chain_id(self, rpc_url: str) -> int:
        out = self._execute("chain-id", ["--rpc-url", rpc_url])
        return int(out, 0)

    def get_code(self, address: str, rpc_url: str) -> str:
        return self._execute("code", [address, "--rpc-url", rpc_url])

    def call(self, address: str, signature: str, args: List[str], rpc_url: str) -> str:
        params = [address, signature] + args + ["--rpc-url", rpc_url]
        return self._execute("call", params)

    def get_balance(self, address: str, rpc_url: str) -> int:
        out = self._execute("balance", [address, "--rpc-url", rpc_url])
        return int(out.split()[0], 0)


# --- Health Check Engine ---
class CrossGuardHealthChecker:
    def __init__(self, config: Dict[str, Any], runner: Optional[RpcRunner] = None):
        self.config = config
        self.runner = runner or CastRpcRunner()
        self.results: List[CheckResult] = []

    def run_all_checks(self) -> Dict[str, Any]:
        self.results.clear()

        # Phase 1: Network reachability and chain IDs
        self._check_networks()

        # Phase 2: Contract deployments (bytecodes)
        self._check_deployments()

        # Phase 3: Cross-contract configuration consistency
        self._check_configurations()

        # Phase 4: Funding, reserves, and debt
        self._check_funding_and_debt()

        # Phase 5: Callback gas configuration
        self._check_callback_gas()

        # Phase 6: Optional callback record inspection
        if self.config.get("reactive_tx_hash"):
            self._check_callback_record(self.config["reactive_tx_hash"])

        overall_status = self._calculate_overall_status()

        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "overall_status": overall_status.value,
            "summary": {
                "total": len(self.results),
                "pass": sum(1 for r in self.results if r.status == Status.PASS),
                "warning": sum(1 for r in self.results if r.status == Status.WARNING),
                "critical": sum(1 for r in self.results if r.status == Status.CRITICAL),
                "unknown": sum(1 for r in self.results if r.status == Status.UNKNOWN),
                "error": sum(1 for r in self.results if r.status == Status.ERROR),
            },
            "checks": [r.to_dict() for r in self.results],
            "topology": {
                "base_sepolia": {
                    "expected_chain_id": BASE_SEPOLIA_CHAIN_ID,
                    "rpc_url": self.config.get("base_rpc"),
                    "risk_controller": self.config.get("origin_risk_controller"),
                },
                "reactive_lasna": {
                    "expected_chain_id": REACTIVE_LASNA_CHAIN_ID,
                    "rpc_url": self.config.get("reactive_rpc"),
                    "reactive_contract": self.config.get("reactive_address"),
                    "system_contract": self.config.get("system_contract", DEFAULT_SYSTEM_CONTRACT),
                },
                "unichain_sepolia": {
                    "expected_chain_id": UNICHAIN_SEPOLIA_CHAIN_ID,
                    "rpc_url": self.config.get("unichain_rpc"),
                    "callback_adapter": self.config.get("callback_address"),
                    "borrowing_controller": self.config.get("borrowing_controller_address"),
                    "callback_proxy": self.config.get("callback_proxy", DEFAULT_CALLBACK_PROXY),
                },
            },
        }

    def _calculate_overall_status(self) -> Status:
        statuses = {r.status for r in self.results}
        if Status.CRITICAL in statuses:
            return Status.CRITICAL
        if Status.ERROR in statuses:
            return Status.ERROR
        if Status.WARNING in statuses:
            return Status.WARNING
        if Status.UNKNOWN in statuses:
            return Status.UNKNOWN
        return Status.PASS

    # --- Check Implementations ---

    def _check_networks(self):
        targets = [
            ("Base Sepolia", self.config.get("base_rpc"), BASE_SEPOLIA_CHAIN_ID, "network_base_sepolia"),
            ("Reactive Lasna", self.config.get("reactive_rpc"), REACTIVE_LASNA_CHAIN_ID, "network_reactive_lasna"),
            ("Unichain Sepolia", self.config.get("unichain_rpc"), UNICHAIN_SEPOLIA_CHAIN_ID, "network_unichain_sepolia"),
        ]

        for name, rpc, expected_chain_id, check_id in targets:
            if not rpc:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.NETWORK,
                        name=check_id,
                        status=Status.UNKNOWN,
                        message=f"{name} RPC URL not configured.",
                        evidence={"expected_chain_id": expected_chain_id, "rpc_url": None},
                        remediation=f"Configure the RPC URL via environment variable or CLI flag for {name}.",
                    )
                )
                continue

            try:
                actual_id = self.runner.get_chain_id(rpc)
                if actual_id == expected_chain_id:
                    self.results.append(
                        CheckResult(
                            category=CheckCategory.NETWORK,
                            name=check_id,
                            status=Status.PASS,
                            message=f"{name} RPC reachable with correct chain ID ({actual_id}).",
                            evidence={"expected_chain_id": expected_chain_id, "actual_chain_id": actual_id, "rpc_url": rpc},
                        )
                    )
                else:
                    self.results.append(
                        CheckResult(
                            category=CheckCategory.NETWORK,
                            name=check_id,
                            status=Status.CRITICAL,
                            message=f"{name} chain ID mismatch: expected {expected_chain_id}, received {actual_id}.",
                            evidence={"expected_chain_id": expected_chain_id, "actual_chain_id": actual_id, "rpc_url": rpc},
                            remediation="Verify RPC endpoint configuration. The node is operating on an incorrect blockchain network.",
                        )
                    )
            except Exception as e:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.NETWORK,
                        name=check_id,
                        status=Status.ERROR,
                        message=f"{name} RPC unreachable or query failed: {str(e)}",
                        evidence={"expected_chain_id": expected_chain_id, "rpc_url": rpc, "error": str(e)},
                        remediation=f"Check network connectivity, RPC provider status, or rate limits for {name}.",
                    )
                )

    def _check_deployments(self):
        contracts = [
            ("Origin RiskController", self.config.get("origin_risk_controller"), self.config.get("base_rpc"), "deployment_origin_risk_controller"),
            ("Reactive CrossGuardReactive", self.config.get("reactive_address"), self.config.get("reactive_rpc"), "deployment_reactive_crossguard"),
            ("Destination CrossGuardCallback", self.config.get("callback_address"), self.config.get("unichain_rpc"), "deployment_destination_callback"),
            ("Destination BorrowingController", self.config.get("borrowing_controller_address"), self.config.get("unichain_rpc"), "deployment_borrowing_controller"),
            ("Destination Callback Proxy", self.config.get("callback_proxy", DEFAULT_CALLBACK_PROXY), self.config.get("unichain_rpc"), "deployment_callback_proxy"),
        ]

        for name, addr, rpc, check_id in contracts:
            if not addr:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.DEPLOYMENT,
                        name=check_id,
                        status=Status.UNKNOWN,
                        message=f"{name} address not configured.",
                        evidence={"contract_name": name, "address": None},
                        remediation=f"Specify address for {name}.",
                    )
                )
                continue

            if not rpc:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.DEPLOYMENT,
                        name=check_id,
                        status=Status.UNKNOWN,
                        message=f"RPC not available to verify {name}.",
                        evidence={"contract_name": name, "address": addr},
                        remediation="Ensure RPC URL is provided.",
                    )
                )
                continue

            try:
                code = self.runner.get_code(addr, rpc)
                clean_code = code.strip().lower()
                if clean_code in ("", "0x", "0x0"):
                    self.results.append(
                        CheckResult(
                            category=CheckCategory.DEPLOYMENT,
                            name=check_id,
                            status=Status.CRITICAL,
                            message=f"{name} has NO deployed bytecode at {addr} (empty code).",
                            evidence={"contract_name": name, "address": addr, "code_length": len(code)},
                            remediation=f"Deploy {name} to the target network or update configuration with valid address.",
                        )
                    )
                else:
                    self.results.append(
                        CheckResult(
                            category=CheckCategory.DEPLOYMENT,
                            name=check_id,
                            status=Status.PASS,
                            message=f"{name} is deployed at {addr} with bytecode length {len(code)} chars.",
                            evidence={"contract_name": name, "address": addr, "code_length": len(code)},
                        )
                    )
            except Exception as e:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.DEPLOYMENT,
                        name=check_id,
                        status=Status.ERROR,
                        message=f"Failed to fetch bytecode for {name} at {addr}: {str(e)}",
                        evidence={"contract_name": name, "address": addr, "error": str(e)},
                        remediation="Investigate RPC connectivity or node state.",
                    )
                )

    def _check_configurations(self):
        # 1. CrossGuardReactive configuration
        reactive_addr = self.config.get("reactive_address")
        reactive_rpc = self.config.get("reactive_rpc")
        origin_controller = self.config.get("origin_risk_controller")
        callback_addr = self.config.get("callback_address")
        system_addr = self.config.get("system_contract", DEFAULT_SYSTEM_CONTRACT)

        if reactive_addr and reactive_rpc:
            # Check originChainId()
            self._verify_call_uint(
                reactive_addr, "originChainId()", reactive_rpc, BASE_SEPOLIA_CHAIN_ID,
                "config_reactive_origin_chain_id", "Reactive origin chain ID matches Base Sepolia (84532)"
            )
            # Check originRiskController()
            if origin_controller:
                self._verify_call_addr(
                    reactive_addr, "originRiskController()", reactive_rpc, origin_controller,
                    "config_reactive_origin_risk_controller", "Reactive originRiskController matches configured RiskController"
                )
            # Check destinationChainId()
            self._verify_call_uint(
                reactive_addr, "destinationChainId()", reactive_rpc, UNICHAIN_SEPOLIA_CHAIN_ID,
                "config_reactive_dest_chain_id", "Reactive destination chain ID matches Unichain Sepolia (1301)"
            )
            # Check destinationCallback()
            if callback_addr:
                self._verify_call_addr(
                    reactive_addr, "destinationCallback()", reactive_rpc, callback_addr,
                    "config_reactive_dest_callback", "Reactive destinationCallback matches configured CrossGuardCallback"
                )
            # Check systemContract()
            self._verify_call_addr(
                reactive_addr, "systemContract()", reactive_rpc, system_addr,
                "config_reactive_system_contract", "Reactive systemContract matches configured Omni System Contract"
            )

        # 2. CrossGuardCallback configuration
        unichain_rpc = self.config.get("unichain_rpc")
        proxy_addr = self.config.get("callback_proxy", DEFAULT_CALLBACK_PROXY)
        borrow_addr = self.config.get("borrowing_controller_address")

        if callback_addr and unichain_rpc:
            # Check callbackProxy()
            self._verify_call_addr(
                callback_addr, "callbackProxy()", unichain_rpc, proxy_addr,
                "config_callback_proxy", "CrossGuardCallback callbackProxy matches configured proxy address"
            )
            # Check authorizedReactiveSender()
            if reactive_addr:
                self._verify_call_addr(
                    callback_addr, "authorizedReactiveSender()", unichain_rpc, reactive_addr,
                    "config_callback_authorized_reactive", "CrossGuardCallback authorizedReactiveSender matches deployed CrossGuardReactive"
                )
            # Check borrowingController()
            if borrow_addr:
                self._verify_call_addr(
                    callback_addr, "borrowingController()", unichain_rpc, borrow_addr,
                    "config_callback_borrowing_controller", "CrossGuardCallback borrowingController matches deployed BorrowingController"
                )

        # 3. BorrowingController configuration
        if borrow_addr and unichain_rpc and callback_addr:
            self._verify_call_addr(
                borrow_addr, "callbackAdapter()", unichain_rpc, callback_addr,
                "config_controller_callback_adapter", "BorrowingController callbackAdapter matches deployed CrossGuardCallback"
            )

    def _verify_call_uint(self, contract: str, sig: str, rpc: str, expected: int, check_id: str, label: str):
        try:
            raw = self.runner.call(contract, sig, [], rpc)
            val = int(raw, 0)
            if val == expected:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CONFIGURATION,
                        name=check_id,
                        status=Status.PASS,
                        message=f"{label}: {val}",
                        evidence={"contract": contract, "signature": sig, "actual": val, "expected": expected},
                    )
                )
            else:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CONFIGURATION,
                        name=check_id,
                        status=Status.CRITICAL,
                        message=f"Configuration mismatch for {sig}: expected {expected}, found {val}.",
                        evidence={"contract": contract, "signature": sig, "actual": val, "expected": expected},
                        remediation=f"Reconfigure {contract} via setter to match expected value {expected}.",
                    )
                )
        except Exception as e:
            self.results.append(
                CheckResult(
                    category=CheckCategory.CONFIGURATION,
                    name=check_id,
                    status=Status.ERROR,
                    message=f"Failed to query {sig} on {contract}: {str(e)}",
                    evidence={"contract": contract, "signature": sig, "error": str(e)},
                    remediation="Check contract ABI and RPC reachability.",
                )
            )

    def _verify_call_addr(self, contract: str, sig: str, rpc: str, expected: str, check_id: str, label: str):
        try:
            raw = self.runner.call(contract, sig, [], rpc)
            actual_norm = normalize_address(raw)
            expected_norm = normalize_address(expected)
            if actual_norm == expected_norm:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CONFIGURATION,
                        name=check_id,
                        status=Status.PASS,
                        message=f"{label}: {actual_norm}",
                        evidence={"contract": contract, "signature": sig, "actual": actual_norm, "expected": expected_norm},
                    )
                )
            else:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CONFIGURATION,
                        name=check_id,
                        status=Status.CRITICAL,
                        message=f"Address mismatch for {sig}: expected {expected_norm}, found {actual_norm}.",
                        evidence={"contract": contract, "signature": sig, "actual": actual_norm, "expected": expected_norm},
                        remediation=f"Update contract configuration on {contract} to point to {expected_norm}.",
                    )
                )
        except Exception as e:
            self.results.append(
                CheckResult(
                    category=CheckCategory.CONFIGURATION,
                    name=check_id,
                    status=Status.ERROR,
                    message=f"Failed to query {sig} on {contract}: {str(e)}",
                    evidence={"contract": contract, "signature": sig, "error": str(e)},
                    remediation="Check contract ABI and RPC reachability.",
                )
            )

    def _check_funding_and_debt(self):
        # 1. Reactive Lasna Side
        reactive_addr = self.config.get("reactive_address")
        reactive_rpc = self.config.get("reactive_rpc")
        system_addr = self.config.get("system_contract", DEFAULT_SYSTEM_CONTRACT)

        if reactive_addr and reactive_rpc and system_addr:
            # Query debt(address)
            try:
                debt_raw = self.runner.call(system_addr, "debt(address)", [reactive_addr], reactive_rpc)
                debt_val = int(debt_raw, 0)
                if debt_val > 0:
                    self.results.append(
                        CheckResult(
                            category=CheckCategory.FUNDING_AND_DEBT,
                            name="funding_reactive_system_debt",
                            status=Status.CRITICAL,
                            message=f"Reactive contract has OUTSTANDING DEBT of {debt_val} wei on System Contract. react() execution may be suspended.",
                            evidence={"system_contract": system_addr, "target": reactive_addr, "debt_wei": debt_val},
                            remediation="Fund the contract and settle debt using authorized Reactive System Contract deposit routes.",
                        )
                    )
                else:
                    self.results.append(
                        CheckResult(
                            category=CheckCategory.FUNDING_AND_DEBT,
                            name="funding_reactive_system_debt",
                            status=Status.PASS,
                            message="Reactive contract has 0 outstanding debt on System Contract.",
                            evidence={"system_contract": system_addr, "target": reactive_addr, "debt_wei": 0},
                        )
                    )
            except Exception as e:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_reactive_system_debt",
                        status=Status.ERROR,
                        message=f"Failed to query debt on System Contract: {str(e)}",
                        evidence={"error": str(e)},
                    )
                )

            # Query reserves(address)
            try:
                reserves_raw = self.runner.call(system_addr, "reserves(address)", [reactive_addr], reactive_rpc)
                reserves_val = int(reserves_raw, 0)
                if reserves_val == 0:
                    self.results.append(
                        CheckResult(
                            category=CheckCategory.FUNDING_AND_DEBT,
                            name="funding_reactive_system_reserves",
                            status=Status.WARNING,
                            message="Reactive contract has 0 prepaid reserves on System Contract. Execution depends on ongoing funding.",
                            evidence={"system_contract": system_addr, "target": reactive_addr, "reserves_wei": 0},
                            remediation="Deposit prepaid REACT reserves into the System Contract to ensure uninterrupted reactive execution.",
                        )
                    )
                else:
                    self.results.append(
                        CheckResult(
                            category=CheckCategory.FUNDING_AND_DEBT,
                            name="funding_reactive_system_reserves",
                            status=Status.PASS,
                            message=f"Reactive contract has {reserves_val} wei in prepaid System Contract reserves.",
                            evidence={"system_contract": system_addr, "target": reactive_addr, "reserves_wei": reserves_val},
                        )
                    )
            except Exception as e:
                # In some mock contracts reserves may not be defined; report clearly
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_reactive_system_reserves",
                        status=Status.UNKNOWN,
                        message=f"Reserves query on System Contract returned error: {str(e)}",
                        evidence={"error": str(e)},
                    )
                )

            # Query Native Balance of CrossGuardReactive
            try:
                bal_wei = self.runner.get_balance(reactive_addr, reactive_rpc)
                bal_eth = bal_wei / 1e18
                note = "Note: CrossGuardReactive.pay(uint256) reverts with 'Not implemented'. Direct native balance cannot automatically settle debt via pay()."
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_reactive_native_balance",
                        status=Status.PASS if bal_wei > 0 else Status.WARNING,
                        message=f"CrossGuardReactive native balance: {bal_wei} wei ({bal_eth:.6f} REACT). {note}",
                        evidence={"contract": reactive_addr, "balance_wei": bal_wei, "balance_eth": bal_eth},
                        remediation="Ensure contract maintains adequate native balance for operation." if bal_wei == 0 else None,
                    )
                )
            except Exception as e:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_reactive_native_balance",
                        status=Status.ERROR,
                        message=f"Failed to query native balance of CrossGuardReactive: {str(e)}",
                        evidence={"error": str(e)},
                    )
                )

        # 2. Destination Unichain Sepolia Side
        callback_addr = self.config.get("callback_address")
        unichain_rpc = self.config.get("unichain_rpc")
        proxy_addr = self.config.get("callback_proxy", DEFAULT_CALLBACK_PROXY)

        if callback_addr and unichain_rpc and proxy_addr:
            # Query debt(address) on Callback Proxy
            try:
                p_debt_raw = self.runner.call(proxy_addr, "debt(address)", [callback_addr], unichain_rpc)
                p_debt_val = int(p_debt_raw, 0)
                if p_debt_val > 0:
                    self.results.append(
                        CheckResult(
                            category=CheckCategory.FUNDING_AND_DEBT,
                            name="funding_callback_proxy_debt",
                            status=Status.CRITICAL,
                            message=f"CrossGuardCallback has OUTSTANDING DEBT of {p_debt_val} wei on Callback Proxy. Incoming callbacks may be rejected.",
                            evidence={"callback_proxy": proxy_addr, "target": callback_addr, "debt_wei": p_debt_val},
                            remediation="Settle callback debt with the Callback Proxy immediately.",
                        )
                    )
                else:
                    self.results.append(
                        CheckResult(
                            category=CheckCategory.FUNDING_AND_DEBT,
                            name="funding_callback_proxy_debt",
                            status=Status.PASS,
                            message="CrossGuardCallback has 0 outstanding debt on Callback Proxy.",
                            evidence={"callback_proxy": proxy_addr, "target": callback_addr, "debt_wei": 0},
                        )
                    )
            except Exception as e:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_callback_proxy_debt",
                        status=Status.ERROR,
                        message=f"Failed to query debt on Callback Proxy: {str(e)}",
                        evidence={"error": str(e)},
                    )
                )

            # Query reserves(address) on Callback Proxy
            try:
                p_reserves_raw = self.runner.call(proxy_addr, "reserves(address)", [callback_addr], unichain_rpc)
                p_reserves_val = int(p_reserves_raw, 0)
                if p_reserves_val == 0:
                    self.results.append(
                        CheckResult(
                            category=CheckCategory.FUNDING_AND_DEBT,
                            name="funding_callback_proxy_reserves",
                            status=Status.WARNING,
                            message="CrossGuardCallback has 0 prepaid reserves on Callback Proxy. Callbacks depend on direct settlement.",
                            evidence={"callback_proxy": proxy_addr, "target": callback_addr, "reserves_wei": 0},
                            remediation="Deposit native reserves into the Callback Proxy on Unichain Sepolia.",
                        )
                    )
                else:
                    self.results.append(
                        CheckResult(
                            category=CheckCategory.FUNDING_AND_DEBT,
                            name="funding_callback_proxy_reserves",
                            status=Status.PASS,
                            message=f"CrossGuardCallback has {p_reserves_val} wei in Callback Proxy reserves.",
                            evidence={"callback_proxy": proxy_addr, "target": callback_addr, "reserves_wei": p_reserves_val},
                        )
                    )
            except Exception as e:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_callback_proxy_reserves",
                        status=Status.UNKNOWN,
                        message=f"Reserves query on Callback Proxy returned error: {str(e)}",
                        evidence={"error": str(e)},
                    )
                )

            # Query Native Balance of CrossGuardCallback
            try:
                c_bal_wei = self.runner.get_balance(callback_addr, unichain_rpc)
                c_bal_eth = c_bal_wei / 1e18
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_callback_native_balance",
                        status=Status.PASS if c_bal_wei > 0 else Status.WARNING,
                        message=f"CrossGuardCallback native balance: {c_bal_wei} wei ({c_bal_eth:.6f} ETH).",
                        evidence={"contract": callback_addr, "balance_wei": c_bal_wei, "balance_eth": c_bal_eth},
                        remediation="Deposit native ETH on Unichain Sepolia if proxy charges directly from recipient balance." if c_bal_wei == 0 else None,
                    )
                )
            except Exception as e:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_callback_native_balance",
                        status=Status.ERROR,
                        message=f"Failed to query native balance of CrossGuardCallback: {str(e)}",
                        evidence={"error": str(e)},
                    )
                )

    def _check_callback_gas(self):
        reactive_addr = self.config.get("reactive_address")
        reactive_rpc = self.config.get("reactive_rpc")

        if not reactive_addr or not reactive_rpc:
            return

        try:
            raw_gas = self.runner.call(reactive_addr, "callbackGasLimit()", [], reactive_rpc)
            gas_val = int(raw_gas, 0)
            if gas_val < MINIMUM_CALLBACK_GAS:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CALLBACK_GAS,
                        name="callback_gas_limit_check",
                        status=Status.CRITICAL,
                        message=f"Configured callbackGasLimit ({gas_val}) is BELOW required Reactive minimum of {MINIMUM_CALLBACK_GAS} gas.",
                        evidence={"configured_gas_limit": gas_val, "minimum_required": MINIMUM_CALLBACK_GAS},
                        remediation=f"Call setDestinationConfig to increase callbackGasLimit to at least {MINIMUM_CALLBACK_GAS} gas (recommended: 300,000 gas).",
                    )
                )
            else:
                advisory = "Note: Proxy reserves accounting overhead for execution and debt settlement; gas forwarded to the target callback method is strictly less than the configured envelope."
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CALLBACK_GAS,
                        name="callback_gas_limit_check",
                        status=Status.PASS,
                        message=f"Configured callbackGasLimit is {gas_val} gas (>= {MINIMUM_CALLBACK_GAS} gas). {advisory}",
                        evidence={"configured_gas_limit": gas_val, "minimum_required": MINIMUM_CALLBACK_GAS},
                    )
                )
        except Exception as e:
            self.results.append(
                CheckResult(
                    category=CheckCategory.CALLBACK_GAS,
                    name="callback_gas_limit_check",
                    status=Status.ERROR,
                    message=f"Failed to query callbackGasLimit: {str(e)}",
                    evidence={"error": str(e)},
                )
            )

    def _check_callback_record(self, tx_hash_str: str):
        reactive_rpc = self.config.get("reactive_rpc")
        system_addr = self.config.get("system_contract", DEFAULT_SYSTEM_CONTRACT)

        if not reactive_rpc or not system_addr:
            self.results.append(
                CheckResult(
                    category=CheckCategory.CALLBACK_RECORDS,
                    name="callback_record_inspection",
                    status=Status.UNKNOWN,
                    message="Reactive RPC or System Contract address not configured to query callback records.",
                    evidence={"tx_hash": tx_hash_str},
                )
            )
            return

        # Ensure tx_hash is properly parsed to uint256 parameter
        try:
            clean_hash = tx_hash_str.strip()
            uint_hash_str = str(int(clean_hash, 16)) if clean_hash.startswith("0x") else str(int(clean_hash))
        except ValueError:
            self.results.append(
                CheckResult(
                    category=CheckCategory.CALLBACK_RECORDS,
                    name="callback_record_inspection",
                    status=Status.ERROR,
                    message=f"Invalid transaction hash format: {tx_hash_str}",
                    evidence={"tx_hash": tx_hash_str},
                    remediation="Provide a valid 32-byte hex transaction hash (e.g., 0xabc...).",
                )
            )
            return

        try:
            raw_out = self.runner.call(system_addr, "getCallbacks(uint256)", [uint_hash_str], reactive_rpc)
            clean_out = raw_out.strip()

            # Empty response or empty ABI array (length 0)
            is_empty = clean_out in ("", "0x", "()", "[]") or clean_out.endswith("0000000000000000000000000000000000000000000000000000000000000000") and len(clean_out) <= 130

            if is_empty:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CALLBACK_RECORDS,
                        name="callback_record_inspection",
                        status=Status.UNKNOWN,
                        message="Callback records are pending, not yet recorded, or unavailable on Reactive System Contract.",
                        evidence={"tx_hash": tx_hash_str, "raw_response": raw_out, "state": "PENDING_OR_UNAVAILABLE"},
                        remediation="Wait for cross-chain relaying and destination block finalization, then query again. Do not treat as confirmed failure.",
                    )
                )
                return

            # Parse record data
            record_info = self._parse_callback_record(clean_out)
            if record_info.get("success") is True:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CALLBACK_RECORDS,
                        name="callback_record_inspection",
                        status=Status.PASS,
                        message=f"Callback execution recorded as SUCCESS on destination chain {record_info.get('destination_chain_id')}.",
                        evidence={"tx_hash": tx_hash_str, "record": record_info, "raw_response": raw_out},
                    )
                )
            elif record_info.get("success") is False:
                err_data = record_info.get("error_data", "")
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CALLBACK_RECORDS,
                        name="callback_record_inspection",
                        status=Status.CRITICAL,
                        message=f"Callback execution recorded as FAILED on destination chain {record_info.get('destination_chain_id')}. Raw error: {err_data}",
                        evidence={"tx_hash": tx_hash_str, "record": record_info, "raw_response": raw_out},
                        remediation="Inspect error data and destination callback logic (e.g., invalid nonce, gas exhaustion, or revert).",
                    )
                )
            else:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CALLBACK_RECORDS,
                        name="callback_record_inspection",
                        status=Status.UNKNOWN,
                        message="Callback records returned non-empty data but outcome could not be deterministically decoded.",
                        evidence={"tx_hash": tx_hash_str, "raw_response": raw_out, "parsed": record_info},
                    )
                )
        except Exception as e:
            self.results.append(
                CheckResult(
                    category=CheckCategory.CALLBACK_RECORDS,
                    name="callback_record_inspection",
                    status=Status.ERROR,
                    message=f"Failed to query getCallbacks(uint256) on System Contract: {str(e)}",
                    evidence={"tx_hash": tx_hash_str, "error": str(e)},
                    remediation="Check Reactive Lasna RPC health and system contract interface compatibility.",
                )
            )

    def _parse_callback_record(self, raw_data: str) -> Dict[str, Any]:
        """Parses decoded or raw hex callback records from getCallbacks."""
        parsed: Dict[str, Any] = {"raw": raw_data}

        # Check for formatted cast output containing boolean keywords
        lower = raw_data.lower()
        if "true" in lower:
            parsed["success"] = True
        elif "false" in lower:
            parsed["success"] = False

        # Extract destination chain ID if present
        chain_match = re.search(r"(\b1301\b|\b84532\b)", raw_data)
        if chain_match:
            parsed["destination_chain_id"] = int(chain_match.group(1))

        # Extract transaction hash (64 hex characters)
        tx_matches = re.findall(r"0x[a-fA-F0-9]{64}", raw_data)
        if tx_matches:
            parsed["destination_tx_hash"] = tx_matches[-1]

        # Extract custom revert data if error
        if parsed.get("success") is False:
            err_matches = re.findall(r"0x[a-fA-F0-9]{8,}", raw_data)
            if err_matches:
                parsed["error_data"] = err_matches[-1]

        return parsed


# --- Human-Readable Terminal Formatter ---
def format_terminal_report(report: Dict[str, Any]) -> str:
    lines = []
    lines.append("=" * 80)
    lines.append("           CROSSGUARD OPERATIONAL HEALTH CHECK & DIAGNOSTICS REPORT")
    lines.append("=" * 80)
    lines.append(f"Timestamp (UTC): {report['timestamp']}")
    lines.append(f"Overall Status:  [{report['overall_status']}]")
    s = report["summary"]
    lines.append(f"Check Summary:   Total: {s['total']} | Pass: {s['pass']} | Warning: {s['warning']} | Critical: {s['critical']} | Error: {s['error']}")
    lines.append("-" * 80)

    # Topology Overview
    lines.append("TOPOLOGY CONFIGURATION:")
    topo = report["topology"]
    lines.append(f"  • Base Sepolia (Origin: {topo['base_sepolia']['expected_chain_id']}):")
    lines.append(f"      RPC: {topo['base_sepolia']['rpc_url'] or '<Not configured>'}")
    lines.append(f"      RiskController: {topo['base_sepolia']['risk_controller'] or '<Not configured>'}")
    lines.append(f"  • Reactive Lasna (Engine: {topo['reactive_lasna']['expected_chain_id']}):")
    lines.append(f"      RPC: {topo['reactive_lasna']['rpc_url'] or '<Not configured>'}")
    lines.append(f"      CrossGuardReactive: {topo['reactive_lasna']['reactive_contract'] or '<Not configured>'}")
    lines.append(f"      SystemContract: {topo['reactive_lasna']['system_contract']}")
    lines.append(f"  • Unichain Sepolia (Destination: {topo['unichain_sepolia']['expected_chain_id']}):")
    lines.append(f"      RPC: {topo['unichain_sepolia']['rpc_url'] or '<Not configured>'}")
    lines.append(f"      CrossGuardCallback: {topo['unichain_sepolia']['callback_adapter'] or '<Not configured>'}")
    lines.append(f"      BorrowingController: {topo['unichain_sepolia']['borrowing_controller'] or '<Not configured>'}")
    lines.append(f"      CallbackProxy: {topo['unichain_sepolia']['callback_proxy']}")
    lines.append("-" * 80)

    # Individual Checks
    lines.append("DIAGNOSTIC CHECKS:")
    current_cat = None
    for check in report["checks"]:
        if check["category"] != current_cat:
            current_cat = check["category"]
            lines.append(f"\n[{current_cat}]")

        status_tag = f"[{check['status']}]".ljust(11)
        lines.append(f"  {status_tag} {check['name']}: {check['message']}")
        if check["status"] in ("CRITICAL", "ERROR", "WARNING") and check.get("remediation"):
            lines.append(f"              -> Remediation: {check['remediation']}")

    lines.append("\n" + "=" * 80)
    lines.append("OPERATIONAL ADVISORY & SAFETY BOUNDARIES:")
    lines.append("  1. Tool is strictly read-only; no private keys, transactions, or state mutations.")
    lines.append("  2. Inactive Reactive contracts or callback debts halt cross-chain response pipelines.")
    lines.append("  3. CrossGuardReactive.pay() reverts with 'Not implemented'; manage reserves explicitly.")
    lines.append("  4. Empty callback records represent pending/unfinalized states, not confirmed failures.")
    lines.append("=" * 80)
    return "\n".join(lines)


# --- CLI Argument Parsing ---
def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="CrossGuard Cross-Chain Operational Health Check & Diagnostics Tool"
    )

    # RPC URLs
    parser.add_argument("--base-rpc", default=os.getenv("BASE_SEPOLIA_RPC_URL"), help="Base Sepolia RPC URL")
    parser.add_argument("--reactive-rpc", default=os.getenv("REACTIVE_LASNA_RPC_URL"), help="Reactive Lasna RPC URL")
    parser.add_argument("--unichain-rpc", default=os.getenv("UNICHAIN_SEPOLIA_RPC_URL"), help="Unichain Sepolia RPC URL")

    # Contract Addresses
    parser.add_argument(
        "--origin-risk-controller",
        default=os.getenv("BASE_RISK_CONTROLLER") or os.getenv("ORIGIN_RISK_CONTROLLER"),
        help="Deployed RiskController address on Base Sepolia",
    )
    parser.add_argument(
        "--reactive-address",
        default=os.getenv("REACTIVE_CROSSGUARD") or os.getenv("CROSSGUARD_REACTIVE_ADDRESS"),
        help="Deployed CrossGuardReactive address on Reactive Lasna",
    )
    parser.add_argument(
        "--callback-address",
        default=os.getenv("UNICHAIN_CALLBACK_ADAPTER") or os.getenv("CROSSGUARD_CALLBACK_ADDRESS"),
        help="Deployed CrossGuardCallback address on Unichain Sepolia",
    )
    parser.add_argument(
        "--borrowing-controller-address",
        default=os.getenv("BORROWING_CONTROLLER_ADDRESS"),
        help="Deployed BorrowingController address on Unichain Sepolia",
    )
    parser.add_argument(
        "--system-contract-address",
        default=os.getenv("REACTIVE_SYSTEM_ADDRESS", DEFAULT_SYSTEM_CONTRACT),
        help=f"Reactive Omni System Contract address (default: {DEFAULT_SYSTEM_CONTRACT})",
    )
    parser.add_argument(
        "--callback-proxy-address",
        default=os.getenv("UNICHAIN_CALLBACK_PROXY_ADDRESS", DEFAULT_CALLBACK_PROXY),
        help=f"Unichain Sepolia Callback Proxy address (default: {DEFAULT_CALLBACK_PROXY})",
    )

    # Optional inspection
    parser.add_argument("--reactive-tx-hash", default=None, help="Inspect callback record for originating Reactive tx hash")
    parser.add_argument("--json", action="store_true", help="Output diagnostic report in machine-readable JSON")

    return parser.parse_args()


def main():
    args = parse_arguments()

    config = {
        "base_rpc": args.base_rpc,
        "reactive_rpc": args.reactive_rpc,
        "unichain_rpc": args.unichain_rpc,
        "origin_risk_controller": args.origin_risk_controller,
        "reactive_address": args.reactive_address,
        "callback_address": args.callback_address,
        "borrowing_controller_address": args.borrowing_controller_address,
        "system_contract": args.system_contract_address,
        "callback_proxy": args.callback_proxy_address,
        "reactive_tx_hash": args.reactive_tx_hash,
    }

    try:
        checker = CrossGuardHealthChecker(config)
        report = checker.run_all_checks()

        if args.json:
            print(json.dumps(report, indent=2))
        else:
            print(format_terminal_report(report))

        # Exit code reflects health: 0 for healthy/warning, 1 for critical/error
        if report["overall_status"] in (Status.CRITICAL.value, Status.ERROR.value):
            sys.exit(1)
        sys.exit(0)
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e), "overall_status": Status.ERROR.value}))
        else:
            print(f"FATAL ERROR during operational health check: {str(e)}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

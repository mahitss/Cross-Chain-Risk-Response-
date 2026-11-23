#!/usr/bin/env python3
"""
CrossGuard Operational Health-Check and Diagnostics Tool
Part of Mission M005 / M005.1 — Operational Safety, ABI Correctness & Multi-Chain Diagnostics.

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
  - Inspects callback records via getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])
  - Centralized RPC credential redaction across all reports, evidence, and messages
  - Strictly read-only: rejects write-capable commands, bounded execution timeouts
  - Deterministic exit codes: 0 for HEALTHY, 1 for WARNING, CRITICAL, UNKNOWN, ERROR
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
import urllib.parse


# --- Constants & Expected Defaults ---
BASE_SEPOLIA_CHAIN_ID = 84532
REACTIVE_LASNA_CHAIN_ID = 5318007
UNICHAIN_SEPOLIA_CHAIN_ID = 1301

DEFAULT_SYSTEM_CONTRACT = "0x8888888888888888888888888888888888888888"
DEFAULT_CALLBACK_PROXY = "0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4"
MINIMUM_CALLBACK_GAS = 100_000
DEFAULT_RPC_TIMEOUT_SECONDS = 15.0


class Status(str, Enum):
    PASS = "PASS"
    WARNING = "WARNING"
    CRITICAL = "CRITICAL"
    UNKNOWN = "UNKNOWN"
    ERROR = "ERROR"


class OverallStatus(str, Enum):
    HEALTHY = "HEALTHY"
    WARNING = "WARNING"
    CRITICAL = "CRITICAL"
    UNKNOWN = "UNKNOWN"
    ERROR = "ERROR"


class RecoveryStatus(str, Enum):
    RETRY_ELIGIBLE = "RETRY_ELIGIBLE"
    RETRY_BLOCKED = "RETRY_BLOCKED"
    RETRY_PENDING = "RETRY_PENDING"
    RETRY_ALREADY_SUCCEEDED = "RETRY_ALREADY_SUCCEEDED"
    RETRY_SUPERSEDED = "RETRY_SUPERSEDED"
    RETRY_UNKNOWN = "RETRY_UNKNOWN"


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


# --- Redaction & Sanitization Utilities ---
def redact_rpc_url(url: Optional[str]) -> Optional[str]:
    """
    Sanitizes an RPC URL by redacting credentials (userinfo, sensitive path segments, query parameters).
    Preserves scheme, host, and port (if non-standard).
    Replaces sensitive paths and query strings with /<redacted>.
    Does not modify the underlying raw URL passed to RPC clients.
    """
    if not url or not isinstance(url, str):
        return url
    trimmed = url.strip()
    try:
        parsed = urllib.parse.urlsplit(trimmed)
        if not parsed.scheme or not parsed.hostname:
            # Fallback regex scrubber for irregular URLs or raw strings
            scrubbed = re.sub(r'//[^/@\s]+@', '//<redacted>@', trimmed)
            scrubbed = re.sub(r'\?[^#\s]*', '?<redacted>', scrubbed)
            return scrubbed

        host_part = parsed.hostname
        if parsed.port and parsed.port not in (80, 443):
            host_part = f"{host_part}:{parsed.port}"

        has_sensitive_path = bool(parsed.path and parsed.path.strip('/'))
        has_query = bool(parsed.query)

        if has_sensitive_path or has_query:
            return f"{parsed.scheme}://{host_part}/<redacted>"
        else:
            return f"{parsed.scheme}://{host_part}"
    except Exception:
        return "<redacted_rpc_url>"


def sanitize_text(text: str, urls: Optional[List[str]] = None) -> str:
    """
    Scans text and scrubs any sensitive RPC URLs, userinfo, credentials, or tokens.
    """
    if not text or not isinstance(text, str):
        return text
    result = text
    if urls:
        for u in urls:
            if u and isinstance(u, str) and u in result:
                result = result.replace(u, redact_rpc_url(u) or "<redacted>")

    def _scrub_url(match):
        raw_u = match.group(0)
        return redact_rpc_url(raw_u) or "<redacted>"

    result = re.sub(r'https?://[^\s"\'<>]+', _scrub_url, result)
    result = re.sub(r'//[^/@\s]+:[^/@\s]+@', '//<redacted>@', result)
    return result


def compute_exit_code(overall_status: str) -> int:
    """
    Calculates process exit code based on top-level overall status:
    - HEALTHY: 0
    - WARNING: 1
    - CRITICAL: 1
    - UNKNOWN: 1
    - ERROR: 1
    """
    if overall_status == OverallStatus.HEALTHY.value:
        return 0
    return 1


def compute_recovery_exit_code(status: str) -> int:
    """
    Calculates process exit code for recovery preflight:
    - RETRY_ELIGIBLE: 0
    - RETRY_ALREADY_SUCCEEDED: 0
    - RETRY_BLOCKED: 1
    - RETRY_PENDING: 1
    - RETRY_SUPERSEDED: 1
    - RETRY_UNKNOWN: 1
    """
    if status in (RecoveryStatus.RETRY_ELIGIBLE.value, RecoveryStatus.RETRY_ALREADY_SUCCEEDED.value):
        return 0
    return 1


# --- Address Normalization Utilities ---
def normalize_address(addr: str) -> str:
    """Normalizes address string to 0x-prefixed 40-char lowercase hex."""
    clean = addr.strip().lower()
    if clean.startswith("0x"):
        clean = clean[2:]
    if len(clean) > 40:
        clean = clean[-40:]
    elif len(clean) < 40:
        clean = clean.zfill(40)
    return f"0x{clean}"


# --- Callback Record ABI Decoding ---
def decode_callback_records(raw_data: str) -> Tuple[Optional[List[Dict[str, Any]]], Optional[str]]:
    """
    Decodes return data from:
      getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])

    Official Reactive Network economy return schema:
      1. uint256 blockNumber          - Reactive block number when callback was requested
      2. address reactiveContract     - Requesting Reactive smart contract address
      3. uint256 callbackIndex        - Sequential index of callback
      4. uint256 destinationChainId   - Target destination EVM chain ID (e.g., 1301)
      5. uint256 destinationTxHash    - Transaction hash on destination network (0 if pending relay)
      6. bytes error                  - Execution revert data on destination (empty if success)

    Success condition:
      - Valid destination chain (1301)
      - Matching requesting Reactive contract
      - Non-zero destinationTxHash (mined on destination)
      - Empty error field ('0x' or length 0)

    Returns:
      (records_list, None) on successful parse (records_list may be empty if array length is 0).
      (None, error_message) on malformed or invalid data.
    """
    s = raw_data.strip()
    if s in ("", "0x", "()", "[]"):
        return [], None

    # Check for empty ABI array (offset 0x20, count 0)
    if s.startswith("0x") and len(s) == 130:
        try:
            clean_hex = s[2:]
            arr_offset = int(clean_hex[:64], 16)
            arr_len = int(clean_hex[64:128], 16)
            if arr_offset == 32 and arr_len == 0:
                return [], None
        except Exception:
            pass

    # 1. Try parsing formatted tuple string from cast call: [(blockNumber, reactiveContract, callbackIndex, destinationChainId, destinationTxHash, error)]
    if "(" in s and ")" in s:
        tuples = re.findall(r'\(([^)]+)\)', s)
        if not tuples:
            return None, "No tuples found in formatted response"
        records = []
        for t in tuples:
            parts = [p.strip() for p in t.split(',')]
            if len(parts) != 6:
                return None, f"Expected 6 fields per record, found {len(parts)}"
            try:
                block_number = int(parts[0], 0)
                reactive_contract = normalize_address(parts[1])
                callback_index = int(parts[2], 0)
                dest_chain_id = int(parts[3], 0)
                dest_tx_hash = int(parts[4], 0)
                err = parts[5].strip().lower()
                if not err.startswith("0x"):
                    err = "0x" + err if err else "0x"
                is_pending = (dest_tx_hash == 0)
                is_success = (err in ("0x", "")) and not is_pending
                records.append({
                    "block_number": block_number,
                    "blockNumber": block_number,
                    "reactive_contract": reactive_contract,
                    "reactiveContract": reactive_contract,
                    "callback_index": callback_index,
                    "callbackIndex": callback_index,
                    "destination_chain_id": dest_chain_id,
                    "destinationChainId": dest_chain_id,
                    "destination_tx_hash": dest_tx_hash,
                    "destinationTxHash": dest_tx_hash,
                    "error": err,
                    "success": is_success,
                    "is_pending": is_pending,
                })
            except Exception as e:
                return None, f"Error parsing formatted tuple fields: {str(e)}"
        return records, None

    # 2. Try parsing raw ABI-encoded hex response
    if s.startswith("0x"):
        try:
            raw_bytes = bytes.fromhex(s[2:])
            if len(raw_bytes) < 64:
                return None, "Hex response too short for dynamic ABI array"
            arr_offset = int.from_bytes(raw_bytes[:32], "big")
            if arr_offset >= len(raw_bytes):
                return None, f"Invalid array offset {arr_offset}"
            arr_len = int.from_bytes(raw_bytes[arr_offset:arr_offset+32], "big")
            if arr_len == 0:
                return [], None

            elements_start = arr_offset + 32
            records = []
            for i in range(arr_len):
                elem_offset_loc = elements_start + i * 32
                if elem_offset_loc + 32 > len(raw_bytes):
                    return None, f"Truncated element offset pointer at index {i}"
                elem_offset = int.from_bytes(raw_bytes[elem_offset_loc:elem_offset_loc+32], "big")
                tuple_start = elements_start + elem_offset
                if tuple_start + 192 > len(raw_bytes):
                    return None, f"Truncated tuple head at index {i}"

                block_number = int.from_bytes(raw_bytes[tuple_start:tuple_start+32], "big")
                reactive_contract = "0x" + raw_bytes[tuple_start+44:tuple_start+64].hex()
                callback_index = int.from_bytes(raw_bytes[tuple_start+64:tuple_start+96], "big")
                dest_chain_id = int.from_bytes(raw_bytes[tuple_start+96:tuple_start+128], "big")
                dest_tx_hash = int.from_bytes(raw_bytes[tuple_start+128:tuple_start+160], "big")
                bytes_offset = int.from_bytes(raw_bytes[tuple_start+160:tuple_start+192], "big")

                bytes_start = tuple_start + bytes_offset
                if bytes_start + 32 > len(raw_bytes):
                    return None, f"Truncated error bytes length at index {i}"
                bytes_len = int.from_bytes(raw_bytes[bytes_start:bytes_start+32], "big")
                data_start = bytes_start + 32
                if data_start + bytes_len > len(raw_bytes):
                    return None, f"Truncated error bytes payload at index {i}"

                err_data = raw_bytes[data_start:data_start+bytes_len]
                err_hex = "0x" + err_data.hex()
                is_pending = (dest_tx_hash == 0)
                is_success = (len(err_data) == 0) and not is_pending
                records.append({
                    "block_number": block_number,
                    "blockNumber": block_number,
                    "reactive_contract": normalize_address(reactive_contract),
                    "reactiveContract": normalize_address(reactive_contract),
                    "callback_index": callback_index,
                    "callbackIndex": callback_index,
                    "destination_chain_id": dest_chain_id,
                    "destinationChainId": dest_chain_id,
                    "destination_tx_hash": dest_tx_hash,
                    "destinationTxHash": dest_tx_hash,
                    "error": err_hex,
                    "success": is_success,
                    "is_pending": is_pending,
                })
            return records, None
        except Exception as e:
            return None, f"Hex ABI decoding error: {str(e)}"

    return None, "Unrecognized callback record format"


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

    def get_receipt(self, tx_hash: str, rpc_url: str) -> Dict[str, Any]:
        raise NotImplementedError


class CastRpcRunner(RpcRunner):
    """Executes read-only commands using Foundry's cast CLI with strict whitelisting and timeouts."""

    ALLOWED_SUBCOMMANDS = {"chain-id", "code", "call", "balance", "receipt"}
    FORBIDDEN_FLAGS = {"--private-key", "--ledger", "--trezor", "--interactive", "--broadcast"}
    FORBIDDEN_COMMANDS = {"send", "mktx", "publish", "create2", "wallet"}

    def __init__(self, cast_path: Optional[str] = None, timeout: float = DEFAULT_RPC_TIMEOUT_SECONDS):
        self.cast_path = cast_path or shutil.which("cast") or shutil.which("cast.exe")
        if not self.cast_path:
            raise FileNotFoundError("Foundry 'cast' executable not found on PATH.")
        self.timeout = timeout

    def _execute(self, subcommand: str, cmd_args: List[str]) -> str:
        if subcommand not in self.ALLOWED_SUBCOMMANDS:
            raise PermissionError(f"Security violation: Command '{subcommand}' is not in read-only whitelist.")

        for arg in cmd_args:
            for forbidden in self.FORBIDDEN_FLAGS | self.FORBIDDEN_COMMANDS:
                if forbidden in arg.lower():
                    raise PermissionError(f"Security violation: Forbidden argument or token '{arg}' detected.")

        full_cmd = [self.cast_path, subcommand] + cmd_args
        try:
            res = subprocess.run(full_cmd, capture_output=True, text=True, check=True, timeout=self.timeout)
            return res.stdout.strip()
        except subprocess.TimeoutExpired as e:
            # Bounded execution: convert subprocess timeout into controlled exception with sanitized text
            raise TimeoutError(f"Cast {subcommand} query timed out after {self.timeout}s") from e
        except subprocess.CalledProcessError as e:
            raw_err = e.stderr.strip() or e.stdout.strip() or f"Process exited with code {e.returncode}"
            err_msg = sanitize_text(raw_err, cmd_args)
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

    def get_receipt(self, tx_hash: str, rpc_url: str) -> Dict[str, Any]:
        out = self._execute("receipt", [tx_hash, "--json", "--rpc-url", rpc_url])
        try:
            return json.loads(out)
        except Exception as e:
            raise RuntimeError(f"Failed to parse receipt JSON: {e}") from e


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
                    "rpc_url": redact_rpc_url(self.config.get("base_rpc")),
                    "risk_controller": self.config.get("origin_risk_controller"),
                },
                "reactive_lasna": {
                    "expected_chain_id": REACTIVE_LASNA_CHAIN_ID,
                    "rpc_url": redact_rpc_url(self.config.get("reactive_rpc")),
                    "reactive_contract": self.config.get("reactive_address"),
                    "system_contract": self.config.get("system_contract", DEFAULT_SYSTEM_CONTRACT),
                },
                "unichain_sepolia": {
                    "expected_chain_id": UNICHAIN_SEPOLIA_CHAIN_ID,
                    "rpc_url": redact_rpc_url(self.config.get("unichain_rpc")),
                    "callback_adapter": self.config.get("callback_address"),
                    "borrowing_controller": self.config.get("borrowing_controller_address"),
                    "callback_proxy": self.config.get("callback_proxy", DEFAULT_CALLBACK_PROXY),
                },
            },
        }

    def _calculate_overall_status(self) -> OverallStatus:
        statuses = {r.status for r in self.results}
        if Status.CRITICAL in statuses:
            return OverallStatus.CRITICAL
        if Status.ERROR in statuses:
            return OverallStatus.ERROR
        if Status.WARNING in statuses:
            return OverallStatus.WARNING
        if Status.UNKNOWN in statuses:
            return OverallStatus.UNKNOWN
        return OverallStatus.HEALTHY

    # --- Check Implementations ---

    def _check_networks(self):
        targets = [
            ("Base Sepolia", self.config.get("base_rpc"), BASE_SEPOLIA_CHAIN_ID, "network_base_sepolia"),
            ("Reactive Lasna", self.config.get("reactive_rpc"), REACTIVE_LASNA_CHAIN_ID, "network_reactive_lasna"),
            ("Unichain Sepolia", self.config.get("unichain_rpc"), UNICHAIN_SEPOLIA_CHAIN_ID, "network_unichain_sepolia"),
        ]

        for name, rpc, expected_chain_id, check_id in targets:
            redacted_rpc = redact_rpc_url(rpc)
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
                            evidence={"expected_chain_id": expected_chain_id, "actual_chain_id": actual_id, "rpc_url": redacted_rpc},
                        )
                    )
                else:
                    self.results.append(
                        CheckResult(
                            category=CheckCategory.NETWORK,
                            name=check_id,
                            status=Status.CRITICAL,
                            message=f"{name} chain ID mismatch: expected {expected_chain_id}, received {actual_id}.",
                            evidence={"expected_chain_id": expected_chain_id, "actual_chain_id": actual_id, "rpc_url": redacted_rpc},
                            remediation="Verify RPC endpoint configuration. The node is operating on an incorrect blockchain network.",
                        )
                    )
            except Exception as e:
                sanitized_err = sanitize_text(str(e), [rpc])
                self.results.append(
                    CheckResult(
                        category=CheckCategory.NETWORK,
                        name=check_id,
                        status=Status.ERROR,
                        message=f"{name} RPC unreachable or query failed: {sanitized_err}",
                        evidence={"expected_chain_id": expected_chain_id, "rpc_url": redacted_rpc, "error": sanitized_err},
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
                sanitized_err = sanitize_text(str(e), [rpc])
                self.results.append(
                    CheckResult(
                        category=CheckCategory.DEPLOYMENT,
                        name=check_id,
                        status=Status.ERROR,
                        message=f"Failed to fetch bytecode for {name} at {addr}: {sanitized_err}",
                        evidence={"contract_name": name, "address": addr, "error": sanitized_err},
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
            sanitized_err = sanitize_text(str(e), [rpc])
            self.results.append(
                CheckResult(
                    category=CheckCategory.CONFIGURATION,
                    name=check_id,
                    status=Status.ERROR,
                    message=f"Failed to query {sig} on {contract}: {sanitized_err}",
                    evidence={"contract": contract, "signature": sig, "error": sanitized_err},
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
            sanitized_err = sanitize_text(str(e), [rpc])
            self.results.append(
                CheckResult(
                    category=CheckCategory.CONFIGURATION,
                    name=check_id,
                    status=Status.ERROR,
                    message=f"Failed to query {sig} on {contract}: {sanitized_err}",
                    evidence={"contract": contract, "signature": sig, "error": sanitized_err},
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
                            message=f"Reactive contract has OUTSTANDING DEBT of {debt_val} wei on System Contract. react() execution suspended.",
                            evidence={"system_contract": system_addr, "target": reactive_addr, "debt_wei": debt_val},
                            remediation="Settle debt by executing depositTo(reactiveContract) on the Reactive System Contract (0x8888...8888) with native REACT. Direct transfers without depositTo credit sender balance, not beneficiary.",
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
                sanitized_err = sanitize_text(str(e), [reactive_rpc])
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_reactive_system_debt",
                        status=Status.ERROR,
                        message=f"Failed to query debt on System Contract: {sanitized_err}",
                        evidence={"error": sanitized_err},
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
                            remediation="Replenish reserves by executing depositTo(reactiveContract) on the Reactive System Contract (0x8888...8888) with native REACT.",
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
                sanitized_err = sanitize_text(str(e), [reactive_rpc])
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_reactive_system_reserves",
                        status=Status.UNKNOWN,
                        message=f"Reserves query on System Contract returned error: {sanitized_err}",
                        evidence={"error": sanitized_err},
                    )
                )

            # Query Native Balance of CrossGuardReactive
            try:
                bal_wei = self.runner.get_balance(reactive_addr, reactive_rpc)
                bal_eth = bal_wei / 1e18
                note = "Note: CrossGuardReactive.pay(uint256) reverts with 'Not implemented'. Direct native balance cannot automatically settle debt via pay(); operators must call depositTo on System Contract."
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
                sanitized_err = sanitize_text(str(e), [reactive_rpc])
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_reactive_native_balance",
                        status=Status.ERROR,
                        message=f"Failed to query native balance of CrossGuardReactive: {sanitized_err}",
                        evidence={"error": sanitized_err},
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
                            remediation="Settle callback debt by executing depositTo(callbackContract) on the Callback Proxy (0x9299...7FC4) with native gas token (ETH) on Unichain Sepolia.",
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
                sanitized_err = sanitize_text(str(e), [unichain_rpc])
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_callback_proxy_debt",
                        status=Status.ERROR,
                        message=f"Failed to query debt on Callback Proxy: {sanitized_err}",
                        evidence={"error": sanitized_err},
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
                            remediation="Replenish reserves by executing depositTo(callbackContract) on the Callback Proxy (0x9299...7FC4) with native gas token (ETH) on Unichain Sepolia.",
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
                sanitized_err = sanitize_text(str(e), [unichain_rpc])
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_callback_proxy_reserves",
                        status=Status.UNKNOWN,
                        message=f"Reserves query on Callback Proxy returned error: {sanitized_err}",
                        evidence={"error": sanitized_err},
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
                sanitized_err = sanitize_text(str(e), [unichain_rpc])
                self.results.append(
                    CheckResult(
                        category=CheckCategory.FUNDING_AND_DEBT,
                        name="funding_callback_native_balance",
                        status=Status.ERROR,
                        message=f"Failed to query native balance of CrossGuardCallback: {sanitized_err}",
                        evidence={"error": sanitized_err},
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
            sanitized_err = sanitize_text(str(e), [reactive_rpc])
            self.results.append(
                CheckResult(
                    category=CheckCategory.CALLBACK_GAS,
                    name="callback_gas_limit_check",
                    status=Status.ERROR,
                    message=f"Failed to query callbackGasLimit: {sanitized_err}",
                    evidence={"error": sanitized_err},
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

        # Call getCallbacks with complete documented return signature
        signature = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        try:
            raw_out = self.runner.call(system_addr, signature, [uint_hash_str], reactive_rpc)
            records, decode_err = decode_callback_records(raw_out)

            if decode_err is not None:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CALLBACK_RECORDS,
                        name="callback_record_inspection",
                        status=Status.ERROR,
                        message=f"Failed to decode callback records ABI: {decode_err}",
                        evidence={"tx_hash": tx_hash_str, "raw_response": raw_out, "error": decode_err},
                        remediation="Inspect Reactive System Contract interface and node response.",
                    )
                )
                return

            # Empty array: callbacks pending, unfinalized, or not yet written
            if records is None or len(records) == 0:
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

            # Analyze decoded records
            failed_records = [r for r in records if r.get("error") not in ("0x", "")]
            mismatched_dest_records = [
                r for r in records if r.get("destination_chain_id") != UNICHAIN_SEPOLIA_CHAIN_ID
            ]
            mismatched_reactive_records = []
            if self.config.get("reactive_address"):
                expected_reactive = normalize_address(self.config["reactive_address"])
                mismatched_reactive_records = [
                    r for r in records if normalize_address(r.get("reactive_contract", "")) != expected_reactive
                ]
            unconfirmed_records = [
                r for r in records if r.get("destination_tx_hash") in (0, "0", "0x0", "0x", None)
            ]

            if failed_records:
                first_failed = failed_records[0]
                err_data = first_failed.get("error", "0x")
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CALLBACK_RECORDS,
                        name="callback_record_inspection",
                        status=Status.CRITICAL,
                        message=f"Callback execution recorded as FAILED on destination chain (failed: {len(failed_records)}/{len(records)}). Error data: {err_data}",
                        evidence={
                            "tx_hash": tx_hash_str,
                            "records": records,
                            "failed_records": failed_records,
                            "raw_response": raw_out,
                        },
                        remediation="Inspect error data and destination callback logic (e.g., invalid nonce, gas exhaustion, or revert).",
                    )
                )
            elif mismatched_reactive_records:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CALLBACK_RECORDS,
                        name="callback_record_inspection",
                        status=Status.CRITICAL,
                        message=f"Callback requesting Reactive contract mismatch: expected {normalize_address(self.config.get('reactive_address'))}, got {mismatched_reactive_records[0].get('reactive_contract')}.",
                        evidence={"tx_hash": tx_hash_str, "records": records, "raw_response": raw_out},
                        remediation="Check that the query transaction hash corresponds to the configured CrossGuardReactive contract.",
                    )
                )
            elif mismatched_dest_records:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CALLBACK_RECORDS,
                        name="callback_record_inspection",
                        status=Status.CRITICAL,
                        message=f"Callback destination chain ID mismatch: expected {UNICHAIN_SEPOLIA_CHAIN_ID}, got {mismatched_dest_records[0].get('destination_chain_id')}.",
                        evidence={"tx_hash": tx_hash_str, "records": records, "raw_response": raw_out},
                        remediation="Check destination chain ID configuration in Reactive contract.",
                    )
                )
            elif unconfirmed_records:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CALLBACK_RECORDS,
                        name="callback_record_inspection",
                        status=Status.UNKNOWN,
                        message=f"Callback recorded on Reactive Network, but destination transaction hash is zero (0) ({len(unconfirmed_records)}/{len(records)} record(s)). Destination execution is pending or unconfirmed.",
                        evidence={
                            "tx_hash": tx_hash_str,
                            "records": records,
                            "unconfirmed_records": unconfirmed_records,
                            "state": "PENDING_DESTINATION_TX",
                            "raw_response": raw_out,
                        },
                        remediation="Wait for relayer to submit callback transaction to destination chain (Unichain Sepolia) and destination block confirmation, then query again.",
                    )
                )
            else:
                self.results.append(
                    CheckResult(
                        category=CheckCategory.CALLBACK_RECORDS,
                        name="callback_record_inspection",
                        status=Status.PASS,
                        message=f"Callback execution recorded as SUCCESS on destination chain {UNICHAIN_SEPOLIA_CHAIN_ID} ({len(records)} record(s)).",
                        evidence={"tx_hash": tx_hash_str, "records": records, "raw_response": raw_out},
                    )
                )
        except Exception as e:
            sanitized_err = sanitize_text(str(e), [reactive_rpc])
            self.results.append(
                CheckResult(
                    category=CheckCategory.CALLBACK_RECORDS,
                    name="callback_record_inspection",
                    status=Status.ERROR,
                    message=f"Failed to query getCallbacks(uint256) on System Contract: {sanitized_err}",
                    evidence={"tx_hash": tx_hash_str, "error": sanitized_err},
                    remediation="Check Reactive Lasna RPC health and system contract interface compatibility.",
                )
            )


# --- Recovery Preflight Utilities & Logic ---
def decode_bool(val: Any) -> bool:
    """Decodes boolean representation from cast/RPC output."""
    if isinstance(val, bool):
        return val
    s = str(val).strip().lower()
    if s in ("true", "1", "0x1", "0x01"):
        return True
    return False


def decode_uint(val: Any) -> int:
    """Decodes uint representation from cast/RPC output."""
    if isinstance(val, int):
        return val
    s = str(val).strip()
    if not s or s in ("0x", ""):
        return 0
    try:
        return int(s.split()[0], 0)
    except Exception:
        return 0


def decode_get_latest_callback(raw: str) -> Tuple[int, int, str, int]:
    """
    Decodes return data from getLatestCallback(bytes32):
      (uint256 nonce, uint8 eventType, bytes payload, uint8 retryCount)
    Returns:
      (nonce, eventType, payload_hex, retryCount)
    """
    s = raw.strip()
    if not s or s == "0x":
        return 0, 0, "0x", 0

    # 1. Tuple string format e.g. (1, 1, 0x1234..., 0)
    if "(" in s and ")" in s:
        inner = s[s.find("(") + 1 : s.rfind(")")]
        parts = [p.strip() for p in inner.split(",")]
        if len(parts) >= 4:
            try:
                nonce = int(parts[0], 0)
                event_type = int(parts[1], 0)
                payload = parts[2]
                if not payload.startswith("0x"):
                    payload = "0x" + payload
                retry_count = int(parts[3], 0)
                return nonce, event_type, payload, retry_count
            except Exception:
                pass

    # 2. Whitespace separated e.g. 1 1 0x... 0
    tokens = s.split()
    if len(tokens) >= 4 and tokens[2].startswith("0x"):
        try:
            return int(tokens[0], 0), int(tokens[1], 0), tokens[2], int(tokens[3], 0)
        except Exception:
            pass

    # 3. Raw ABI hex
    if s.startswith("0x") and len(s) >= 258:
        try:
            clean = s[2:]
            nonce = int(clean[0:64], 16)
            event_type = int(clean[64:128], 16)
            payload_offset = int(clean[128:192], 16) * 2
            retry_count = int(clean[192:256], 16)
            payload_len = int(clean[payload_offset : payload_offset + 64], 16) * 2
            payload_hex = "0x" + clean[payload_offset + 64 : payload_offset + 64 + payload_len]
            return nonce, event_type, payload_hex, retry_count
        except Exception:
            pass

    return 0, 0, "0x", 0


def run_recovery_preflight(
    config: Dict[str, Any],
    position_id: str,
    reactive_tx_hash: Optional[str] = None,
    runner: Optional[RpcRunner] = None,
) -> Dict[str, Any]:
    """
    Executes read-only cross-chain recovery preflight diagnostics.
    Evaluates:
      - Origin risk state and position nonce
      - Reactive Lasna stored callback state, latest origin nonce, and destination config
      - Destination borrowing controller state and last processed nonce
      - Reactive System Contract debt and reserves
      - Callback Proxy debt and reserves
      - Optional callback record from Reactive System Contract
    Classifies status into:
      RETRY_ELIGIBLE, RETRY_BLOCKED, RETRY_PENDING, RETRY_ALREADY_SUCCEEDED, RETRY_SUPERSEDED, RETRY_UNKNOWN
    """
    clean_pos = position_id.strip().lower()
    if clean_pos.startswith("0x"):
        clean_pos_hex = clean_pos[2:]
    else:
        clean_pos_hex = clean_pos
    if len(clean_pos_hex) != 64 or not all(c in "0123456789abcdef" for c in clean_pos_hex):
        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "status": RecoveryStatus.RETRY_UNKNOWN.value,
            "position_id": position_id,
            "reason": f"Invalid position ID format: '{position_id}'. Must be a 32-byte hex string (64 hex characters).",
            "remediation": "Provide a valid 32-byte hex position identifier (e.g., 0x1234... or 64 hex characters).",
            "suggested_command": None,
            "execution": "NOT PERFORMED (read-only preflight diagnostic)",
        }
    norm_pos = "0x" + clean_pos_hex

    if runner is None:
        runner = CastRpcRunner(timeout=config.get("timeout", DEFAULT_RPC_TIMEOUT_SECONDS))

    base_rpc = config.get("base_rpc")
    reactive_rpc = config.get("reactive_rpc")
    unichain_rpc = config.get("unichain_rpc")
    origin_controller = config.get("origin_risk_controller")
    reactive_addr = config.get("reactive_address")
    callback_addr = config.get("callback_address")
    borrowing_controller = config.get("borrowing_controller_address")
    system_addr = config.get("system_contract", DEFAULT_SYSTEM_CONTRACT)
    proxy_addr = config.get("callback_proxy", DEFAULT_CALLBACK_PROXY)

    if not (base_rpc and reactive_rpc and unichain_rpc and origin_controller and reactive_addr and callback_addr and borrowing_controller):
        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "status": RecoveryStatus.RETRY_UNKNOWN.value,
            "position_id": norm_pos,
            "reason": "Missing required multi-chain RPC URLs or contract address configuration.",
            "remediation": "Specify all required RPC URLs and contract addresses via flags or environment variables.",
            "suggested_command": None,
            "execution": "NOT PERFORMED (read-only preflight diagnostic)",
        }

    # 1. Read Origin State
    try:
        raw_o_nonce = runner.call(origin_controller, "positionNonce(bytes32)", [norm_pos], base_rpc)
        origin_nonce = decode_uint(raw_o_nonce)
        raw_o_breached = runner.call(origin_controller, "isPositionBreached(bytes32)", [norm_pos], base_rpc)
        origin_breached = decode_bool(raw_o_breached)
    except Exception as e:
        sanitized_err = sanitize_text(str(e), [base_rpc])
        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "status": RecoveryStatus.RETRY_UNKNOWN.value,
            "position_id": norm_pos,
            "reason": f"Failed to query origin state on Base Sepolia: {sanitized_err}",
            "remediation": "Check Base Sepolia RPC connectivity and origin RiskController address.",
            "suggested_command": None,
            "execution": "NOT PERFORMED (read-only preflight diagnostic)",
        }

    # 2. Read Reactive State
    try:
        raw_r_latest_nonce = runner.call(reactive_addr, "latestOriginNonce(bytes32)", [norm_pos], reactive_rpc)
        reactive_latest_origin_nonce = decode_uint(raw_r_latest_nonce)

        raw_r_cb = runner.call(reactive_addr, "getLatestCallback(bytes32)", [norm_pos], reactive_rpc)
        r_cb_nonce, r_cb_type_idx, r_cb_payload, r_cb_retries = decode_get_latest_callback(raw_r_cb)

        type_map = {0: "NONE", 1: "BREACH", 2: "RESOLVED"}
        r_cb_type = type_map.get(r_cb_type_idx, "UNKNOWN")

        raw_dest_cb = runner.call(reactive_addr, "destinationCallback()", [], reactive_rpc)
        dest_callback_configured = normalize_address(raw_dest_cb)

        raw_dest_chain = runner.call(reactive_addr, "destinationChainId()", [], reactive_rpc)
        dest_chain_id_configured = decode_uint(raw_dest_chain)

        raw_gas = runner.call(reactive_addr, "callbackGasLimit()", [], reactive_rpc)
        gas_limit_configured = decode_uint(raw_gas)
    except Exception as e:
        sanitized_err = sanitize_text(str(e), [reactive_rpc])
        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "status": RecoveryStatus.RETRY_UNKNOWN.value,
            "position_id": norm_pos,
            "reason": f"Failed to query Reactive state on Reactive Lasna: {sanitized_err}",
            "remediation": "Check Reactive Lasna RPC connectivity and CrossGuardReactive address.",
            "suggested_command": None,
            "execution": "NOT PERFORMED (read-only preflight diagnostic)",
        }

    # 3. Read Destination State
    try:
        raw_d_nonce = runner.call(borrowing_controller, "lastProcessedNonce(bytes32)", [norm_pos], unichain_rpc)
        dest_last_processed_nonce = decode_uint(raw_d_nonce)

        raw_d_paused = runner.call(borrowing_controller, "isBorrowingPaused(bytes32)", [norm_pos], unichain_rpc)
        dest_paused = decode_bool(raw_d_paused)

        raw_d_breach = runner.call(borrowing_controller, "pausedByRiskBreach(bytes32)", [norm_pos], unichain_rpc)
        dest_paused_by_breach = decode_bool(raw_d_breach)

        raw_d_admin = runner.call(borrowing_controller, "pausedByAdmin(bytes32)", [norm_pos], unichain_rpc)
        dest_paused_by_admin = decode_bool(raw_d_admin)
    except Exception as e:
        sanitized_err = sanitize_text(str(e), [unichain_rpc])
        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "status": RecoveryStatus.RETRY_UNKNOWN.value,
            "position_id": norm_pos,
            "reason": f"Failed to query destination state on Unichain Sepolia: {sanitized_err}",
            "remediation": "Check Unichain Sepolia RPC connectivity and BorrowingController address.",
            "suggested_command": None,
            "execution": "NOT PERFORMED (read-only preflight diagnostic)",
        }

    # 4. Read Economics & Debt
    system_debt = 0
    system_reserves = 0
    proxy_debt = 0
    proxy_reserves = 0
    try:
        system_debt = decode_uint(runner.call(system_addr, "debt(address)", [reactive_addr], reactive_rpc))
        system_reserves = decode_uint(runner.call(system_addr, "reserves(address)", [reactive_addr], reactive_rpc))
        proxy_debt = decode_uint(runner.call(proxy_addr, "debt(address)", [callback_addr], unichain_rpc))
        proxy_reserves = decode_uint(runner.call(proxy_addr, "reserves(address)", [callback_addr], unichain_rpc))
    except Exception:
        pass

    # 5. Read Callback Record if reactive_tx_hash provided
    callback_record_info = None
    if reactive_tx_hash:
        try:
            clean_hash = reactive_tx_hash.strip()
            uint_hash_str = str(int(clean_hash, 16)) if clean_hash.startswith("0x") else str(int(clean_hash))
            sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
            raw_cbs = runner.call(system_addr, sig, [uint_hash_str], reactive_rpc)
            records, _ = decode_callback_records(raw_cbs)
            if records and len(records) > 0:
                callback_record_info = records[0]
            elif records is not None and len(records) == 0:
                callback_record_info = {"empty": True}
        except Exception:
            pass

    # 6. Classification Decision Logic
    status: Optional[RecoveryStatus] = None
    reason: Optional[str] = None
    remediation: Optional[str] = None

    # Already Succeeded
    if dest_last_processed_nonce >= r_cb_nonce and r_cb_nonce > 0:
        status = RecoveryStatus.RETRY_ALREADY_SUCCEEDED
        reason = (
            f"Destination BorrowingController has already processed nonce {dest_last_processed_nonce} "
            f"(callback nonce {r_cb_nonce}). Borrowing paused={dest_paused}."
        )
        remediation = "No recovery action required. Destination state is fully synchronized."
    elif callback_record_info and not callback_record_info.get("empty"):
        dest_tx = callback_record_info.get("destination_tx_hash")
        err_bytes = callback_record_info.get("error", "0x")
        if dest_tx not in (0, "0", "0x0", "0x", None) and err_bytes in ("0x", ""):
            status = RecoveryStatus.RETRY_ALREADY_SUCCEEDED
            reason = f"Callback record confirms destination transaction ({dest_tx}) executed successfully."
            remediation = "No recovery action required. Callback already confirmed on destination."
        elif dest_tx in (0, "0", "0x0", "0x", None):
            status = RecoveryStatus.RETRY_PENDING
            reason = "Callback is recorded on Reactive Lasna but pending delivery by relayer (destinationTxHash is 0)."
            remediation = "Wait for cross-chain relayer to submit transaction to Unichain Sepolia."

    # Pending when callback record array is empty
    if status is None and callback_record_info and callback_record_info.get("empty"):
        status = RecoveryStatus.RETRY_PENDING
        reason = "Callback records are empty or pending finalization on Reactive System Contract."
        remediation = "Allow additional time for Reactive block indexing, then re-check."

    # Superseded by newer origin state
    if status is None:
        if origin_nonce > r_cb_nonce and r_cb_nonce > 0:
            status = RecoveryStatus.RETRY_SUPERSEDED
            reason = (
                f"Stored callback nonce {r_cb_nonce} is superseded by newer origin nonce {origin_nonce}. "
                f"Origin breached={origin_breached}."
            )
            remediation = "Do not retry superseded nonce. Evaluate position on origin to generate latest risk event."

    # Blocked conditions
    if status is None:
        if r_cb_nonce == 0 or not r_cb_payload or r_cb_payload in ("0x", ""):
            status = RecoveryStatus.RETRY_BLOCKED
            reason = f"No callback payload stored for position {norm_pos} in CrossGuardReactive."
            remediation = "Ensure origin risk evaluation has occurred and event was intercepted by Reactive Lasna."
        elif r_cb_retries >= 3:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = f"Retry limit exceeded: maximum 3 retries already consumed ({r_cb_retries}/3)."
            remediation = "Retry budget exhausted. Manual administrative resolution or new origin event required."
        elif system_debt > 0:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = f"CrossGuardReactive has outstanding debt of {system_debt} wei on System Contract."
            remediation = "Settle debt by calling depositTo(reactiveContract) on Reactive System Contract."
        elif proxy_debt > 0:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = f"CrossGuardCallback has outstanding debt of {proxy_debt} wei on Callback Proxy."
            remediation = "Settle debt by calling depositTo(callbackContract) on Callback Proxy on Unichain Sepolia."
        elif dest_callback_configured in (normalize_address("0x0"), "0x0000000000000000000000000000000000000000", ""):
            status = RecoveryStatus.RETRY_BLOCKED
            reason = "Destination callback contract is not configured in CrossGuardReactive."
            remediation = "Owner must call setDestinationConfig with valid destination callback contract address."
        elif dest_chain_id_configured != UNICHAIN_SEPOLIA_CHAIN_ID:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = f"Configured destination chain ID ({dest_chain_id_configured}) is invalid (expected {UNICHAIN_SEPOLIA_CHAIN_ID})."
            remediation = f"Owner must call setDestinationConfig with destination chain ID {UNICHAIN_SEPOLIA_CHAIN_ID}."
        elif gas_limit_configured < MINIMUM_CALLBACK_GAS:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = f"Configured callback gas limit ({gas_limit_configured}) is below minimum required {MINIMUM_CALLBACK_GAS}."
            remediation = f"Owner must call setDestinationConfig to increase callback gas limit to at least {MINIMUM_CALLBACK_GAS}."

    # Eligible
    if status is None:
        status = RecoveryStatus.RETRY_ELIGIBLE
        reason = (
            f"Recovery conditions met: stored callback nonce {r_cb_nonce} ({r_cb_type}) has not been processed "
            f"on destination (dest nonce {dest_last_processed_nonce}), retry budget available ({r_cb_retries}/3), "
            f"and debts are clear."
        )
        remediation = "Safe to initiate retryFailedCallback by authorized contract owner."

    suggested_cmd = None
    if status == RecoveryStatus.RETRY_ELIGIBLE:
        reason_bytes32 = "0x5245434f564552595f44455354494e4154494f4e5f5245564552540000000000"  # RECOVERY_DESTINATION_REVERT
        suggested_cmd = (
            f"cast send {reactive_addr} "
            f'"retryFailedCallback(bytes32,uint256,bytes32)" '
            f"{norm_pos} {r_cb_nonce} {reason_bytes32} "
            f"--rpc-url {redact_rpc_url(reactive_rpc)}"
        )

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "status": status.value,
        "position_id": norm_pos,
        "reason": reason,
        "remediation": remediation,
        "suggested_command": suggested_cmd,
        "origin_state": {
            "risk_controller": origin_controller,
            "nonce": origin_nonce,
            "breached": origin_breached,
        },
        "reactive_state": {
            "reactive_contract": reactive_addr,
            "latest_origin_nonce": reactive_latest_origin_nonce,
            "stored_callback_nonce": r_cb_nonce,
            "event_type": r_cb_type,
            "retry_count": r_cb_retries,
            "max_retries": 3,
            "destination_chain_id": dest_chain_id_configured,
            "destination_callback": dest_callback_configured,
            "callback_gas_limit": gas_limit_configured,
        },
        "destination_state": {
            "borrowing_controller": borrowing_controller,
            "callback_adapter": callback_addr,
            "last_processed_nonce": dest_last_processed_nonce,
            "is_borrowing_paused": dest_paused,
            "paused_by_risk_breach": dest_paused_by_breach,
            "paused_by_admin": dest_paused_by_admin,
        },
        "economics": {
            "system_debt_wei": system_debt,
            "system_reserves_wei": system_reserves,
            "callback_proxy_debt_wei": proxy_debt,
            "callback_proxy_reserves_wei": proxy_reserves,
        },
        "callback_record": callback_record_info,
        "topology": {
            "base_sepolia_rpc": redact_rpc_url(base_rpc),
            "reactive_lasna_rpc": redact_rpc_url(reactive_rpc),
            "unichain_sepolia_rpc": redact_rpc_url(unichain_rpc),
        },
        "execution": "NOT PERFORMED (read-only preflight diagnostic)",
    }


def format_recovery_preflight_terminal(report: Dict[str, Any]) -> str:
    """Formats recovery preflight report into a human-readable terminal output."""
    lines = []
    lines.append("=" * 80)
    lines.append("                 CROSSGUARD RECOVERY PREFLIGHT REPORT")
    lines.append("=" * 80)
    lines.append(f"Timestamp (UTC): {report['timestamp']}")
    lines.append(f"Position ID:     {report['position_id']}")
    lines.append(f"Classification:  [{report['status']}]")
    lines.append(f"Diagnosis:       {report['reason']}")
    lines.append("-" * 80)

    # State overview
    lines.append("CROSS-CHAIN STATE SNAPSHOT:")
    o = report.get("origin_state", {})
    r = report.get("reactive_state", {})
    d = report.get("destination_state", {})
    lines.append(f"  • Origin (Base Sepolia - 84532):")
    lines.append(f"      Nonce: {o.get('nonce')} | Breached: {o.get('breached')}")
    lines.append(f"  • Reactive Lasna (5318007):")
    lines.append(f"      Latest Origin Nonce:    {r.get('latest_origin_nonce')}")
    lines.append(f"      Stored Callback Nonce:  {r.get('stored_callback_nonce')} ({r.get('event_type')})")
    lines.append(f"      Retry Count:            {r.get('retry_count')}/{r.get('max_retries', 3)}")
    lines.append(f"      Destination Callback:   {r.get('destination_callback')}")
    lines.append(f"      Callback Gas Limit:     {r.get('callback_gas_limit')}")
    lines.append(f"  • Destination (Unichain Sepolia - 1301):")
    lines.append(f"      Last Processed Nonce:   {d.get('last_processed_nonce')}")
    lines.append(f"      Borrowing Paused:       {d.get('is_borrowing_paused')}")
    lines.append(f"      Paused By Risk Breach:  {d.get('paused_by_risk_breach')}")
    lines.append(f"      Paused By Admin:        {d.get('paused_by_admin')}")
    lines.append("-" * 80)

    econ = report.get("economics", {})
    lines.append("ECONOMIC PRECONDITIONS:")
    lines.append(f"  • Reactive System Reserves: {econ.get('system_reserves_wei')} wei | Debt: {econ.get('system_debt_wei')} wei")
    lines.append(f"  • Callback Proxy Reserves:   {econ.get('callback_proxy_reserves_wei')} wei | Debt: {econ.get('callback_proxy_debt_wei')} wei")
    lines.append("-" * 80)

    lines.append("REMEDIATION & RECOVERY ACTION:")
    lines.append(f"  Remediation: {report.get('remediation')}")
    if report.get("suggested_command"):
        lines.append("  Suggested Command (execute manually as contract owner):")
        lines.append(f"    {report['suggested_command']}")
    lines.append("\n" + "=" * 80)
    lines.append("SAFETY ADVISORY:")
    lines.append(f"  Execution: {report['execution']}")
    lines.append("  No private keys used, no transactions broadcast, no state mutated.")
    lines.append("=" * 80)
    return "\n".join(lines)


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
    lines.append("  3. CrossGuardReactive.pay() reverts with 'Not implemented'; use depositTo(beneficiary).")
    lines.append("  4. Empty callback records represent pending/unfinalized states, not confirmed failures.")
    lines.append("  5. RPC credentials and query secrets are automatically redacted across all outputs.")
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

    # Recovery Preflight
    parser.add_argument("--recovery-preflight", action="store_true", help="Execute read-only cross-chain recovery preflight diagnostics")
    parser.add_argument("--position-id", default=None, help="Position ID (bytes32 hex) for recovery preflight diagnostics")

    # Optional inspection & timeout
    parser.add_argument("--reactive-tx-hash", default=None, help="Inspect callback record for originating Reactive tx hash")
    parser.add_argument("--timeout", type=float, default=DEFAULT_RPC_TIMEOUT_SECONDS, help="Timeout in seconds for RPC queries")
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
        "timeout": args.timeout,
    }

    try:
        runner = CastRpcRunner(timeout=args.timeout)

        if args.recovery_preflight:
            if not args.position_id:
                err_msg = "Error: --position-id is required when --recovery-preflight is enabled."
                if args.json:
                    print(json.dumps({"error": err_msg, "status": RecoveryStatus.RETRY_UNKNOWN.value}))
                else:
                    print(err_msg, file=sys.stderr)
                sys.exit(1)

            report = run_recovery_preflight(
                config,
                position_id=args.position_id,
                reactive_tx_hash=args.reactive_tx_hash,
                runner=runner,
            )

            if args.json:
                print(json.dumps(report, indent=2))
            else:
                print(format_recovery_preflight_terminal(report))

            sys.exit(compute_recovery_exit_code(report["status"]))

        checker = CrossGuardHealthChecker(config, runner=runner)
        report = checker.run_all_checks()

        if args.json:
            print(json.dumps(report, indent=2))
        else:
            print(format_terminal_report(report))

        sys.exit(compute_exit_code(report["overall_status"]))
    except Exception as e:
        sanitized_err = sanitize_text(str(e))
        if args.json:
            print(json.dumps({"error": sanitized_err, "overall_status": OverallStatus.ERROR.value}))
        else:
            print(f"FATAL ERROR during operational health check: {sanitized_err}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

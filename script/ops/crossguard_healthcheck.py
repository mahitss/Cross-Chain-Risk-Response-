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
ZERO_ADDRESS = "0x" + "0" * 40
UINT256_MAX = (1 << 256) - 1
UINT64_MAX = (1 << 64) - 1
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
    DISPATCH_REQUIRED = "DISPATCH_REQUIRED"
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
    - DISPATCH_REQUIRED: 0
    - RETRY_ELIGIBLE: 0
    - RETRY_ALREADY_SUCCEEDED: 0
    - RETRY_BLOCKED: 1
    - RETRY_PENDING: 1
    - RETRY_SUPERSEDED: 1
    - RETRY_UNKNOWN: 1
    """
    if status in (
        RecoveryStatus.DISPATCH_REQUIRED.value,
        RecoveryStatus.RETRY_ELIGIBLE.value,
        RecoveryStatus.RETRY_ALREADY_SUCCEEDED.value,
    ):
        return 0
    return 1


# --- Address Normalization & Strict Validation Utilities ---
def validate_evm_address(addr: Any, field_name: str = "address") -> str:
    """Strictly validates a 20-byte 0x-prefixed EVM address (40 hex characters)."""
    if addr is None or not isinstance(addr, str):
        raise ValueError(f"Missing or non-string {field_name}: {addr}")
    s = addr.strip().lower()
    if not s.startswith("0x"):
        raise ValueError(f"Invalid {field_name}: missing '0x' prefix in '{addr}'")
    hex_body = s[2:]
    if len(hex_body) != 40 or not all(c in "0123456789abcdef" for c in hex_body):
        raise ValueError(f"Invalid {field_name}: expected 20-byte EVM address (40 hex chars), got '{addr}'")
    return f"0x{hex_body}"


def normalize_address(addr: str) -> str:
    """
    Normalizes an EVM address or 32-byte zero-padded ABI word to 0x-prefixed lowercase 40-char hex.
    For strict 20-byte validation without zero-padding truncated strings, use validate_evm_address().
    """
    clean = addr.strip().lower()
    if clean.startswith("0x"):
        clean = clean[2:]
    if len(clean) == 64 and clean[:24] == "0" * 24 and all(c in "0123456789abcdef" for c in clean):
        clean = clean[24:]
    elif len(clean) == 40 and all(c in "0123456789abcdef" for c in clean):
        pass
    else:
        return f"0x{clean}"
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
        stripped = s
        if stripped.startswith("[") and stripped.endswith("]"):
            stripped = stripped[1:-1].strip()
        tuples = re.findall(r'\(([^()]+)\)', stripped)
        if not tuples:
            return None, "No tuples found in formatted response"
        # Ensure no unexpected non-whitespace/non-comma characters exist outside matched tuples
        remainder = re.sub(r'\(([^()]+)\)', '', stripped).replace(",", "").strip()
        if remainder:
            return None, f"Malformed extra tokens in formatted callback records: '{remainder}'"
        records = []
        for t in tuples:
            parts = [p.strip() for p in t.split(',')]
            if len(parts) != 6:
                return None, f"Expected 6 fields per record, found {len(parts)}"
            try:
                block_number = int(parts[0], 0)
                if block_number < 0 or block_number > UINT256_MAX:
                    return None, f"Invalid blockNumber in callback record: {block_number}"
                reactive_contract = validate_evm_address(parts[1], "callback_record.reactiveContract")
                callback_index = int(parts[2], 0)
                if callback_index < 0 or callback_index > UINT256_MAX:
                    return None, f"Invalid callbackIndex in callback record: {callback_index}"
                dest_chain_id = int(parts[3], 0)
                if dest_chain_id < 0 or dest_chain_id > UINT256_MAX:
                    return None, f"Invalid destinationChainId in callback record: {dest_chain_id}"
                dest_tx_hash = int(parts[4], 0)
                if dest_tx_hash < 0 or dest_tx_hash > UINT256_MAX:
                    return None, f"Invalid destinationTxHash in callback record: {dest_tx_hash}"
                err_raw = parts[5].strip().lower()
                if not err_raw:
                    err = "0x"
                else:
                    if not err_raw.startswith("0x"):
                        err_raw = "0x" + err_raw
                    err = decode_bytes_strict(err_raw, "callback_record.error")
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
            hex_body = s[2:]
            if len(hex_body) % 2 != 0 or not all(c in "0123456789abcdefABCDEF" for c in hex_body):
                return None, "Malformed hex characters or odd length in callback records"
            raw_bytes = bytes.fromhex(hex_body)
            if len(raw_bytes) < 64 or len(raw_bytes) % 32 != 0:
                return None, "Hex response too short or unaligned for dynamic ABI array"
            arr_offset = int.from_bytes(raw_bytes[:32], "big")
            if arr_offset != 32:
                return None, f"Non-canonical array offset {arr_offset} (expected 32)"
            arr_len = int.from_bytes(raw_bytes[32:64], "big")
            if arr_len == 0:
                if len(raw_bytes) != 64:
                    return None, f"Unexpected trailing bytes after empty callback array ({len(raw_bytes)} bytes != 64)"
                return [], None

            elements_start = 64
            if arr_len > (len(raw_bytes) - elements_start) // 256:
                return None, f"Truncated or overflowing callback array length {arr_len}"

            records = []
            expected_rel_offset = arr_len * 32
            for i in range(arr_len):
                elem_offset_loc = elements_start + i * 32
                if elem_offset_loc + 32 > len(raw_bytes):
                    return None, f"Truncated element offset pointer at index {i}"
                elem_offset = int.from_bytes(raw_bytes[elem_offset_loc:elem_offset_loc+32], "big")
                if elem_offset < arr_len * 32:
                    return None, f"Element offset {elem_offset} at index {i} points into array offset table"
                if elem_offset != expected_rel_offset:
                    return None, f"Non-canonical or overlapping element offset {elem_offset} at index {i} (expected {expected_rel_offset})"
                tuple_start = elements_start + elem_offset
                if tuple_start + 224 > len(raw_bytes):
                    return None, f"Truncated tuple head/error length at index {i}"

                block_number = int.from_bytes(raw_bytes[tuple_start:tuple_start+32], "big")
                reactive_contract = decode_address_strict(
                    "0x" + raw_bytes[tuple_start+32:tuple_start+64].hex(),
                    "callback_record.reactiveContract",
                )
                callback_index = int.from_bytes(raw_bytes[tuple_start+64:tuple_start+96], "big")
                dest_chain_id = int.from_bytes(raw_bytes[tuple_start+96:tuple_start+128], "big")
                dest_tx_hash = int.from_bytes(raw_bytes[tuple_start+128:tuple_start+160], "big")
                bytes_offset = int.from_bytes(raw_bytes[tuple_start+160:tuple_start+192], "big")
                if bytes_offset != 192:
                    return None, f"Non-canonical or head-aliasing error bytes offset {bytes_offset} at index {i} (expected 192)"

                bytes_start = tuple_start + bytes_offset
                bytes_len = int.from_bytes(raw_bytes[bytes_start:bytes_start+32], "big")
                data_start = bytes_start + 32
                available_tail = len(raw_bytes) - data_start
                if bytes_len > available_tail:
                    return None, f"Truncated error bytes payload at index {i}"
                err_padded_len = ((bytes_len + 31) // 32) * 32
                if data_start + err_padded_len > len(raw_bytes):
                    return None, f"Truncated error bytes padding at index {i}"
                err_pad = raw_bytes[data_start + bytes_len : data_start + err_padded_len]
                if err_pad != b"\x00" * len(err_pad):
                    return None, f"Non-zero error bytes padding at index {i}"

                err_data = raw_bytes[data_start:data_start+bytes_len]
                err_hex = "0x" + err_data.hex()
                is_pending = (dest_tx_hash == 0)
                is_success = (len(err_data) == 0) and not is_pending
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
                    "error": err_hex,
                    "success": is_success,
                    "is_pending": is_pending,
                })
                expected_rel_offset += 224 + err_padded_len

            if elements_start + expected_rel_offset != len(raw_bytes):
                return None, f"Unexpected trailing bytes after callback records array (expected {elements_start + expected_rel_offset}, got {len(raw_bytes)})"
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

    def get_gas_price(self, rpc_url: str) -> int:
        raise NotImplementedError

    def get_base_fee(self, rpc_url: str) -> int:
        raise NotImplementedError


class CastRpcRunner(RpcRunner):
    """Executes read-only commands using Foundry's cast CLI with strict whitelisting and timeouts."""

    ALLOWED_SUBCOMMANDS = {"chain-id", "code", "call", "balance", "receipt", "gas-price", "base-fee"}
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

    def get_gas_price(self, rpc_url: str) -> int:
        out = self._execute("gas-price", ["--rpc-url", rpc_url])
        return decode_uint_strict(out, "gas-price")

    def get_base_fee(self, rpc_url: str) -> int:
        out = self._execute("base-fee", ["latest", "--rpc-url", rpc_url])
        return decode_uint_strict(out, "base-fee")


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
            if len(actual_norm) != 42 or len(expected_norm) != 42:
                raise ValueError(f"Invalid EVM address length for {sig}: actual='{raw}', expected='{expected}'")
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


# --- Ethereum Keccak-256 (pure Python, zero dependencies, domain separation 0x01) ---
def _rotl64(x: int, n: int) -> int:
    return ((x << n) | (x >> (64 - n))) & 0xFFFFFFFFFFFFFFFF


def _keccak_f1600(state: List[int]) -> None:
    rc = 1
    round_constants = []
    for _ in range(24):
        c = 0
        for j in range(7):
            if rc & 1:
                c ^= 1 << ((1 << j) - 1)
            rc = ((rc << 1) ^ (0x71 if (rc & 0x80) else 0)) & 0xFF
        round_constants.append(c)

    rho_offsets = [0] * 25
    x, y = 1, 0
    for t in range(24):
        rho_offsets[x + 5 * y] = ((t + 1) * (t + 2) // 2) % 64
        x, y = y, (2 * x + 3 * y) % 5

    for rc_val in round_constants:
        c = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rotl64(c[(x + 1) % 5], 1) for x in range(5)]
        for i in range(25):
            state[i] ^= d[i % 5]
        b = [0] * 25
        for x in range(5):
            for y in range(5):
                idx = x + 5 * y
                b[y + 5 * ((2 * x + 3 * y) % 5)] = _rotl64(state[idx], rho_offsets[idx])
        for x in range(5):
            for y in range(5):
                idx = x + 5 * y
                state[idx] = b[idx] ^ ((~b[((x + 1) % 5) + 5 * y]) & b[((x + 2) % 5) + 5 * y])
        state[0] ^= rc_val


def keccak256(data: bytes) -> bytes:
    """Computes Ethereum Keccak-256 digest (0x01 domain separator, NOT NIST SHA3-256 0x06)."""
    rate = 136
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate != 0:
        padded.append(0x00)
    padded[-1] |= 0x80

    state = [0] * 25
    for offset in range(0, len(padded), rate):
        block = padded[offset : offset + rate]
        for i in range(rate // 8):
            state[i] ^= int.from_bytes(block[i * 8 : (i + 1) * 8], "little")
        _keccak_f1600(state)

    return b"".join(state[i].to_bytes(8, "little") for i in range(4))


def keccak256_topic(signature: str) -> str:
    """Computes 0x-prefixed 32-byte Ethereum event signature topic hash."""
    return "0x" + keccak256(signature.encode("utf-8")).hex()


# --- Recovery Preflight Utilities & Logic ---
REACTIVE_BREACH_PROCESSED_TOPIC = keccak256_topic("ReactiveBreachProcessed(bytes32,uint256,uint256,uint256)")
REACTIVE_RESOLVED_PROCESSED_TOPIC = keccak256_topic("ReactiveResolvedProcessed(bytes32,uint256,uint256,uint256)")
CALLBACK_DISPATCH_DEFERRED_TOPIC = keccak256_topic("CallbackDispatchDeferred(bytes32,uint256,uint8,string)")
CALLBACK_DISPATCH_SUBMITTED_TOPIC = keccak256_topic("CallbackDispatchSubmitted(bytes32,uint256,uint8)")
CALLBACK_RETRY_REQUESTED_TOPIC = keccak256_topic("CallbackRetryRequested(bytes32,uint256,uint8,bytes32)")
PENDING_CALLBACK_SUPERSEDED_TOPIC = keccak256_topic("PendingCallbackSuperseded(bytes32,uint256,uint256)")
CALLBACK_REQUEST_TOPIC = keccak256_topic("CallbackRequest(uint256,address,address,uint8,bytes)")
# Legacy / mock-only signature kept solely to identify & reject unverified receipts cleanly (NEVER accepted):
UNSUPPORTED_LEGACY_CALLBACK_REQUESTED_V1_TOPIC = keccak256_topic("CallbackRequestedV1(uint256,address,uint64,bytes)")
SUPPORTED_CALLBACK_VERSIONS = (0,)  # ISystemContract.CallbackVersion.V_1_0

DEFAULT_RESERVE_SAFETY_MULTIPLIER = 2
DEFAULT_REACTIVE_GAS_ESTIMATE = 150_000


def decode_bool(val: Any) -> bool:
    """Decodes boolean representation from cast/RPC output (permissive)."""
    if isinstance(val, bool):
        return val
    s = str(val).strip().lower()
    if s in ("true", "1", "0x1", "0x01"):
        return True
    return False


def decode_bool_strict(val: Any, field_name: str = "bool") -> bool:
    """Decodes boolean representation from cast/RPC output strictly (fail-closed)."""
    if val is None or isinstance(val, list) or isinstance(val, dict):
        raise ValueError(f"Missing or invalid {field_name}: {val}")
    if isinstance(val, bool):
        return val
    s = str(val).strip().lower()
    if s in ("true", "1", "0x1", "0x01"):
        return True
    if s in ("false", "0", "0x0", "0x00"):
        return False
    if s.startswith("0x") and len(s) == 66 and all(c in "0123456789abcdef" for c in s[2:]):
        n = int(s, 16)
        if n == 1:
            return True
        if n == 0:
            return False
    raise ValueError(f"Malformed {field_name} boolean value: '{val}'")


def decode_uint(val: Any) -> int:
    """Decodes uint representation from cast/RPC output (permissive)."""
    if isinstance(val, int) and not isinstance(val, bool):
        return val
    s = str(val).strip()
    if not s or s in ("0x", ""):
        return 0
    try:
        return int(s.split()[0], 0)
    except Exception:
        return 0


def decode_uint_strict(val: Any, field_name: str = "uint") -> int:
    """Decodes unsigned integer from cast/RPC output strictly (fail-closed)."""
    if val is None or isinstance(val, bool) or isinstance(val, list) or isinstance(val, dict):
        raise ValueError(f"Missing or invalid {field_name}: {val}")
    if isinstance(val, int):
        if val < 0:
            raise ValueError(f"Negative {field_name} unsigned integer: {val}")
        return val
    s = str(val).strip()
    if not s or s in ("0x", ""):
        raise ValueError(f"Empty {field_name} string: '{val}'")
    parts = s.split()
    first_token = parts[0].rstrip(",)").lstrip("(")
    if len(parts) > 1 and not parts[1].startswith("["):
        raise ValueError(f"Malformed trailing token in {field_name}: '{val}'")
    try:
        parsed = int(first_token, 0)
    except Exception as e:
        raise ValueError(f"Malformed {field_name} numeric value: '{val}': {e}") from e
    if parsed < 0:
        raise ValueError(f"Negative {field_name} unsigned integer: '{val}'")
    return parsed


def decode_address_strict(val: Any, field_name: str = "address") -> str:
    """Strictly decodes a 20-byte EVM address (or 32-byte left-zero-padded ABI word)."""
    if val is None or not isinstance(val, str):
        raise ValueError(f"Missing or non-string {field_name}: {val}")
    s = val.strip().lower()
    if not s.startswith("0x"):
        raise ValueError(f"Address {field_name} must be 0x-prefixed: '{val}'")
    hex_body = s[2:]
    if not hex_body or not all(c in "0123456789abcdef" for c in hex_body):
        raise ValueError(f"Non-hex characters in {field_name}: '{val}'")
    if len(hex_body) == 40:
        return "0x" + hex_body
    if len(hex_body) == 64:
        if hex_body[:24] != "0" * 24:
            raise ValueError(f"Dirty upper bits in ABI address word for {field_name}: '{val}'")
        return "0x" + hex_body[24:]
    raise ValueError(f"Invalid address length ({len(hex_body)} hex chars) for {field_name}: '{val}'")


def decode_bytes_strict(val: Any, field_name: str = "bytes") -> str:
    """Strictly validates a 0x-prefixed hex byte string."""
    if val is None or not isinstance(val, str):
        raise ValueError(f"Missing or non-string {field_name}: {val}")
    s = val.strip().lower()
    if not s.startswith("0x"):
        raise ValueError(f"Bytes {field_name} must be 0x-prefixed: '{val}'")
    hex_body = s[2:]
    if len(hex_body) % 2 != 0 or not all(c in "0123456789abcdef" for c in hex_body):
        raise ValueError(f"Invalid hex bytes in {field_name}: '{val}'")
    return "0x" + hex_body


def decode_get_latest_callback_strict(raw: str) -> Tuple[int, int, str, int, int]:
    """
    Strictly decodes return data from getLatestCallback(bytes32):
      (uint256 nonce, uint8 eventType, bytes payload, uint8 retryCount, uint8 dispatchStatus)
    Raises ValueError on malformed or truncated data.
    """
    if raw is None or not isinstance(raw, str):
        raise ValueError("Missing getLatestCallback response")
    s = raw.strip()
    if not s:
        raise ValueError("Empty getLatestCallback response")

    if s.startswith("(") and s.endswith(")"):
        parts = [p.strip() for p in s[1:-1].strip().split(",")]
        if len(parts) != 5:
            raise ValueError(f"Expected 5 tuple fields in getLatestCallback, found {len(parts)}: '{s}'")
        return (
            decode_uint_strict(parts[0], "callback.nonce"),
            decode_uint_strict(parts[1], "callback.eventType"),
            decode_bytes_strict(parts[2], "callback.payload"),
            decode_uint_strict(parts[3], "callback.retryCount"),
            decode_uint_strict(parts[4], "callback.dispatchStatus"),
        )

    tokens = s.split()
    if len(tokens) == 5 and tokens[2].lower().startswith("0x"):
        return (
            decode_uint_strict(tokens[0], "callback.nonce"),
            decode_uint_strict(tokens[1], "callback.eventType"),
            decode_bytes_strict(tokens[2], "callback.payload"),
            decode_uint_strict(tokens[3], "callback.retryCount"),
            decode_uint_strict(tokens[4], "callback.dispatchStatus"),
        )

    if s.lower().startswith("0x"):
        hex_body = s[2:]
        if len(hex_body) % 2 != 0 or not all(c in "0123456789abcdefABCDEF" for c in hex_body):
            raise ValueError(f"Invalid hex in getLatestCallback: '{s}'")
        raw_bytes = bytes.fromhex(hex_body)
        if len(raw_bytes) < 192:
            raise ValueError(f"Truncated ABI hex in getLatestCallback ({len(raw_bytes)} bytes < 192)")
        nonce = int.from_bytes(raw_bytes[0:32], "big")
        event_type = int.from_bytes(raw_bytes[32:64], "big")
        payload_offset = int.from_bytes(raw_bytes[64:96], "big")
        retry_count = int.from_bytes(raw_bytes[96:128], "big")
        status = int.from_bytes(raw_bytes[128:160], "big")
        if payload_offset < 160 or payload_offset + 32 > len(raw_bytes):
            raise ValueError(f"Invalid ABI bytes offset {payload_offset} in getLatestCallback")
        payload_len = int.from_bytes(raw_bytes[payload_offset : payload_offset + 32], "big")
        data_start = payload_offset + 32
        if data_start + payload_len > len(raw_bytes):
            raise ValueError(f"Truncated ABI payload bytes in getLatestCallback (need {data_start + payload_len}, got {len(raw_bytes)})")
        payload_hex = "0x" + raw_bytes[data_start : data_start + payload_len].hex()
        return nonce, event_type, payload_hex, retry_count, status

    raise ValueError(f"Unrecognized getLatestCallback response format: '{s}'")


def decode_get_latest_callback(raw: str) -> Tuple[int, int, str, int, int]:
    """
    Decodes return data from getLatestCallback(bytes32):
      (uint256 nonce, uint8 eventType, bytes payload, uint8 retryCount, uint8 dispatchStatus)
    Supports both 5-field M006.1 format and legacy 4-field fallback when called standalone.
    """
    try:
        return decode_get_latest_callback_strict(raw)
    except Exception:
        s = (raw or "").strip()
        if not s or s == "0x":
            return 0, 0, "0x", 0, 0
        if "(" in s and ")" in s:
            inner = s[s.find("(") + 1 : s.rfind(")")]
            parts = [p.strip() for p in inner.split(",")]
            if len(parts) == 4:
                try:
                    payload = parts[2] if parts[2].startswith("0x") else "0x" + parts[2]
                    return int(parts[0], 0), int(parts[1], 0), payload, int(parts[3], 0), 0
                except Exception:
                    pass
        tokens = s.split()
        if len(tokens) == 4 and tokens[2].startswith("0x"):
            try:
                return int(tokens[0], 0), int(tokens[1], 0), tokens[2], int(tokens[3], 0), 0
            except Exception:
                pass
        return 0, 0, "0x", 0, 0


def encode_callback_request_data(
    chain_id: int,
    recipient: str,
    gas_limit: int,
    payload_hex: str,
    version: int = 0,
) -> str:
    """
    ABI-encodes non-indexed CallbackRequest event data:
      (uint8 version, bytes configuration)
    where configuration = abi.encode(CallbackConfiguration_V_1_0(chainId, recipient, gasLimit, payload)).
    """
    norm_recipient = validate_evm_address(recipient, "CallbackConfiguration.recipient")
    clean_payload = decode_bytes_strict(payload_hex, "CallbackConfiguration.payload")[2:]
    payload_bytes = bytes.fromhex(clean_payload)
    padded_payload = payload_bytes + b"\x00" * ((32 - (len(payload_bytes) % 32)) % 32)

    cfg_inner = (
        (32).to_bytes(32, "big")
        + int(chain_id).to_bytes(32, "big")
        + b"\x00" * 12
        + bytes.fromhex(norm_recipient[2:])
        + int(gas_limit).to_bytes(32, "big")
        + (128).to_bytes(32, "big")
        + len(payload_bytes).to_bytes(32, "big")
        + padded_payload
    )
    padded_cfg = cfg_inner + b"\x00" * ((32 - (len(cfg_inner) % 32)) % 32)
    outer = (
        int(version).to_bytes(32, "big")
        + (64).to_bytes(32, "big")
        + len(cfg_inner).to_bytes(32, "big")
        + padded_cfg
    )
    return "0x" + outer.hex()


def decode_callback_request_data_strict(raw_data: Any) -> Dict[str, Any]:
    """
    Strictly decodes and validates canonical CallbackRequest non-indexed ABI data:
      abi.encode(CallbackVersion version, bytes configuration)
    where version == 0 (V_1_0) and configuration == abi.encode(CallbackConfiguration_V_1_0):
      (uint256 chainId, address recipient, uint64 gasLimit, bytes payload).

    Enforces canonical Solidity ABI layout:
      - Exact outer bytes offset (64), 32-byte padded extent, zero outer padding, zero trailing bytes.
      - Exact inner tuple offset (32) and payload offset (128), zero inner padding, zero trailing bytes.
      - Valid uint8 version, clean 20-byte address upper bits, uint64 gasLimit, non-empty payload.
    Raises ValueError on missing, truncated, non-canonical, overlapping, trailing, or malformed data.
    """
    norm_hex = decode_bytes_strict(raw_data, "CallbackRequest.data")
    raw_bytes = bytes.fromhex(norm_hex[2:])
    if len(raw_bytes) < 96:
        raise ValueError(f"CallbackRequest.data missing or too short ({len(raw_bytes)} bytes < 96)")

    # 1. Event version word must be canonical ABI uint8
    version_word = raw_bytes[0:32]
    if version_word[:31] != b"\x00" * 31:
        raise ValueError("Dirty upper bits in CallbackRequest.version")
    version = version_word[31]
    if version not in SUPPORTED_CALLBACK_VERSIONS:
        raise ValueError(f"Unsupported CallbackVersion {version} in CallbackRequest (only V_1_0=0 supported)")

    # 2 & 11. Outer configuration bytes offset must be exact canonical offset 64
    cfg_offset = int.from_bytes(raw_bytes[32:64], "big")
    if cfg_offset < 64:
        raise ValueError(
            f"Invalid configuration bytes offset {cfg_offset} in CallbackRequest.data: points into outer head (< 64)"
        )
    if cfg_offset != 64:
        raise ValueError(
            f"Non-canonical configuration bytes offset {cfg_offset} in CallbackRequest.data: expected exact offset 64"
        )

    # 3, 4, 5, 10. Configuration length, 32-byte padded extent, zero padding, and no trailing bytes
    cfg_start = cfg_offset + 32  # 96
    cfg_len = int.from_bytes(raw_bytes[cfg_offset:cfg_start], "big")
    available_outer = len(raw_bytes) - cfg_start
    if cfg_len > available_outer:
        raise ValueError(
            f"Truncated or overflowing CallbackConfiguration length ({cfg_len} > available {available_outer}) in CallbackRequest.data"
        )
    cfg_padded_len = ((cfg_len + 31) // 32) * 32
    if cfg_start + cfg_padded_len > len(raw_bytes):
        raise ValueError(
            f"Truncated outer dynamic-byte padding in CallbackRequest.data (expected {cfg_start + cfg_padded_len} bytes, got {len(raw_bytes)})"
        )
    outer_pad = raw_bytes[cfg_start + cfg_len : cfg_start + cfg_padded_len]
    if outer_pad != b"\x00" * len(outer_pad):
        raise ValueError("Non-zero outer dynamic-byte padding in CallbackRequest.data")
    if len(raw_bytes) != cfg_start + cfg_padded_len:
        raise ValueError(
            f"Unexpected trailing bytes in CallbackRequest.data (expected {cfg_start + cfg_padded_len} bytes, got {len(raw_bytes)})"
        )
    if cfg_len < 192:
        raise ValueError(
            f"Invalid or truncated CallbackConfiguration length ({cfg_len} < 192) in CallbackRequest.data"
        )

    cfg_bytes = raw_bytes[cfg_start : cfg_start + cfg_len]

    # 6 & 11. Inner configuration wrapper offset from abi.encode(CallbackConfiguration_V_1_0) must be exact 32
    tuple_offset = int.from_bytes(cfg_bytes[0:32], "big")
    if tuple_offset != 32:
        raise ValueError(
            f"Non-canonical outer tuple offset ({tuple_offset}) in CallbackConfiguration_V_1_0: expected 32"
        )

    t_start = 32
    if t_start + 128 > len(cfg_bytes):
        raise ValueError("Truncated CallbackConfiguration_V_1_0 tuple body")

    # 13. Static struct fields with strict ABI bounds
    cfg_chain_id = int.from_bytes(cfg_bytes[t_start : t_start + 32], "big")
    cfg_recipient = decode_address_strict(
        "0x" + cfg_bytes[t_start + 32 : t_start + 64].hex(), "CallbackConfiguration.recipient"
    )
    cfg_gas_limit = int.from_bytes(cfg_bytes[t_start + 64 : t_start + 96], "big")
    if cfg_gas_limit > UINT64_MAX:
        raise ValueError(f"CallbackConfiguration.gasLimit ({cfg_gas_limit}) overflows uint64")

    # 7, 11, 12. Payload offset inside CallbackConfiguration_V_1_0 must be exact canonical offset 128 (relative to t_start)
    payload_offset = int.from_bytes(cfg_bytes[t_start + 96 : t_start + 128], "big")
    if payload_offset < 128:
        raise ValueError(
            f"Invalid payload offset ({payload_offset}) in CallbackConfiguration_V_1_0: points into tuple head (< 128)"
        )
    if payload_offset != 128:
        raise ValueError(
            f"Non-canonical payload offset ({payload_offset}) in CallbackConfiguration_V_1_0: expected canonical offset 128"
        )

    # 8, 9, 10. Payload length, padded extent, zero padding, and no trailing bytes inside configuration
    payload_len_pos = t_start + payload_offset  # 160
    if payload_len_pos + 32 > len(cfg_bytes):
        raise ValueError("Truncated payload length word in CallbackConfiguration_V_1_0")
    payload_len = int.from_bytes(cfg_bytes[payload_len_pos : payload_len_pos + 32], "big")
    payload_start = payload_len_pos + 32  # 192
    if payload_len == 0:
        raise ValueError("Missing or empty payload in CallbackConfiguration_V_1_0 (len=0)")
    available_cfg = len(cfg_bytes) - payload_start
    if payload_len > available_cfg:
        raise ValueError(
            f"Truncated or overflowing payload in CallbackConfiguration_V_1_0 (len={payload_len} > available={available_cfg})"
        )
    payload_padded_len = ((payload_len + 31) // 32) * 32
    if payload_start + payload_padded_len > len(cfg_bytes):
        raise ValueError(
            f"Truncated inner payload dynamic-byte padding in CallbackConfiguration_V_1_0 (expected {payload_start + payload_padded_len} bytes, got {len(cfg_bytes)})"
        )
    inner_pad = cfg_bytes[payload_start + payload_len : payload_start + payload_padded_len]
    if inner_pad != b"\x00" * len(inner_pad):
        raise ValueError("Non-zero inner payload dynamic-byte padding in CallbackConfiguration_V_1_0")
    if len(cfg_bytes) != payload_start + payload_padded_len:
        raise ValueError(
            f"Unexpected trailing bytes inside CallbackConfiguration_V_1_0 (expected {payload_start + payload_padded_len} bytes, got {len(cfg_bytes)})"
        )

    cfg_payload = "0x" + cfg_bytes[payload_start : payload_start + payload_len].hex()

    return {
        "version": version,
        "chain_id": cfg_chain_id,
        "recipient": cfg_recipient,
        "gas_limit": cfg_gas_limit,
        "payload": cfg_payload,
    }


def _require_uint256(val: Any, field_name: str) -> int:
    """Strictly validates a non-bool integer within uint256 bounds [0, 2**256 - 1]."""
    if val is None or isinstance(val, bool) or not isinstance(val, int):
        raise ValueError(f"Missing or non-integer {field_name}: {val}")
    if val < 0 or val > UINT256_MAX:
        raise ValueError(f"Out-of-range uint256 {field_name}: {val}")
    return val


def estimate_callback_fee_wei(
    gas_limit: int,
    p_base_wei: int,
    coeff_per_1000: int,
    extra_gas: int,
    max_charge_gas: Optional[int] = None,
    safety_multiplier: int = DEFAULT_RESERVE_SAFETY_MULTIPLIER,
    settlement_gas_requirement: Optional[int] = None,
) -> Dict[str, Any]:
    """
    Computes conservative Reactive fee estimate using official documented equation:
      fee = p_base * (C / 1000) * (g_used + K)
    where:
      - p_base = max(gas_price, base_fee)
      - C = _gasPriceCoeffPer1000
      - K = _extraGas
      - g_used bounded conservatively by configured gas_limit (while noting forwarded gas < gas_limit)

    IMPORTANT: _maxChargeGas is NEVER added to (g_used + K), multiplied into fee, or compared
    against (g_used + K). _maxChargeGas limits gas available for payment-settlement execution only.
    """
    gas_limit = _require_uint256(gas_limit, "gas_limit")
    p_base_wei = _require_uint256(p_base_wei, "p_base_wei")
    coeff_per_1000 = _require_uint256(coeff_per_1000, "coeff_per_1000")
    extra_gas = _require_uint256(extra_gas, "extra_gas")
    if max_charge_gas is None:
        raise ValueError("Missing _maxChargeGas payment-settlement parameter")
    max_charge_gas = _require_uint256(max_charge_gas, "max_charge_gas")
    safety_multiplier = _require_uint256(safety_multiplier, "safety_multiplier")
    if settlement_gas_requirement is not None:
        settlement_gas_requirement = _require_uint256(settlement_gas_requirement, "settlement_gas_requirement")

    if p_base_wei <= 0 or coeff_per_1000 <= 0 or safety_multiplier < 1:
        raise ValueError(
            f"Invalid economic parameters for fee estimation: gas_limit={gas_limit}, "
            f"p_base_wei={p_base_wei}, coeff={coeff_per_1000}, extra_gas={extra_gas}, "
            f"safety_multiplier={safety_multiplier}"
        )

    accounted_gas = gas_limit + extra_gas
    if accounted_gas > UINT256_MAX:
        raise ValueError(f"Arithmetic overflow in accounted_gas ({gas_limit} + {extra_gas} > uint256)")

    fee_numerator = p_base_wei * coeff_per_1000 * accounted_gas
    if fee_numerator + 999 > UINT256_MAX:
        raise ValueError("Arithmetic overflow in callback fee numerator (> uint256)")
    raw_fee_wei = (fee_numerator + 999) // 1000
    recommended_reserve_wei = raw_fee_wei * safety_multiplier
    if recommended_reserve_wei > UINT256_MAX:
        raise ValueError("Arithmetic overflow in recommended_min_reserve_wei (> uint256)")

    if max_charge_gas == 0:
        settlement_gas_status = "ZERO_SETTLEMENT_GAS"
        settlement_gas_sufficient: Optional[bool] = False
    elif settlement_gas_requirement is not None:
        if max_charge_gas < settlement_gas_requirement:
            settlement_gas_status = "BELOW_REQUIREMENT"
            settlement_gas_sufficient = False
        elif max_charge_gas == settlement_gas_requirement:
            settlement_gas_status = "AT_REQUIREMENT"
            settlement_gas_sufficient = True
        else:
            settlement_gas_status = "ABOVE_REQUIREMENT"
            settlement_gas_sufficient = True
    else:
        settlement_gas_status = "UNVERIFIED_REQUIREMENT"
        settlement_gas_sufficient = None

    return {
        "p_base_wei": p_base_wei,
        "configured_gas_limit": gas_limit,
        "gas_used_upper_bound": gas_limit,
        "extra_gas_overhead": extra_gas,
        "accounted_gas": accounted_gas,
        "max_charge_gas": max_charge_gas,
        "max_charge_gas_role": "Limits gas available for internal payment-settlement execution; NOT part of execution fee formula or execution gas cap.",
        "max_charge_gas_in_fee_formula": False,
        "settlement_gas_requirement": settlement_gas_requirement,
        "settlement_gas_status": settlement_gas_status,
        "settlement_gas_sufficient": settlement_gas_sufficient,
        "effective_forwarded_gas_exact": None,
        "effective_forwarded_gas_warning": (
            f"Configured callbackGasLimit ({gas_limit}) is NOT exact forwarded destination gas: "
            f"Callback Proxy accounts +{extra_gas} extraGas overhead and reserves internal accounting/settlement overhead."
        ),
        "gas_price_coeff_per_1000": coeff_per_1000,
        "estimated_single_callback_fee_wei": raw_fee_wei,
        "safety_multiplier": safety_multiplier,
        "recommended_min_reserve_wei": recommended_reserve_wei,
        "guarantees_future_delivery": False,
        "assumptions": [
            f"p_base = max(gas_price, block.basefee) = {p_base_wei} wei at inspection time.",
            f"Fee formula: p_base * (_gasPriceCoeffPer1000 / 1000) * (g_used + _extraGas) = {raw_fee_wei} wei using upper-bound g_used={gas_limit} and K={extra_gas}.",
            f"_maxChargeGas ({max_charge_gas}) governs gas available for payment settlement only and is excluded from the fee equation.",
            f"Conservative reserve requirement applies safety_multiplier={safety_multiplier}x -> {recommended_reserve_wei} wei.",
            "Exact forwarded destination gas is strictly less than configured callbackGasLimit and cannot be derived from configured limit alone.",
            "Dynamic gas-price spikes and execution variance mean this estimate does NOT guarantee future delivery.",
        ],
    }


def _preflight_error(
    status: RecoveryStatus,
    position_id: Optional[str],
    expected_nonce: Optional[int],
    reactive_tx_hash: Optional[str],
    reason: str,
    remediation: str,
    extra: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    out: Dict[str, Any] = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "status": status.value,
        "safe_to_consider_recovery": status in (RecoveryStatus.DISPATCH_REQUIRED, RecoveryStatus.RETRY_ELIGIBLE),
        "position_id": position_id,
        "expected_nonce": expected_nonce,
        "reactive_tx_hash": reactive_tx_hash,
        "reason": reason,
        "remediation": remediation,
        "suggested_command": None,
        "warnings": [],
        "unsafe_or_unverified_conditions": [],
        "missing_or_unavailable_evidence": [],
        "execution": "NOT PERFORMED (read-only preflight diagnostic)",
    }
    if extra:
        out.update(extra)
    return out


def _validate_receipt_json(receipt: Any) -> Tuple[str, List[Dict[str, Any]]]:
    """Strictly validates receipt JSON structure and returns (status_str, logs)."""
    if receipt is None or not isinstance(receipt, dict):
        raise ValueError("Transaction receipt is missing or not a JSON object")
    if "status" not in receipt:
        raise ValueError("Transaction receipt missing required 'status' field")
    logs = receipt.get("logs")
    if logs is None or not isinstance(logs, list):
        raise ValueError("Transaction receipt missing required 'logs' list")
    for idx, lg in enumerate(logs):
        if not isinstance(lg, dict):
            raise ValueError(f"Malformed receipt log entry at index {idx}")
        if "address" not in lg or not isinstance(lg["address"], str):
            raise ValueError(f"Receipt log {idx} missing valid 'address'")
        topics = lg.get("topics")
        if topics is None or not isinstance(topics, list) or not all(isinstance(t, str) for t in topics):
            raise ValueError(f"Receipt log {idx} missing valid 'topics' array")
    return str(receipt["status"]), logs


def run_recovery_preflight(
    config: Dict[str, Any],
    position_id: Optional[str] = None,
    expected_nonce: Optional[int] = None,
    reactive_tx_hash: Optional[str] = None,
    runner: Optional[RpcRunner] = None,
) -> Dict[str, Any]:
    """
    Executes read-only cross-chain recovery preflight diagnostics.
    Mandatory parameters: position_id, expected_nonce, and reactive_tx_hash.
    Fail-closed on any missing evidence, RPC error, malformed numeric/ABI response,
    contradictory state, or ambiguous callback record correlation.
    Classifies status strictly into:
      DISPATCH_REQUIRED, RETRY_ELIGIBLE, RETRY_BLOCKED, RETRY_PENDING,
      RETRY_ALREADY_SUCCEEDED, RETRY_SUPERSEDED, RETRY_UNKNOWN
    """
    if not position_id or not isinstance(position_id, str):
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, position_id, expected_nonce, reactive_tx_hash,
            "Missing mandatory parameter: --position-id is required for recovery preflight.",
            "Provide --position-id <32-byte-hex>.",
        )

    if expected_nonce is None or isinstance(expected_nonce, bool) or not isinstance(expected_nonce, int) or expected_nonce <= 0:
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, position_id, expected_nonce, reactive_tx_hash,
            f"Missing or invalid mandatory parameter: --expected-nonce must be a positive integer (got {expected_nonce}).",
            "Provide --expected-nonce <int> matching the origin nonce under investigation.",
        )

    if not reactive_tx_hash or not isinstance(reactive_tx_hash, str):
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, position_id, expected_nonce, reactive_tx_hash,
            "Missing mandatory parameter: --reactive-tx-hash is required to inspect receipt evidence and callback records.",
            "Provide --reactive-tx-hash <32-byte-hex> of the originating Reactive Lasna transaction.",
        )

    clean_tx = reactive_tx_hash.strip().lower()
    clean_tx_hex = clean_tx[2:] if clean_tx.startswith("0x") else clean_tx
    if len(clean_tx_hex) != 64 or not all(c in "0123456789abcdef" for c in clean_tx_hex):
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, position_id, expected_nonce, reactive_tx_hash,
            f"Invalid Reactive transaction hash format: '{reactive_tx_hash}'. Must be a 32-byte hex string (64 hex chars).",
            "Provide a valid 32-byte hex Reactive Lasna transaction hash.",
        )
    norm_tx_hash = "0x" + clean_tx_hex

    clean_pos = position_id.strip().lower()
    clean_pos_hex = clean_pos[2:] if clean_pos.startswith("0x") else clean_pos
    if len(clean_pos_hex) != 64 or not all(c in "0123456789abcdef" for c in clean_pos_hex):
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, position_id, expected_nonce, norm_tx_hash,
            f"Invalid position ID format: '{position_id}'. Must be a 32-byte hex string (64 hex characters).",
            "Provide a valid 32-byte hex position identifier (e.g., 0x1234... or 64 hex characters).",
        )
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
    safety_multiplier = config.get("safety_multiplier", DEFAULT_RESERVE_SAFETY_MULTIPLIER)
    require_reactive_reserves = bool(config.get("require_reactive_reserves", False))
    settlement_gas_req_raw = config.get("settlement_gas_requirement")

    if not (base_rpc and reactive_rpc and unichain_rpc and origin_controller and reactive_addr and callback_addr and borrowing_controller):
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            "Missing required multi-chain RPC URLs or contract address configuration.",
            "Specify all required RPC URLs and contract addresses via flags or environment variables.",
        )

    try:
        norm_origin_ctrl = validate_evm_address(origin_controller, "origin_risk_controller")
        norm_reactive_cfg = validate_evm_address(reactive_addr, "reactive_address")
        norm_cb_addr = validate_evm_address(callback_addr, "callback_address")
        norm_borrow_ctrl = validate_evm_address(borrowing_controller, "borrowing_controller_address")
        norm_sys_cfg = validate_evm_address(system_addr, "system_contract")
        norm_proxy_cfg = validate_evm_address(proxy_addr, "callback_proxy")
    except ValueError as e:
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Malformed contract address in recovery configuration: {e}",
            "Provide valid 20-byte 0x-prefixed EVM addresses (40 hex characters).",
        )

    if norm_cb_addr == ZERO_ADDRESS:
        return _preflight_error(
            RecoveryStatus.RETRY_BLOCKED, norm_pos, expected_nonce, norm_tx_hash,
            "Expected CrossGuardCallback address cannot be the zero address.",
            "Specify the deployed non-zero CrossGuardCallback address.",
        )

    try:
        safety_multiplier = _require_uint256(safety_multiplier, "safety_multiplier")
        if safety_multiplier < 1:
            raise ValueError("safety_multiplier must be >= 1")
        settlement_gas_requirement = (
            _require_uint256(settlement_gas_req_raw, "settlement_gas_requirement")
            if settlement_gas_req_raw is not None
            else None
        )
    except ValueError as e:
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Invalid economic configuration parameter: {e}",
            "Provide positive integer economic parameters within uint256 bounds.",
        )

    # 1. Read Origin State (strict & fail-closed)
    try:
        raw_o_nonce = runner.call(origin_controller, "positionNonce(bytes32)", [norm_pos], base_rpc)
        origin_nonce = decode_uint_strict(raw_o_nonce, "origin positionNonce")
        raw_o_breached = runner.call(origin_controller, "isPositionBreached(bytes32)", [norm_pos], base_rpc)
        origin_breached = decode_bool_strict(raw_o_breached, "origin isPositionBreached")
    except Exception as e:
        sanitized_err = sanitize_text(str(e), [base_rpc])
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Failed to query origin state on Base Sepolia: {sanitized_err}",
            "Check Base Sepolia RPC connectivity and origin RiskController address.",
        )

    # 2. Read Reactive State (strict & fail-closed)
    try:
        raw_r_latest_nonce = runner.call(reactive_addr, "latestOriginNonce(bytes32)", [norm_pos], reactive_rpc)
        reactive_latest_origin_nonce = decode_uint_strict(raw_r_latest_nonce, "reactive latestOriginNonce")

        raw_r_cb = runner.call(reactive_addr, "getLatestCallback(bytes32)", [norm_pos], reactive_rpc)
        r_cb_nonce, r_cb_type_idx, r_cb_payload, r_cb_retries, r_cb_status_idx = decode_get_latest_callback_strict(raw_r_cb)

        type_map = {0: "NONE", 1: "BREACH", 2: "RESOLVED"}
        r_cb_type = type_map.get(r_cb_type_idx, "UNKNOWN")

        status_map = {0: "NONE", 1: "PENDING_DISPATCH", 2: "REQUESTED"}
        r_cb_status = status_map.get(r_cb_status_idx, "UNKNOWN")

        raw_dest_cb = runner.call(reactive_addr, "destinationCallback()", [], reactive_rpc)
        dest_callback_configured = decode_address_strict(raw_dest_cb, "reactive destinationCallback")

        raw_dest_chain = runner.call(reactive_addr, "destinationChainId()", [], reactive_rpc)
        dest_chain_id_configured = decode_uint_strict(raw_dest_chain, "reactive destinationChainId")

        raw_gas = runner.call(reactive_addr, "callbackGasLimit()", [], reactive_rpc)
        gas_limit_configured = decode_uint_strict(raw_gas, "reactive callbackGasLimit")
    except Exception as e:
        sanitized_err = sanitize_text(str(e), [reactive_rpc])
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Failed to query Reactive state on Reactive Lasna: {sanitized_err}",
            "Check Reactive Lasna RPC connectivity and CrossGuardReactive address.",
        )

    # 3. Read Destination State (strict & fail-closed)
    try:
        raw_d_nonce = runner.call(borrowing_controller, "lastProcessedNonce(bytes32)", [norm_pos], unichain_rpc)
        dest_last_processed_nonce = decode_uint_strict(raw_d_nonce, "destination lastProcessedNonce")

        raw_d_paused = runner.call(borrowing_controller, "isBorrowingPaused(bytes32)", [norm_pos], unichain_rpc)
        dest_paused = decode_bool_strict(raw_d_paused, "destination isBorrowingPaused")

        raw_d_breach = runner.call(borrowing_controller, "pausedByRiskBreach(bytes32)", [norm_pos], unichain_rpc)
        dest_paused_by_breach = decode_bool_strict(raw_d_breach, "destination pausedByRiskBreach")

        raw_d_admin = runner.call(borrowing_controller, "pausedByAdmin(bytes32)", [norm_pos], unichain_rpc)
        dest_paused_by_admin = decode_bool_strict(raw_d_admin, "destination pausedByAdmin")
    except Exception as e:
        sanitized_err = sanitize_text(str(e), [unichain_rpc])
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Failed to query destination state on Unichain Sepolia: {sanitized_err}",
            "Check Unichain Sepolia RPC connectivity and BorrowingController address.",
        )

    # 4. Network Chain IDs, Bytecodes, and Cross-Contract Wiring Verification
    config_blocker_reason = None
    config_blocker_remediation = None
    try:
        base_cid = decode_uint_strict(runner.get_chain_id(base_rpc), "Base Sepolia chainId")
        reactive_cid = decode_uint_strict(runner.get_chain_id(reactive_rpc), "Reactive Lasna chainId")
        unichain_cid = decode_uint_strict(runner.get_chain_id(unichain_rpc), "Unichain Sepolia chainId")

        if base_cid != BASE_SEPOLIA_CHAIN_ID:
            config_blocker_reason = f"Base Sepolia RPC chain ID mismatch: expected {BASE_SEPOLIA_CHAIN_ID}, got {base_cid}."
            config_blocker_remediation = "Point --base-rpc to Base Sepolia (84532)."
        elif reactive_cid != REACTIVE_LASNA_CHAIN_ID:
            config_blocker_reason = f"Reactive Lasna RPC chain ID mismatch: expected {REACTIVE_LASNA_CHAIN_ID}, got {reactive_cid}."
            config_blocker_remediation = "Point --reactive-rpc to Reactive Lasna (5318007)."
        elif unichain_cid != UNICHAIN_SEPOLIA_CHAIN_ID:
            config_blocker_reason = f"Unichain Sepolia RPC chain ID mismatch: expected {UNICHAIN_SEPOLIA_CHAIN_ID}, got {unichain_cid}."
            config_blocker_remediation = "Point --unichain-rpc to Unichain Sepolia (1301)."

        if not config_blocker_reason:
            for label, addr, rpc_u in (
                ("Origin RiskController", origin_controller, base_rpc),
                ("CrossGuardReactive", reactive_addr, reactive_rpc),
                ("CrossGuardCallback", callback_addr, unichain_rpc),
                ("BorrowingController", borrowing_controller, unichain_rpc),
                ("Callback Proxy", proxy_addr, unichain_rpc),
            ):
                code = runner.get_code(addr, rpc_u)
                if not isinstance(code, str) or code.strip().lower() in ("", "0x", "0x0"):
                    config_blocker_reason = f"{label} at {addr} has no deployed bytecode."
                    config_blocker_remediation = f"Verify {label} address and deployment on target network."
                    break

        if not config_blocker_reason:
            r_origin_cid = decode_uint_strict(runner.call(reactive_addr, "originChainId()", [], reactive_rpc), "reactive originChainId")
            r_origin_ctrl = decode_address_strict(runner.call(reactive_addr, "originRiskController()", [], reactive_rpc), "reactive originRiskController")
            r_sys = decode_address_strict(runner.call(reactive_addr, "systemContract()", [], reactive_rpc), "reactive systemContract")
            cb_proxy = decode_address_strict(runner.call(callback_addr, "callbackProxy()", [], unichain_rpc), "callback callbackProxy")
            cb_sender = decode_address_strict(runner.call(callback_addr, "authorizedReactiveSender()", [], unichain_rpc), "callback authorizedReactiveSender")
            cb_borrow = decode_address_strict(runner.call(callback_addr, "borrowingController()", [], unichain_rpc), "callback borrowingController")
            bc_adapter = decode_address_strict(runner.call(borrowing_controller, "callbackAdapter()", [], unichain_rpc), "borrowingController callbackAdapter")

            if r_origin_cid != BASE_SEPOLIA_CHAIN_ID:
                config_blocker_reason = f"CrossGuardReactive originChainId ({r_origin_cid}) != {BASE_SEPOLIA_CHAIN_ID}."
                config_blocker_remediation = "Verify CrossGuardReactive deployment parameters."
            elif r_origin_ctrl != norm_origin_ctrl:
                config_blocker_reason = f"CrossGuardReactive originRiskController mismatch: expected {norm_origin_ctrl}, got {r_origin_ctrl}."
                config_blocker_remediation = "Verify RiskController / CrossGuardReactive topology parity."
            elif r_sys != norm_sys_cfg:
                config_blocker_reason = f"CrossGuardReactive systemContract mismatch: expected {norm_sys_cfg}, got {r_sys}."
                config_blocker_remediation = "Verify Omni System Contract address wiring."
            elif cb_proxy != norm_proxy_cfg:
                config_blocker_reason = f"CrossGuardCallback callbackProxy mismatch: expected {norm_proxy_cfg}, got {cb_proxy}."
                config_blocker_remediation = "Verify Unichain Sepolia Callback Proxy address wiring."
            elif cb_sender != norm_reactive_cfg:
                config_blocker_reason = f"CrossGuardCallback authorizedReactiveSender mismatch: expected {norm_reactive_cfg}, got {cb_sender}."
                config_blocker_remediation = "Owner must call setAuthorizedReactiveSender on CrossGuardCallback."
            elif cb_borrow != norm_borrow_ctrl:
                config_blocker_reason = f"CrossGuardCallback borrowingController mismatch: expected {norm_borrow_ctrl}, got {cb_borrow}."
                config_blocker_remediation = "Owner must call setBorrowingController on CrossGuardCallback."
            elif bc_adapter != norm_cb_addr:
                config_blocker_reason = f"BorrowingController callbackAdapter mismatch: expected {norm_cb_addr}, got {bc_adapter}."
                config_blocker_remediation = "Owner must call setCallbackAdapter on BorrowingController."
    except Exception as e:
        sanitized_err = sanitize_text(str(e), [base_rpc, reactive_rpc, unichain_rpc])
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Failed to verify cross-chain topology or wiring configuration: {sanitized_err}",
            "Check RPC connectivity across all three networks and verify contract ABIs.",
        )

    # 5. Read Economics, Debt & Fee Environment (strict & fail-closed)
    try:
        system_debt = decode_uint_strict(runner.call(system_addr, "debt(address)", [reactive_addr], reactive_rpc), "system debt")
        system_reserves = decode_uint_strict(runner.call(system_addr, "reserves(address)", [reactive_addr], reactive_rpc), "system reserves")
        system_coeff = decode_uint_strict(runner.call(system_addr, "_gasPriceCoeffPer1000()", [], reactive_rpc), "system _gasPriceCoeffPer1000")
        system_extra_gas = decode_uint_strict(runner.call(system_addr, "_extraGas()", [], reactive_rpc), "system _extraGas")
        system_max_gas = decode_uint_strict(runner.call(system_addr, "_maxChargeGas()", [], reactive_rpc), "system _maxChargeGas")
        reactive_gas_price = decode_uint_strict(runner.get_gas_price(reactive_rpc), "Reactive Lasna gas price")
        reactive_base_fee = decode_uint_strict(runner.get_base_fee(reactive_rpc), "Reactive Lasna base fee")
        p_base_reactive = max(reactive_gas_price, reactive_base_fee)

        proxy_debt = decode_uint_strict(runner.call(proxy_addr, "debt(address)", [callback_addr], unichain_rpc), "proxy debt")
        proxy_reserves = decode_uint_strict(runner.call(proxy_addr, "reserves(address)", [callback_addr], unichain_rpc), "proxy reserves")
        proxy_coeff = decode_uint_strict(runner.call(proxy_addr, "_gasPriceCoeffPer1000()", [], unichain_rpc), "proxy _gasPriceCoeffPer1000")
        proxy_extra_gas = decode_uint_strict(runner.call(proxy_addr, "_extraGas()", [], unichain_rpc), "proxy _extraGas")
        proxy_max_gas = decode_uint_strict(runner.call(proxy_addr, "_maxChargeGas()", [], unichain_rpc), "proxy _maxChargeGas")
        dest_gas_price = decode_uint_strict(runner.get_gas_price(unichain_rpc), "Unichain Sepolia gas price")
        dest_base_fee = decode_uint_strict(runner.get_base_fee(unichain_rpc), "Unichain Sepolia base fee")
        p_base_dest = max(dest_gas_price, dest_base_fee)

        if p_base_reactive <= 0 or system_coeff <= 0:
            raise ValueError(f"Unavailable or zero Reactive fee environment (p_base={p_base_reactive}, coeff={system_coeff})")
        if p_base_dest <= 0 or proxy_coeff <= 0:
            raise ValueError(f"Unavailable or zero Destination fee environment (p_base={p_base_dest}, coeff={proxy_coeff})")

        reactive_gas_budget = config.get("reactive_gas_estimate", DEFAULT_REACTIVE_GAS_ESTIMATE)
        system_fee_estimate = estimate_callback_fee_wei(
            gas_limit=reactive_gas_budget,
            p_base_wei=p_base_reactive,
            coeff_per_1000=system_coeff,
            extra_gas=system_extra_gas,
            max_charge_gas=system_max_gas,
            safety_multiplier=safety_multiplier,
            settlement_gas_requirement=settlement_gas_requirement,
        )
        proxy_fee_estimate = estimate_callback_fee_wei(
            gas_limit=gas_limit_configured,
            p_base_wei=p_base_dest,
            coeff_per_1000=proxy_coeff,
            extra_gas=proxy_extra_gas,
            max_charge_gas=proxy_max_gas,
            safety_multiplier=safety_multiplier,
            settlement_gas_requirement=settlement_gas_requirement,
        )
    except Exception as e:
        sanitized_err = sanitize_text(str(e), [reactive_rpc, unichain_rpc])
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Failed to query or validate economic/fee parameters: {sanitized_err}",
            "Verify System Contract, Callback Proxy fee parameters, and RPC gas-price/base-fee availability.",
        )

    warnings: List[str] = []
    unsafe_conditions: List[str] = [proxy_fee_estimate["effective_forwarded_gas_warning"]]
    missing_evidence: List[str] = [
        "Official 6-field getCallbacks(uint256) schema omits destination recipient address and origin nonce.",
        "Live SystemContract.requestCallbackV_1_0 enforcement on indebted Reactive contracts cannot be established offline.",
    ]
    if proxy_fee_estimate["settlement_gas_sufficient"] is None:
        msg = (
            f"Callback Proxy _maxChargeGas={proxy_max_gas} limits payment-settlement gas, "
            "but exact proxy/recipient settlement gas requirement is unverified offline."
        )
        unsafe_conditions.append(msg)
        missing_evidence.append("Exact destination Callback Proxy + receiver pay() settlement gas requirement.")
    elif proxy_fee_estimate["settlement_gas_sufficient"] is False:
        unsafe_conditions.append(
            f"Callback Proxy _maxChargeGas ({proxy_max_gas}) is below settlement gas requirement ({settlement_gas_requirement})."
        )

    if system_debt > 0:
        w = (
            f"REACTIVE_PATH_WARNING: CrossGuardReactive has {system_debt} wei debt on System Contract. "
            "Automated react() processing is suspended until depositTo(reactiveContract) clears debt; "
            "note owner-triggered dispatchPendingCallback/retryFailedCallback uses EOA tx gas on Reactive Lasna "
            "and is evaluated separately from destination Callback Proxy delivery funding."
        )
        warnings.append(w)
        unsafe_conditions.append(w)
    if system_reserves == 0 or system_reserves < system_fee_estimate["recommended_min_reserve_wei"]:
        w = (
            f"REACTIVE_PATH_WARNING: Reactive System Contract reserves ({system_reserves} wei) are below conservative "
            f"estimate ({system_fee_estimate['recommended_min_reserve_wei']} wei) for automated react() continuity; "
            "destination Callback Proxy delivery path uses separate Unichain ETH reserves."
        )
        warnings.append(w)
        unsafe_conditions.append(w)

    # 6. Inspect Reactive Transaction Receipt & Strict Log Correlation
    try:
        receipt = runner.get_receipt(norm_tx_hash, reactive_rpc)
        rec_status_str, logs = _validate_receipt_json(receipt)
    except Exception as e:
        sanitized_err = sanitize_text(str(e), [reactive_rpc])
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Failed to retrieve or validate transaction receipt for {norm_tx_hash}: {sanitized_err}",
            "Verify Reactive Lasna RPC connectivity and ensure transaction hash has been mined.",
        )

    if rec_status_str.lower() in ("0", "0x0", "false"):
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Reactive transaction {norm_tx_hash} reverted on Reactive Lasna (receipt status {rec_status_str}).",
            "Inspect Reactive transaction trace; reverted Reactive transactions never dispatch callbacks.",
        )

    cg_topics = {
        REACTIVE_BREACH_PROCESSED_TOPIC: 1,
        REACTIVE_RESOLVED_PROCESSED_TOPIC: 2,
        CALLBACK_DISPATCH_DEFERRED_TOPIC: None,
        CALLBACK_DISPATCH_SUBMITTED_TOPIC: None,
        CALLBACK_RETRY_REQUESTED_TOPIC: None,
    }

    matching_cg_logs = []
    for lg in logs:
        lg_addr = normalize_address(lg["address"])
        lg_topics = lg["topics"]
        if not lg_topics:
            continue
        t0 = lg_topics[0].lower()
        if t0 in cg_topics and lg_addr == norm_reactive_cfg:
            matching_cg_logs.append(lg)

    if len(matching_cg_logs) == 0:
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Receipt for {norm_tx_hash} does not contain any CrossGuardReactive operational event emitted by {norm_reactive_cfg}.",
            "Verify transaction hash and configured CrossGuardReactive address.",
        )

    if len(matching_cg_logs) > 1:
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Receipt for {norm_tx_hash} contains {len(matching_cg_logs)} conflicting CrossGuardReactive operational events; cannot associate unambiguously.",
            "Manual receipt audit required for multi-event transactions.",
        )

    cg_log = matching_cg_logs[0]
    cg_topics_list = cg_log["topics"]
    cg_t0 = cg_topics_list[0].lower()
    if len(cg_topics_list) < 3:
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"CrossGuardReactive event log in {norm_tx_hash} has truncated indexed topics.",
            "Inspect transaction log encoding.",
        )

    receipt_pos_id = cg_topics_list[1].lower()
    try:
        receipt_nonce = int(cg_topics_list[2], 16)
    except Exception:
        receipt_nonce = None

    if receipt_pos_id != norm_pos:
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Receipt position ID ({receipt_pos_id}) does not match expected position ID ({norm_pos}).",
            "Provide the correct --position-id belonging to this Reactive transaction.",
        )

    if receipt_nonce != expected_nonce:
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Receipt event nonce ({receipt_nonce}) does not match expected nonce ({expected_nonce}).",
            "Provide the exact --expected-nonce emitted in this Reactive transaction.",
        )

    is_deferred_event = (cg_t0 == CALLBACK_DISPATCH_DEFERRED_TOPIC)
    receipt_event_type = cg_topics[cg_t0]
    if cg_t0 in (CALLBACK_DISPATCH_DEFERRED_TOPIC, CALLBACK_DISPATCH_SUBMITTED_TOPIC):
        if len(cg_topics_list) < 4:
            return _preflight_error(
                RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                f"Dispatch event log in {norm_tx_hash} missing indexed eventType topic.",
                "Inspect transaction receipt ABI.",
            )
        try:
            receipt_event_type = int(cg_topics_list[3], 16)
        except Exception:
            return _preflight_error(
                RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                f"Malformed indexed eventType topic in {norm_tx_hash}.",
                "Inspect transaction receipt ABI.",
            )

    # Verify authoritative Omni System Contract CallbackRequest log (no legacy CallbackRequestedV1 fallback)
    system_cb_requests = []
    legacy_unverified_requests = []
    foreign_cb_requests = []
    for lg in logs:
        lg_topics = lg["topics"]
        if not lg_topics:
            continue
        t0 = lg_topics[0].lower()
        lg_sender = normalize_address(lg["address"])
        if t0 == CALLBACK_REQUEST_TOPIC:
            if lg_sender == norm_sys_cfg:
                system_cb_requests.append(lg)
            else:
                foreign_cb_requests.append(lg_sender)
        elif t0 == UNSUPPORTED_LEGACY_CALLBACK_REQUESTED_V1_TOPIC and lg_sender == norm_sys_cfg:
            legacy_unverified_requests.append(lg)

    historical_cb_recipient: Optional[str] = None
    historical_cb_request: Optional[Dict[str, Any]] = None

    if is_deferred_event:
        if system_cb_requests or legacy_unverified_requests:
            return _preflight_error(
                RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                "Contradictory receipt evidence: CallbackDispatchDeferred emitted alongside System Contract callback request log(s).",
                "Audit transaction trace for inconsistent execution state.",
            )
    else:
        if len(system_cb_requests) == 0:
            if legacy_unverified_requests:
                return _preflight_error(
                    RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                    "Receipt contains unverified legacy/mock CallbackRequestedV1 event without modern Omni CallbackRequest(uint256,address,address,uint8,bytes); rejected fail-closed.",
                    "Supply a transaction receipt emitted by the supported Omni System Contract CallbackRequest ABI.",
                )
            if foreign_cb_requests:
                return _preflight_error(
                    RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                    f"CallbackRequest log emitted by unexpected contract(s) {foreign_cb_requests} instead of configured System Contract {norm_sys_cfg}.",
                    "Verify Omni System Contract address configuration.",
                )
            return _preflight_error(
                RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                f"Receipt for {norm_tx_hash} does not contain a CallbackRequest event from Omni System Contract {norm_sys_cfg}.",
                "Inspect transaction trace to confirm whether requestCallbackV_1_0 executed.",
            )
        if len(system_cb_requests) > 1:
            return _preflight_error(
                RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                f"Receipt contains {len(system_cb_requests)} CallbackRequest logs; cannot unambiguously correlate single request.",
                "Perform manual multi-callback receipt correlation.",
            )

        req_log = system_cb_requests[0]
        req_topics = req_log["topics"]
        if len(req_topics) != 4:
            return _preflight_error(
                RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                f"CallbackRequest log must have exactly 4 topics (chainId/sender/recipient); found {len(req_topics)}.",
                "Verify Omni System Contract ABI.",
            )
        try:
            norm_t1 = decode_bytes_strict(req_topics[1], "CallbackRequest.chainId")
            if len(norm_t1) != 66:
                raise ValueError(f"Expected 32-byte indexed chainId topic (66 chars), got '{req_topics[1]}'")
            req_chain_id = int(norm_t1, 16)
            req_sender = decode_address_strict(req_topics[2], "CallbackRequest.sender")
            req_recipient = decode_address_strict(req_topics[3], "CallbackRequest.recipient")
        except Exception as e:
            return _preflight_error(
                RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                f"Malformed indexed fields in CallbackRequest log: {e}",
                "Inspect System Contract receipt event logs.",
            )

        try:
            decoded_req_data = decode_callback_request_data_strict(req_log.get("data"))
        except Exception as e:
            return _preflight_error(
                RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                f"Missing or malformed non-indexed CallbackRequest event data: {e}",
                "Inspect System Contract CallbackRequest (CallbackVersion, CallbackConfiguration_V_1_0) event data.",
            )

        if req_sender != norm_reactive_cfg:
            return _preflight_error(
                RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                f"CallbackRequest sender ({req_sender}) does not match CrossGuardReactive ({norm_reactive_cfg}).",
                "Verify Reactive contract address and transaction hash.",
            )
        if req_chain_id != UNICHAIN_SEPOLIA_CHAIN_ID:
            return _preflight_error(
                RecoveryStatus.RETRY_BLOCKED, norm_pos, expected_nonce, norm_tx_hash,
                f"CallbackRequest targets unsupported destination chain ID {req_chain_id} (expected {UNICHAIN_SEPOLIA_CHAIN_ID}).",
                "Update CrossGuardReactive destinationChainId to 1301 before retrying.",
            )
        if decoded_req_data["chain_id"] != req_chain_id:
            return _preflight_error(
                RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                f"CallbackRequest configuration chainId ({decoded_req_data['chain_id']}) contradicts indexed chainId ({req_chain_id}).",
                "Inspect System Contract receipt event encoding.",
            )
        if decoded_req_data["recipient"] != req_recipient:
            return _preflight_error(
                RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                f"CallbackRequest configuration recipient ({decoded_req_data['recipient']}) contradicts indexed recipient ({req_recipient}).",
                "Inspect System Contract receipt event encoding.",
            )
        if decoded_req_data["gas_limit"] < MINIMUM_CALLBACK_GAS:
            return _preflight_error(
                RecoveryStatus.RETRY_BLOCKED, norm_pos, expected_nonce, norm_tx_hash,
                f"CallbackRequest configuration gasLimit ({decoded_req_data['gas_limit']}) is below minimum required {MINIMUM_CALLBACK_GAS}.",
                "Ensure CrossGuardReactive callbackGasLimit >= 100,000 before dispatching or retrying.",
            )
        if r_cb_nonce == expected_nonce and r_cb_payload not in ("0x", ""):
            try:
                norm_stored_payload = decode_bytes_strict(r_cb_payload, "latestCallback.payload")
            except Exception as e:
                return _preflight_error(
                    RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                    f"Malformed stored callback payload: {e}",
                    "Inspect CrossGuardReactive latestCallback storage.",
                )
            if decoded_req_data["payload"] != norm_stored_payload:
                return _preflight_error(
                    RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                    "CallbackRequest configuration payload does not match CrossGuardReactive stored callback payload.",
                    "Verify transaction hash matches the callback payload under recovery.",
                )

        historical_cb_recipient = req_recipient
        historical_cb_request = decoded_req_data

    # 3-Way Destination Callback Drift Comparison
    expected_matches_current = (dest_callback_configured == norm_cb_addr)
    expected_matches_historical = (
        (historical_cb_recipient == norm_cb_addr) if historical_cb_recipient is not None else None
    )
    historical_matches_current = (
        (historical_cb_recipient == dest_callback_configured) if historical_cb_recipient is not None else None
    )
    all_recipients_match = (
        expected_matches_current
        and (True if historical_cb_recipient is None else (bool(expected_matches_historical) and bool(historical_matches_current)))
    )
    failed_comparisons: List[str] = []
    if not expected_matches_current:
        failed_comparisons.append("expected_callback != current_destination_callback")
    if historical_cb_recipient is not None and not expected_matches_historical:
        failed_comparisons.append("expected_callback != historical_callback_request_recipient")
    if historical_cb_recipient is not None and not historical_matches_current:
        failed_comparisons.append("historical_callback_request_recipient != current_destination_callback")

    config_comparison = {
        "expected_callback": norm_cb_addr,
        "historical_callback_request_recipient": historical_cb_recipient,
        "current_destination_callback": dest_callback_configured,
        "expected_matches_current": expected_matches_current,
        "expected_matches_historical": expected_matches_historical,
        "historical_matches_current": historical_matches_current,
        "all_recipients_match": all_recipients_match,
        "drift_detected": (not all_recipients_match),
        "failed_comparisons": failed_comparisons,
        "migration_policy": (
            "Normal recovery rejects recipient mismatches and never auto-adopts a new callback address; "
            "an operator must complete an explicitly reviewed configuration migration."
        ),
    }

    if historical_cb_recipient is not None and historical_cb_recipient != norm_cb_addr and dest_callback_configured == norm_cb_addr:
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"CallbackRequest recipient ({historical_cb_recipient}) does not match configured CrossGuardCallback ({norm_cb_addr}).",
            "Verify CrossGuardCallback address wiring or complete a reviewed configuration migration.",
            extra={
                "configuration_comparison": config_comparison,
                "warnings": warnings,
                "unsafe_or_unverified_conditions": unsafe_conditions,
                "missing_or_unavailable_evidence": missing_evidence,
            },
        )

    # 7. Read and Correlate Official Callback Records
    records = []
    callback_record_info = None
    try:
        uint_hash_str = str(int(norm_tx_hash, 16))
        sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
        raw_cbs = runner.call(norm_sys_cfg, sig, [uint_hash_str], reactive_rpc)
        records, parse_err = decode_callback_records(raw_cbs)
        if parse_err:
            return _preflight_error(
                RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
                f"Failed to parse callback records ABI: {parse_err}",
                "Inspect System Contract getCallbacks ABI compatibility.",
            )
    except Exception as e:
        sanitized_err = sanitize_text(str(e), [reactive_rpc])
        return _preflight_error(
            RecoveryStatus.RETRY_UNKNOWN, norm_pos, expected_nonce, norm_tx_hash,
            f"Failed to query getCallbacks for {norm_tx_hash}: {sanitized_err}",
            "Check Reactive Lasna RPC connectivity.",
        )

    # 8. Classification Decision Engine
    status: Optional[RecoveryStatus] = None
    reason: Optional[str] = None
    remediation: Optional[str] = None
    matched_record_count = 0

    # First check Superseded across origin/reactive before contradiction checks
    if origin_nonce > expected_nonce or reactive_latest_origin_nonce > expected_nonce or (r_cb_nonce > expected_nonce):
        status = RecoveryStatus.RETRY_SUPERSEDED
        reason = (
            f"Expected nonce {expected_nonce} is superseded by newer state "
            f"(origin nonce {origin_nonce}, reactive latest nonce {reactive_latest_origin_nonce}, stored callback nonce {r_cb_nonce})."
        )
        remediation = "Do not dispatch or retry superseded nonce. Inspect the latest nonce instead."

    # Next verify no backward state contradiction
    if status is None:
        if origin_nonce < expected_nonce:
            status = RecoveryStatus.RETRY_UNKNOWN
            reason = f"Contradictory state: Origin positionNonce ({origin_nonce}) is lower than expected nonce ({expected_nonce})."
            remediation = "Verify Base Sepolia origin contract address and RPC sync state."
        elif reactive_latest_origin_nonce < expected_nonce:
            status = RecoveryStatus.RETRY_UNKNOWN
            reason = f"Contradictory state: Reactive latestOriginNonce ({reactive_latest_origin_nonce}) is lower than expected nonce ({expected_nonce})."
            remediation = "Verify CrossGuardReactive state synchronization and address."

    # Next check deferred dispatch path (requires expected_callback == current_destination_callback)
    if status is None and is_deferred_event:
        if r_cb_nonce == 0 or r_cb_payload in ("0x", ""):
            status = RecoveryStatus.RETRY_BLOCKED
            reason = f"No callback payload stored for position {norm_pos} in CrossGuardReactive."
            remediation = "Ensure valid origin risk evaluation was accepted by CrossGuardReactive."
        elif r_cb_nonce != expected_nonce:
            status = RecoveryStatus.RETRY_UNKNOWN
            reason = f"Stored callback nonce ({r_cb_nonce}) does not match expected nonce ({expected_nonce})."
            remediation = "Inspect CrossGuardReactive latestCallback state."
        elif receipt_event_type is not None and receipt_event_type != r_cb_type_idx:
            status = RecoveryStatus.RETRY_UNKNOWN
            reason = f"Receipt eventType ({receipt_event_type}) contradicts stored callback eventType ({r_cb_type_idx})."
            remediation = "Verify receipt matches current stored callback state."
        elif (r_cb_type_idx == 1 and not origin_breached) or (r_cb_type_idx == 2 and origin_breached):
            status = RecoveryStatus.RETRY_UNKNOWN
            reason = f"Origin breached state ({origin_breached}) contradicts stored callback eventType ({r_cb_type}) at nonce {expected_nonce}."
            remediation = "Re-query origin RiskController and Reactive state consistency."
        elif r_cb_status_idx != 1:
            status = RecoveryStatus.RETRY_UNKNOWN
            reason = f"Receipt recorded CallbackDispatchDeferred, but stored dispatch status is {r_cb_status} (expected PENDING_DISPATCH)."
            remediation = "Inspect newer dispatch transactions for this position and nonce."
        elif dest_callback_configured == ZERO_ADDRESS:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = "Origin event is stored as PENDING_DISPATCH, but destination callback contract remains unconfigured."
            remediation = "Owner must call setDestinationConfig before invoking dispatchPendingCallback."
        elif not config_comparison["all_recipients_match"]:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = (
                f"Destination callback configuration drift blocked dispatch: expected_callback={norm_cb_addr}, "
                f"current destinationCallback()={dest_callback_configured} ({', '.join(failed_comparisons)})."
            )
            remediation = (
                "Complete an explicitly reviewed configuration migration before dispatching; "
                "preflight does not automatically adopt a drifted callback address."
            )
        elif dest_chain_id_configured != UNICHAIN_SEPOLIA_CHAIN_ID:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = f"Configured destination chain ID ({dest_chain_id_configured}) is invalid (expected {UNICHAIN_SEPOLIA_CHAIN_ID})."
            remediation = f"Owner must call setDestinationConfig with destination chain ID {UNICHAIN_SEPOLIA_CHAIN_ID}."
        elif gas_limit_configured < MINIMUM_CALLBACK_GAS:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = f"Configured callback gas limit ({gas_limit_configured}) is below minimum required {MINIMUM_CALLBACK_GAS}."
            remediation = f"Owner must call setDestinationConfig with callback gas limit >= {MINIMUM_CALLBACK_GAS}."
        elif config_blocker_reason:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = config_blocker_reason
            remediation = config_blocker_remediation
        elif proxy_debt > 0:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = f"CrossGuardCallback has outstanding debt of {proxy_debt} wei on Callback Proxy (blocks callback delivery)."
            remediation = "Settle callback debt by calling depositTo(callbackContract) on Unichain Sepolia Callback Proxy."
        elif proxy_reserves == 0 or proxy_reserves < proxy_fee_estimate["recommended_min_reserve_wei"]:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = (
                f"Insufficient Callback Proxy reserves ({proxy_reserves} wei) vs conservative estimate "
                f"({proxy_fee_estimate['recommended_min_reserve_wei']} wei under current gas environment)."
            )
            remediation = "Replenish reserves via depositTo(callbackContract) on Unichain Sepolia Callback Proxy."
        elif proxy_fee_estimate["settlement_gas_sufficient"] is False:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = (
                f"Callback Proxy _maxChargeGas ({proxy_max_gas}) fails payment-settlement requirement "
                f"({proxy_fee_estimate['settlement_gas_status']})."
            )
            remediation = "Verify destination Callback Proxy _maxChargeGas payment-settlement gas configuration."
        elif require_reactive_reserves and system_debt > 0:
            status = RecoveryStatus.RETRY_BLOCKED
            reason = (
                f"Conservative whole-pipeline policy (require_reactive_reserves=True): "
                f"CrossGuardReactive has outstanding debt of {system_debt} wei on System Contract (suspends automated react() execution)."
            )
            remediation = "Settle debt by calling depositTo(reactiveContract) on Reactive System Contract."
        elif require_reactive_reserves and (system_reserves == 0 or system_reserves < system_fee_estimate["recommended_min_reserve_wei"]):
            status = RecoveryStatus.RETRY_BLOCKED
            reason = (
                f"Conservative whole-pipeline policy (require_reactive_reserves=True): "
                f"Insufficient Reactive System Contract reserves ({system_reserves} wei) vs conservative estimate "
                f"({system_fee_estimate['recommended_min_reserve_wei']} wei)."
            )
            remediation = "Replenish reserves via depositTo(reactiveContract) on Reactive System Contract."
        else:
            status = RecoveryStatus.DISPATCH_REQUIRED
            reason = (
                f"Valid origin event (nonce {expected_nonce}, {r_cb_type}) was stored in CrossGuardReactive "
                f"as PENDING_DISPATCH when destination config was unavailable; current configuration and Callback Proxy funding pass."
            )
            if warnings:
                reason += f" Advisory: {len(warnings)} Reactive System Contract warning(s) emitted (see warnings)."
            remediation = "Authorized contract owner may review this evidence and manually invoke dispatchPendingCallback(positionId, expectedNonce)."

    # Next check non-deferred recipient drift BEFORE RETRY_ALREADY_SUCCEEDED or RETRY_ELIGIBLE
    if status is None and dest_callback_configured != ZERO_ADDRESS and not config_comparison["all_recipients_match"]:
        status = RecoveryStatus.RETRY_BLOCKED
        reason = (
            f"Destination callback configuration drift detected: expected={norm_cb_addr}, "
            f"historical={historical_cb_recipient}, current destinationCallback()={dest_callback_configured} "
            f"({', '.join(failed_comparisons)})."
        )
        remediation = (
            "Normal recovery blocks recipient drift and never auto-adopts a changed callback address; "
            "complete an explicitly reviewed configuration migration."
        )

    # Next check already processed on destination
    if status is None and dest_last_processed_nonce >= expected_nonce:
        status = RecoveryStatus.RETRY_ALREADY_SUCCEEDED
        reason = (
            f"Destination BorrowingController has already processed nonce {dest_last_processed_nonce} "
            f"(expected nonce {expected_nonce}). Borrowing paused={dest_paused}."
        )
        remediation = "No recovery action required. Destination state is synchronized."

    # Next inspect callback records & correlate 3-chain states strictly
    if status is None:
        if r_cb_nonce == 0 or r_cb_payload in ("0x", ""):
            status = RecoveryStatus.RETRY_BLOCKED
            reason = f"No callback payload stored for position {norm_pos} in CrossGuardReactive."
            remediation = "Ensure origin risk evaluation has occurred and event was intercepted by Reactive Lasna."
        elif r_cb_nonce != expected_nonce:
            status = RecoveryStatus.RETRY_UNKNOWN
            reason = f"Stored callback nonce ({r_cb_nonce}) does not match expected nonce ({expected_nonce})."
            remediation = "Verify expected nonce matches stored callback state."
        elif receipt_event_type is not None and receipt_event_type != r_cb_type_idx:
            status = RecoveryStatus.RETRY_UNKNOWN
            reason = f"Receipt eventType ({receipt_event_type}) contradicts stored callback eventType ({r_cb_type_idx})."
            remediation = "Verify receipt matches stored callback state."
        elif (r_cb_type_idx == 1 and not origin_breached) or (r_cb_type_idx == 2 and origin_breached):
            status = RecoveryStatus.RETRY_UNKNOWN
            reason = f"Origin breached state ({origin_breached}) contradicts stored callback eventType ({r_cb_type}) at nonce {expected_nonce}."
            remediation = "Reconcile origin RiskController state with Reactive stored state."
        elif r_cb_status_idx == 1:
            status = RecoveryStatus.RETRY_UNKNOWN
            reason = f"Contradictory dispatch state: stored callback status is PENDING_DISPATCH while receipt {norm_tx_hash} emitted non-deferred event."
            remediation = "Inspect transaction history for this position."

    if status is None:
        if not records or len(records) == 0:
            status = RecoveryStatus.RETRY_PENDING
            reason = "Callback records are empty or pending finalization on Reactive System Contract (empty records are NOT proof of failure)."
            remediation = "Allow additional time for Reactive block indexing, then re-check."
        else:
            matching = [
                r for r in records
                if normalize_address(r.get("reactive_contract", "")) == norm_reactive_cfg
                and r.get("destination_chain_id") == UNICHAIN_SEPOLIA_CHAIN_ID
            ]
            matched_record_count = len(matching)
            if len(matching) == 0:
                wrong_senders = [r.get("reactive_contract") for r in records if normalize_address(r.get("reactive_contract", "")) != norm_reactive_cfg]
                wrong_chains = [r.get("destination_chain_id") for r in records if r.get("destination_chain_id") != UNICHAIN_SEPOLIA_CHAIN_ID]
                if wrong_chains and not wrong_senders:
                    status = RecoveryStatus.RETRY_BLOCKED
                    reason = f"Callback record(s) target invalid destination chain(s) {wrong_chains} instead of {UNICHAIN_SEPOLIA_CHAIN_ID}."
                    remediation = "Verify destination chain configuration in CrossGuardReactive."
                elif wrong_senders or wrong_chains:
                    status = RecoveryStatus.RETRY_UNKNOWN
                    reason = f"Callback records do not match CrossGuardReactive ({norm_reactive_cfg}) on chain {UNICHAIN_SEPOLIA_CHAIN_ID} (senders={wrong_senders}, chains={wrong_chains})."
                    remediation = "Verify transaction hash corresponds to this CrossGuard deployment."
                else:
                    status = RecoveryStatus.RETRY_PENDING
                    reason = "Callback record matching CrossGuardReactive is pending creation."
                    remediation = "Wait for relayer and indexer finalization."
            elif len(matching) > 1:
                status = RecoveryStatus.RETRY_UNKNOWN
                reason = f"Found {len(matching)} ambiguous callback records matching CrossGuardReactive; cannot correlate single record unambiguously."
                remediation = "Manual operator investigation required for multi-callback transaction."
            else:
                matched_rec = matching[0]
                callback_record_info = matched_rec
                dest_tx = matched_rec.get("destination_tx_hash")
                err_bytes = matched_rec.get("error", "0x")
                has_dest_tx = dest_tx not in (0, "0", "0x0", "0x", None)
                has_error = err_bytes not in ("0x", "", None)

                if not has_dest_tx and not has_error:
                    status = RecoveryStatus.RETRY_PENDING
                    reason = "Callback is recorded on Reactive Lasna but pending delivery by relayer (destinationTxHash is 0)."
                    remediation = "Wait for cross-chain relayer to submit transaction to Unichain Sepolia."
                elif not has_dest_tx and has_error:
                    status = RecoveryStatus.RETRY_UNKNOWN
                    reason = f"Callback record contains nonempty error ({err_bytes}) with zero destinationTxHash; destination execution unconfirmed."
                    remediation = "Inspect Reactive debugging logs and relayer status before retrying."
                elif has_dest_tx and not has_error:
                    status = RecoveryStatus.RETRY_UNKNOWN
                    reason = (
                        f"Callback record reports empty error for destination tx {dest_tx}, "
                        f"but BorrowingController lastProcessedNonce ({dest_last_processed_nonce}) is still below {expected_nonce}."
                    )
                    remediation = "Inspect destination transaction receipt on Unichain Sepolia for partial execution or configuration drift."
                else:
                    # Confirmed destination execution failure: has_dest_tx AND has_error!
                    if r_cb_retries >= 3:
                        status = RecoveryStatus.RETRY_BLOCKED
                        reason = f"Retry limit exceeded: maximum 3 retries already consumed ({r_cb_retries}/3)."
                        remediation = "Retry budget exhausted. Manual administrative resolution or new origin event required."
                    elif r_cb_status_idx != 2:
                        status = RecoveryStatus.RETRY_BLOCKED
                        reason = f"Callback dispatch status is {r_cb_status} (must be REQUESTED for retry)."
                        remediation = "Callback must have been previously requested before calling retryFailedCallback."
                    elif dest_callback_configured == ZERO_ADDRESS:
                        status = RecoveryStatus.RETRY_BLOCKED
                        reason = "Destination callback contract is not configured in CrossGuardReactive."
                        remediation = "Owner must call setDestinationConfig with valid destination callback contract address."
                    elif not config_comparison["all_recipients_match"]:
                        status = RecoveryStatus.RETRY_BLOCKED
                        reason = (
                            f"Destination callback configuration drift blocked retry: expected={norm_cb_addr}, "
                            f"historical={historical_cb_recipient}, current={dest_callback_configured} "
                            f"({', '.join(failed_comparisons)})."
                        )
                        remediation = "Complete an explicitly reviewed configuration migration before retrying."
                    elif dest_chain_id_configured != UNICHAIN_SEPOLIA_CHAIN_ID:
                        status = RecoveryStatus.RETRY_BLOCKED
                        reason = f"Configured destination chain ID ({dest_chain_id_configured}) is invalid (expected {UNICHAIN_SEPOLIA_CHAIN_ID})."
                        remediation = f"Owner must call setDestinationConfig with destination chain ID {UNICHAIN_SEPOLIA_CHAIN_ID}."
                    elif gas_limit_configured < MINIMUM_CALLBACK_GAS:
                        status = RecoveryStatus.RETRY_BLOCKED
                        reason = f"Configured callback gas limit ({gas_limit_configured}) is below minimum required {MINIMUM_CALLBACK_GAS}."
                        remediation = f"Owner must call setDestinationConfig to increase callback gas limit to at least {MINIMUM_CALLBACK_GAS}."
                    elif config_blocker_reason:
                        status = RecoveryStatus.RETRY_BLOCKED
                        reason = config_blocker_reason
                        remediation = config_blocker_remediation
                    elif proxy_debt > 0:
                        status = RecoveryStatus.RETRY_BLOCKED
                        reason = f"CrossGuardCallback has outstanding debt of {proxy_debt} wei on Callback Proxy (stops callback delivery on destination)."
                        remediation = "Settle debt by calling depositTo(callbackContract) on Callback Proxy on Unichain Sepolia."
                    elif proxy_reserves == 0 or proxy_reserves < proxy_fee_estimate["recommended_min_reserve_wei"]:
                        status = RecoveryStatus.RETRY_BLOCKED
                        reason = (
                            f"Insufficient Callback Proxy reserves ({proxy_reserves} wei) vs conservative estimate "
                            f"({proxy_fee_estimate['recommended_min_reserve_wei']} wei)."
                        )
                        remediation = "Replenish reserves via depositTo(callbackContract) on Unichain Sepolia Callback Proxy."
                    elif proxy_fee_estimate["settlement_gas_sufficient"] is False:
                        status = RecoveryStatus.RETRY_BLOCKED
                        reason = (
                            f"Callback Proxy _maxChargeGas ({proxy_max_gas}) fails payment-settlement requirement "
                            f"({proxy_fee_estimate['settlement_gas_status']})."
                        )
                        remediation = "Verify destination Callback Proxy _maxChargeGas payment-settlement gas configuration."
                    elif require_reactive_reserves and system_debt > 0:
                        status = RecoveryStatus.RETRY_BLOCKED
                        reason = (
                            f"Conservative whole-pipeline policy (require_reactive_reserves=True): "
                            f"CrossGuardReactive has outstanding debt of {system_debt} wei on System Contract (suspends automated react() processing)."
                        )
                        remediation = "Settle debt by calling depositTo(reactiveContract) on Reactive System Contract."
                    elif require_reactive_reserves and (system_reserves == 0 or system_reserves < system_fee_estimate["recommended_min_reserve_wei"]):
                        status = RecoveryStatus.RETRY_BLOCKED
                        reason = (
                            f"Conservative whole-pipeline policy (require_reactive_reserves=True): "
                            f"Insufficient Reactive System Contract reserves ({system_reserves} wei) vs conservative estimate "
                            f"({system_fee_estimate['recommended_min_reserve_wei']} wei)."
                        )
                        remediation = "Replenish reserves by calling depositTo(reactiveContract) on Reactive System Contract."
                    else:
                        status = RecoveryStatus.RETRY_ELIGIBLE
                        reason = (
                            f"Recovery conditions met: confirmed destination execution failure (dest tx: {dest_tx}, error: {err_bytes}), "
                            f"stored callback nonce {r_cb_nonce} ({r_cb_type}) has not been processed on destination "
                            f"(dest nonce {dest_last_processed_nonce}), retry budget available ({r_cb_retries}/3), "
                            f"all 3 callback addresses agree ({norm_cb_addr}), and Callback Proxy reserves are adequate."
                        )
                        if warnings:
                            reason += f" Advisory: {len(warnings)} Reactive System Contract warning(s) emitted (see warnings)."
                        remediation = "Authorized contract owner may review this evidence and manually invoke retryFailedCallback(positionId, expectedNonce, reasonCode)."

    proxy_effective_gas_note = proxy_fee_estimate["effective_forwarded_gas_warning"]

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "status": status.value,
        "safe_to_consider_recovery": status in (RecoveryStatus.DISPATCH_REQUIRED, RecoveryStatus.RETRY_ELIGIBLE),
        "position_id": norm_pos,
        "expected_nonce": expected_nonce,
        "reactive_tx_hash": norm_tx_hash,
        "reason": reason,
        "remediation": remediation,
        "suggested_command": None,
        "warnings": warnings,
        "unsafe_or_unverified_conditions": unsafe_conditions,
        "missing_or_unavailable_evidence": missing_evidence,
        "configuration_comparison": config_comparison,
        "origin_state": {
            "risk_controller": norm_origin_ctrl,
            "nonce": origin_nonce,
            "breached": origin_breached,
        },
        "reactive_state": {
            "reactive_contract": norm_reactive_cfg,
            "latest_origin_nonce": reactive_latest_origin_nonce,
            "stored_callback_nonce": r_cb_nonce,
            "event_type": r_cb_type,
            "dispatch_status": r_cb_status,
            "retry_count": r_cb_retries,
            "max_retries": 3,
            "destination_chain_id": dest_chain_id_configured,
            "destination_callback": dest_callback_configured,
            "callback_gas_limit": gas_limit_configured,
            "gas_minimum_network_floor": MINIMUM_CALLBACK_GAS,
            "effective_forwarded_gas_exact": None,
            "effective_gas_advisory": proxy_effective_gas_note,
        },
        "destination_state": {
            "borrowing_controller": norm_borrow_ctrl,
            "callback_adapter": norm_cb_addr,
            "last_processed_nonce": dest_last_processed_nonce,
            "is_borrowing_paused": dest_paused,
            "paused_by_risk_breach": dest_paused_by_breach,
            "paused_by_admin": dest_paused_by_admin,
        },
        "economics": {
            "reactive_event_processing_path": {
                "contract": norm_sys_cfg,
                "network": "Reactive Lasna (5318007)",
                "currency": "REACT",
                "system_debt_wei": system_debt,
                "system_reserves_wei": system_reserves,
                "has_debt_or_low_reserves": bool(system_debt > 0 or system_reserves < system_fee_estimate["recommended_min_reserve_wei"]),
                "hard_protocol_requirement_for_manual_owner_tx": False,
                "enforced_conservatively": require_reactive_reserves,
                "classification_basis": (
                    "Conservative operational safeguard: System Contract debt/low reserves suspend future automated react() execution; "
                    "manual owner dispatchPendingCallback/retryFailedCallback pays EOA tx gas on Reactive Lasna."
                ),
            },
            "destination_callback_delivery_path": {
                "contract": norm_proxy_cfg,
                "network": "Unichain Sepolia (1301)",
                "currency": "ETH",
                "callback_proxy_debt_wei": proxy_debt,
                "callback_proxy_reserves_wei": proxy_reserves,
                "has_debt_or_low_reserves": bool(proxy_debt > 0 or proxy_reserves < proxy_fee_estimate["recommended_min_reserve_wei"]),
                "hard_protocol_requirement_for_destination_delivery": True,
                "classification_basis": "Callback Proxy blocks destination callback delivery when callback contract has debt or insufficient reserves.",
            },
            "factual_balances_and_debt": {
                "system_debt_wei": system_debt,
                "system_reserves_wei": system_reserves,
                "callback_proxy_debt_wei": proxy_debt,
                "callback_proxy_reserves_wei": proxy_reserves,
                "pathway_impact_notes": {
                    "system_debt_impact": "System Contract debt suspends future react() event execution (does not automatically block manual owner dispatchPendingCallback/retryFailedCallback unless conservative policy enabled).",
                    "callback_proxy_debt_impact": "Callback Proxy debt halts destination callback delivery until settled via depositTo(callbackContract).",
                    "balance_vs_reserves_note": "Direct ETH/REACT balance on contracts is NOT prepaid reserves credit; reserves live inside System Contract / Callback Proxy.",
                },
            },
            "fee_parameters": {
                "reactive_gas_price_coeff_per_1000": system_coeff,
                "reactive_extra_gas": system_extra_gas,
                "reactive_max_charge_gas": system_max_gas,
                "reactive_p_base_wei": p_base_reactive,
                "callback_proxy_gas_price_coeff_per_1000": proxy_coeff,
                "callback_proxy_extra_gas": proxy_extra_gas,
                "callback_proxy_max_charge_gas": proxy_max_gas,
                "callback_proxy_p_base_wei": p_base_dest,
                "max_charge_gas_semantics": "Limits gas available for payment-settlement call; excluded from execution fee formula.",
            },
            "reserve_estimates": {
                "system_contract_estimate": system_fee_estimate,
                "callback_proxy_estimate": proxy_fee_estimate,
            },
            "system_debt_wei": system_debt,
            "system_reserves_wei": system_reserves,
            "callback_proxy_debt_wei": proxy_debt,
            "callback_proxy_reserves_wei": proxy_reserves,
        },
        "receipt_evidence": {
            "tx_hash": norm_tx_hash,
            "status": rec_status_str,
            "event_topic0": cg_t0,
            "event_position_id": receipt_pos_id,
            "event_nonce": receipt_nonce,
            "deferred": is_deferred_event,
            "callback_request_count": len(system_cb_requests),
            "callback_request_decoded": historical_cb_request,
        },
        "callback_record": callback_record_info,
        "callback_record_correlation": {
            "total_records": len(records),
            "matched_records": matched_record_count,
            "expected_reactive_contract": norm_reactive_cfg,
            "expected_destination_chain_id": UNICHAIN_SEPOLIA_CHAIN_ID,
            "unambiguous_match": (matched_record_count == 1 and callback_record_info is not None),
            "protocol_schema_note": (
                "Official 6-field getCallbacks(uint256) returns (blockNumber, reactiveContract, callbackIndex, "
                "destinationChainId, destinationTxHash, error); does not contain recipient address or origin nonce."
            ),
        },
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
    lines.append(f"Position ID:     {report.get('position_id')}")
    lines.append(f"Expected Nonce:  {report.get('expected_nonce')}")
    lines.append(f"Reactive Tx:     {report.get('reactive_tx_hash')}")
    lines.append(f"Classification:  [{report['status']}] | Safe to consider recovery: {report.get('safe_to_consider_recovery')}")
    lines.append(f"Diagnosis:       {report['reason']}")
    lines.append("-" * 80)

    cfg_cmp = report.get("configuration_comparison")
    if cfg_cmp:
        lines.append("CALLBACK ADDRESS DRIFT CHECK:")
        lines.append(f"  • Expected CrossGuardCallback:    {cfg_cmp.get('expected_callback')}")
        lines.append(f"  • Historical Request Recipient:   {cfg_cmp.get('historical_callback_request_recipient') or '<None (deferred)>'}")
        lines.append(f"  • Current Reactive Destination:   {cfg_cmp.get('current_destination_callback')}")
        lines.append(f"  • All Recipients Match:           {cfg_cmp.get('all_recipients_match')} | Drift Detected: {cfg_cmp.get('drift_detected')}")
        lines.append("-" * 80)

    # State overview
    lines.append("CROSS-CHAIN STATE SNAPSHOT:")
    o = report.get("origin_state", {})
    r = report.get("reactive_state", {})
    d = report.get("destination_state", {})
    lines.append("  • Origin (Base Sepolia - 84532):")
    lines.append(f"      Nonce: {o.get('nonce')} | Breached: {o.get('breached')}")
    lines.append("  • Reactive Lasna (5318007):")
    lines.append(f"      Latest Origin Nonce:    {r.get('latest_origin_nonce')}")
    lines.append(f"      Stored Callback Nonce:  {r.get('stored_callback_nonce')} ({r.get('event_type')})")
    lines.append(f"      Dispatch Status:        {r.get('dispatch_status')}")
    lines.append(f"      Retry Count:            {r.get('retry_count')}/{r.get('max_retries', 3)}")
    lines.append(f"      Destination Callback:   {r.get('destination_callback')}")
    lines.append(f"      Callback Gas Limit:     {r.get('callback_gas_limit')} (min network floor: {r.get('gas_minimum_network_floor', MINIMUM_CALLBACK_GAS)})")
    if r.get("effective_gas_advisory"):
        lines.append(f"      Gas Advisory:           {r.get('effective_gas_advisory')}")
    lines.append("  • Destination (Unichain Sepolia - 1301):")
    lines.append(f"      Last Processed Nonce:   {d.get('last_processed_nonce')}")
    lines.append(f"      Borrowing Paused:       {d.get('is_borrowing_paused')}")
    lines.append(f"      Paused By Risk Breach:  {d.get('paused_by_risk_breach')}")
    lines.append(f"      Paused By Admin:        {d.get('paused_by_admin')}")
    lines.append("-" * 80)

    econ = report.get("economics", {})
    factual = econ.get("factual_balances_and_debt", econ)
    est = econ.get("reserve_estimates", {})
    lines.append("ECONOMIC PRECONDITIONS (FACTUAL):")
    lines.append(f"  • Reactive System Reserves: {factual.get('system_reserves_wei')} wei | Debt: {factual.get('system_debt_wei')} wei")
    lines.append(f"  • Callback Proxy Reserves:   {factual.get('callback_proxy_reserves_wei')} wei | Debt: {factual.get('callback_proxy_debt_wei')} wei")
    if est:
        p_est = est.get("callback_proxy_estimate", {})
        s_est = est.get("system_contract_estimate", {})
        lines.append("CONSERVATIVE RESERVE ESTIMATES (NOT A GUARANTEE OF FUTURE DELIVERY):")
        lines.append(f"  • Callback Proxy Est. Min Reserve: {p_est.get('recommended_min_reserve_wei')} wei (single est: {p_est.get('estimated_single_callback_fee_wei')} wei, {p_est.get('safety_multiplier')}x safety)")
        lines.append(f"  • System Contract Est. Min Reserve:{s_est.get('recommended_min_reserve_wei')} wei (single est: {s_est.get('estimated_single_callback_fee_wei')} wei, {s_est.get('safety_multiplier')}x safety)")
    lines.append("-" * 80)

    if report.get("warnings") or report.get("unsafe_or_unverified_conditions"):
        lines.append("WARNINGS & UNSAFE / UNVERIFIED CONDITIONS:")
        for item in report.get("unsafe_or_unverified_conditions", []):
            lines.append(f"  ! {item}")
        lines.append("-" * 80)

    lines.append("REMEDIATION & RECOVERY ACTION:")
    lines.append(f"  Remediation: {report.get('remediation')}")
    lines.append("\n" + "=" * 80)
    lines.append("SAFETY ADVISORY:")
    lines.append(f"  Execution: {report['execution']}")
    lines.append("  No private keys used, no transactions broadcast, no state mutated.")
    lines.append("  Preflight is diagnostic only and does not guarantee future callback delivery.")
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
    parser.add_argument("--expected-nonce", type=int, default=None, help="Expected origin nonce for recovery preflight diagnostics")
    parser.add_argument("--reactive-tx-hash", default=None, help="Originating Reactive Lasna tx hash")
    parser.add_argument(
        "--safety-multiplier",
        type=int,
        default=DEFAULT_RESERVE_SAFETY_MULTIPLIER,
        help=f"Conservative reserve estimate safety multiplier (default: {DEFAULT_RESERVE_SAFETY_MULTIPLIER})",
    )
    parser.add_argument(
        "--require-reactive-reserves",
        action="store_true",
        help="Conservatively block manual recovery when Reactive System Contract has debt or low reserves (automated react() safeguard).",
    )
    parser.add_argument(
        "--settlement-gas-requirement",
        type=int,
        default=None,
        help="Optional minimum payment-settlement gas requirement compared against _maxChargeGas().",
    )

    # Optional inspection & timeout
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
        "expected_nonce": args.expected_nonce,
        "safety_multiplier": args.safety_multiplier,
        "require_reactive_reserves": args.require_reactive_reserves,
        "settlement_gas_requirement": args.settlement_gas_requirement,
        "timeout": args.timeout,
    }

    if args.recovery_preflight and (not args.position_id or args.expected_nonce is None or not args.reactive_tx_hash):
        err_msg = "Error: --position-id, --expected-nonce, and --reactive-tx-hash are all mandatory when --recovery-preflight is enabled."
        if args.json:
            print(json.dumps({
                "status": RecoveryStatus.RETRY_UNKNOWN.value,
                "reason": err_msg,
                "execution": "NOT PERFORMED (read-only preflight diagnostic)",
            }))
        else:
            print(err_msg, file=sys.stderr)
        sys.exit(1)

    try:
        runner = CastRpcRunner(timeout=args.timeout)

        if args.recovery_preflight:

            report = run_recovery_preflight(
                config,
                position_id=args.position_id,
                expected_nonce=args.expected_nonce,
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

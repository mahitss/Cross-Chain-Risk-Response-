# M005.1 Verification Report: Operational Safety & ABI Correctness Patch

**Milestone:** M005.1 — Operational Safety & ABI Correctness Patch  
**Repository:** `mahitss/Cross-Chain-Risk-Response-`  
**Working Branch:** `fix/m002-2-omni-callback-correctness`  
**Baseline Commit:** `4d526a2381cfda57e7072e6450b25435500c8869`  
**Execution Date:** 2026-11-23  
**Implementation Engineer:** Antigravity  
**Principal Architect & Independent Reviewer:** ChatGPT  
**Product Owner:** Mahit  

---

## 1. Executive Summary

Mission M005.1 addresses the operational safety, ABI correctness, and documentation findings identified during the independent architectural review of milestone M005.

Under strict ₹0 budget, zero-deployment, and zero-broadcast constraints, M005.1 delivers:
1. **Centralized RPC Credential Redaction:** Comprehensive masking of sensitive credentials (user-info, secret path tokens, query parameters) across all output surfaces (terminal, JSON, evidence, remediation, exceptions).
2. **Documented Six-Field Callback ABI:** Integration and rigorous decoding of the official Reactive Network System Contract callback schema: `getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])`, deriving success strictly from empty error bytes (`0x` / length 0) rather than an assumed boolean field.
3. **Correct Funding Recovery Architecture:** Explicit documentation and remediation routing for `depositTo(address)` on both the Reactive System Contract (`0x8888...8888`) and Unichain Callback Proxy (`0x9299...7FC4`), warning operators that direct transfers credit `msg.sender` and that `CrossGuardReactive.pay()` reverts.
4. **Deterministic Exit Codes:** Enforced exit code `0` for `HEALTHY`, and exit code `1` for all non-healthy states (`WARNING`, `CRITICAL`, `UNKNOWN`, `ERROR`).
5. **Honest Oracle & Telemetry Scope:** Removal of unsupported claims regarding oracle pause/staleness detection, aligning documentation with the actual `TestValuationSource` implementation (`setAssetPrice`, `getAssetPrice`).
6. **Documentation & CLI Alignment:** Full reconciliation of CLI arguments (`--reactive-tx-hash`), exit codes, and runbook procedures across README, runbook, and verification reports.
7. **Subprocess Timeout Guards:** Bounded execution timeouts (default 15.0s) converting hung queries into controlled `ERROR` results with redacted credentials.
8. **Expanded Test Suite:** 36 offline unit tests (100% mocked RPC, 0 network sockets) and 136 preserved Foundry tests passing with 100% success rate.

---

## 2. File Inventory & Integrity

| File Path | Status | SHA-256 Digest | Description |
| :--- | :--- | :--- | :--- |
| `script/ops/crossguard_healthcheck.py` | Modified | `B37DCC9CBAC673A37DCDD3E58B4A12F086DAA6E07FACB0E1DE8C1822EB1A0DED` | Added centralized credential redaction, 6-field callback ABI decoding, bounded timeouts, and strict exit code mapping |
| `test/ops/test_crossguard_healthcheck.py` | Modified | `7FD8B733349577C0A696A69342E5C3B4542E0272D7ED282A58D7A938842A248C` | Expanded from 20 to 36 tests covering redaction, ABI decoding (raw hex and formatted tuples), exit codes, depositTo routing, and timeouts |
| `docs/operations/CROSSGUARD-OPERATIONS-RUNBOOK.md` | Modified | `FA5C9D11956C2D5F0957814D80D367488E3D83D2B4F972AF91DF7116B0BBD5B9` | Corrected funding recovery procedures to use `depositTo(address)`, updated `getCallbacks` signature, and clarified oracle scope |
| `docs/reports/M005-VERIFICATION-REPORT.md` | Modified | `3F0D6B57F06347A182659848FAF734C9A81A893D16FB0FC6327472A544FF38B4` | Corrected diagnostic matrix table and removed unsupported oracle/flag references |
| `README.md` | Modified | `F996FCE8BCBAD91CA1D43647A883B154ACFF5BD01FE65D0B3351BB154C781CE7` | Updated CLI usage, test count (36 tests), operational runbook summary, and documented arguments |
| `docs/reports/M005-1-VERIFICATION-REPORT.md` | Added | *(Self-referential)* | This milestone verification report |

---

## 3. Detailed Architecture of Corrective Fixes

### A. Centralized RPC Credential Redaction (Critical Fix A)
- **Functions:** `redact_rpc_url(url)` and `sanitize_text(text, urls)`.
- **Properties:**
  - Uses `urllib.parse.urlsplit` to isolate `scheme`, `hostname`, and non-standard `port`.
  - User-info (`user:pass@`) is strictly stripped.
  - Path-based secret tokens (e.g. Alchemy/Infura API keys `/v2/<key>`) and query parameters (e.g. `?apiKey=<key>`) are replaced with `/<redacted>`.
  - Raw unredacted URLs are passed directly to `cast` for network execution; however, any string output to terminal, JSON, evidence dictionaries, exception traces, or remediation text is filtered through `sanitize_text()`.
- **Evidence:** Proved by unit tests 21, 22, 23, 24, and 25 (asserting that user-info, query tokens, path keys, and compound secrets never appear anywhere in generated JSON or terminal reports).

### B. Reactive Callback Record ABI Decoding (Critical Fix B)
- **Official Documentation Reference:** `https://dev.reactive.network/debugging`
- **Method Signature:**
  ```solidity
  getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])
  ```
- **Six-Field Tuple Record Shape:**
  1. `destination_chain_id` (`uint256`): Destination network identifier (expected: `1301`).
  2. `to` (`address`): Target contract address (normalized 0x-prefixed 40 hex chars).
  3. `gas_limit` (`uint256`): Gas limit allocated for callback execution.
  4. `gas_price` (`uint256`): Gas price or execution cost metric.
  5. `tx_id` (`uint256`): Destination transaction identifier (or 0 if pending/unassigned).
  6. `error` (`bytes`): Revert reason bytes.
- **Success Semantics:** Success is determined **strictly** from the `error` byte array:
  - If `error` is empty (`""` or `"0x"` or 0 bytes): **SUCCESS**.
  - If `error` contains non-zero bytes (e.g. `0x4e487b71` for Panic, `0x08c379a0` for Error(string), or custom errors): **REVERT / FAILURE**.
- **Edge-Case & Multi-Record Support:**
  - Empty array returns `Status.UNKNOWN` ("pending, not yet recorded, or unavailable")—never falsely reported as failure.
  - Multiple records: All must succeed for `Status.PASS`; any failed record promotes status to `Status.CRITICAL`.
  - Revert bytes are preserved byte-for-byte in check evidence.
  - Raw ABI-encoded binary hex and formatted string tuples from `cast` are both fully supported.
  - Malformed ABI data yields `Status.ERROR`—never falsely reported as success.
- **Evidence:** Proved by unit tests 14, 15, 16, 26, 27, 28, 29, 30, 31, 32, and 33.

### C. Correct Funding Recovery Instructions (Critical Fix C)
- **Official Documentation Reference:** `https://dev.reactive.network/economy`
- **Reactive Engine (Reactive Lasna):**
  - Funding token: Native REACT.
  - System Contract method: `depositTo(address)`.
  - Calling `depositTo(reactiveContract)` settles outstanding debt first before crediting remainder to prepaid reserves.
  - Plain transfers to the System Contract credit `msg.sender`'s accounting balance, not the reactive contract.
  - `CrossGuardReactive.pay(uint256)` reverts with `"Not implemented"` and must **never** be invoked.
- **Destination Chain (Unichain Sepolia):**
  - Funding token: Native gas token (ETH).
  - Callback Proxy method: `depositTo(address)`.
  - Calling `depositTo(callbackContract)` settles outstanding callback debt and replenishes reserves.
  - Plain transfers to the Callback Proxy credit `msg.sender`, not the callback recipient.
- **Evidence:** Documented in `CROSSGUARD-OPERATIONS-RUNBOOK.md` with explicit operator warning notices (`> [!WARNING]`); validated by unit test 35.

### D. Strict Exit Code Semantics (Critical Fix D)
- **Function:** `compute_exit_code(overall_status)`.
- **Specification:**
  - `OverallStatus.HEALTHY` -> Exit code `0`.
  - `OverallStatus.WARNING` -> Exit code `1`.
  - `OverallStatus.CRITICAL` -> Exit code `1`.
  - `OverallStatus.UNKNOWN` -> Exit code `1`.
  - `OverallStatus.ERROR` -> Exit code `1`.
- **Evidence:** Validated across all exit code states by unit test 34.

### E. Honest Oracle Scope & Telemetry (Fix E)
- `TestValuationSource` contains only `setAssetPrice(address,uint256)` and `getAssetPrice(address)`.
- Corrected all documentation to clarify that oracle pause states, freshness timestamps, heartbeat mechanisms, and automated LTV position telemetry are not implemented in the MVP contracts.
- Documented decentralized oracle integration (Chainlink/Pyth) as future work.

### F. CLI Argument & Documentation Alignment (Fix F)
- Standardized on the implemented `--reactive-tx-hash` CLI argument across README, runbook, and verification reports.
- Added `--timeout` parameter (default: 15.0s).
- Removed all legacy mentions of `--callback-id` and `--position-id`.

---

## 4. Verification Evidence

### A. Python Operational Health Check Unit Tests (36/36 Passed)
```text
test_01_all_three_correct_chain_ids (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_01_all_three_correct_chain_ids) ... ok
test_02_incorrect_chain_id (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_02_incorrect_chain_id) ... ok
test_03_rpc_unavailable (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_03_rpc_unavailable) ... ok
test_04_missing_contract_code (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_04_missing_contract_code) ... ok
test_05_correct_contract_address_wiring (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_05_correct_contract_address_wiring) ... ok
test_06_incorrect_reactive_callback_address (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_06_incorrect_reactive_callback_address) ... ok
test_07_incorrect_authorized_reactive_sender (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_07_incorrect_authorized_reactive_sender) ... ok
test_08_incorrect_borrowing_controller_adapter (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_08_incorrect_borrowing_controller_adapter) ... ok
test_09_nonzero_reactive_debt (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_09_nonzero_reactive_debt) ... ok
test_10_nonzero_callback_proxy_debt (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_10_nonzero_callback_proxy_debt) ... ok
test_11_zero_reserves_with_no_debt (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_11_zero_reserves_with_no_debt) ... ok
test_12_callback_gas_below_100k (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_12_callback_gas_below_100k) ... ok
test_13_callback_gas_at_or_above_100k (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_13_callback_gas_at_or_above_100k) ... ok
test_14_empty_callback_records (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_14_empty_callback_records) ... ok
test_15_successful_callback_record (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_15_successful_callback_record) ... ok
test_16_failed_callback_record_with_error_data (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_16_failed_callback_record_with_error_data) ... ok
test_17_malformed_rpc_or_abi_output (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_17_malformed_rpc_or_abi_output) ... ok
test_18_missing_environment_configuration (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_18_missing_environment_configuration) ... ok
test_19_json_output_validity (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_19_json_output_validity) ... ok
test_20_no_write_capable_command_execution (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_20_no_write_capable_command_execution) ... ok
test_21_credential_redaction_userinfo (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_21_credential_redaction_userinfo) ... ok
test_22_credential_redaction_query_params (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_22_credential_redaction_query_params) ... ok
test_23_credential_redaction_path_api_key (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_23_credential_redaction_path_api_key) ... ok
test_24_credential_redaction_multiple_locations (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_24_credential_redaction_multiple_locations) ... ok
test_25_no_credentials_leak_in_report_or_terminal (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_25_no_credentials_leak_in_report_or_terminal) ... ok
test_26_callback_abi_empty_array_hex (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_26_callback_abi_empty_array_hex) ... ok
test_27_callback_abi_single_success_hex (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_27_callback_abi_single_success_hex) ... ok
test_28_callback_abi_single_failure_hex (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_28_callback_abi_single_failure_hex) ... ok
test_29_callback_multiple_successful_records (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_29_callback_multiple_successful_records) ... ok
test_30_callback_mixed_outcomes (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_30_callback_mixed_outcomes) ... ok
test_31_callback_malformed_abi (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_31_callback_malformed_abi) ... ok
test_32_callback_wrong_destination_chain (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_32_callback_wrong_destination_chain) ... ok
test_33_callback_missing_destination_tx (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_33_callback_missing_destination_tx) ... ok
test_34_exit_code_behavior_all_statuses (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_34_exit_code_behavior_all_statuses) ... ok
test_35_funding_remediation_uses_deposit_to (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_35_funding_remediation_uses_deposit_to) ... ok
test_36_timeout_handling_and_redaction (test_crossguard_healthcheck.TestCrossGuardHealthChecker.test_36_timeout_handling_and_redaction) ... ok

----------------------------------------------------------------------
Ran 36 tests in 0.015s

OK
```

### B. Foundry Test Suites (136/136 Passed)
```text
Ran 10 test suites:
- test/unit/BorrowingController.t.sol: 20 passed, 0 failed, 0 skipped
- test/unit/CrossGuardReactive.t.sol: 24 passed, 0 failed, 0 skipped
- test/unit/CollateralVault.t.sol: 19 passed, 0 failed, 0 skipped
- test/unit/RiskController.t.sol: 18 passed, 0 failed, 0 skipped
- test/unit/CrossGuardCallback.t.sol: 14 passed, 0 failed, 0 skipped
- test/unit/ConfigurationConsistency.t.sol: 10 passed, 0 failed, 0 skipped
- test/unit/TestValuationSource.t.sol: 4 passed, 0 failed, 0 skipped
- test/unit/ScriptPreflight.t.sol: 4 passed, 0 failed, 0 skipped
- test/unit/M004AdversarialSecurity.t.sol: 21 passed, 0 failed, 0 skipped
- test/integration/CrossGuardE2E.t.sol: 2 passed, 0 failed, 0 skipped

Total: 136 passed, 0 failed, 0 skipped (100% pass rate)
```

### C. Formatting Check (`forge fmt --check`)
```text
forge fmt --check: Exited 0 with no formatting violations.
```

### D. Bytecode Sizes (`forge build --sizes`)
```text
╭------------------------+------------------+-------------------+--------------------+---------------------╮
| Contract               | Runtime Size (B) | Initcode Size (B) | Runtime Margin (B) | Initcode Margin (B) |
+==========================================================================================================+
| BorrowingController    | 2,829            | 3,039             | 21,747             | 46,113              |
| CollateralVault        | 3,499            | 3,837             | 21,077             | 45,315              |
| CrossGuardCallback     | 2,314            | 2,769             | 22,262             | 46,383              |
| CrossGuardReactive     | 3,684            | 4,700             | 20,892             | 44,452              |
| RiskController         | 1,826            | 2,095             | 22,750             | 47,057              |
| TestValuationSource    | 695              | 905               | 23,881             | 48,247              |
╰------------------------+------------------+-------------------+--------------------+---------------------╯
```

---

## 5. Budget, Deployment & Transaction Disclosure

- **Total Budget Expended:** ₹0 / $0.
- **Smart Contracts Deployed to Live Networks:** 0.
- **Transactions Broadcast to Live Networks:** 0.
- **Private Keys Handled, Generated, or Stored:** 0.
- **Simulation Rigor:** All tests executed offline against in-memory mocked state and local Foundry EVM instances.

---

## 6. Acceptance Criteria Checklist

- [x] RPC credentials are redacted from every output path (terminal, JSON, evidence, remediation, exceptions).
- [x] Callback parsing matches the official ABI (`getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])`).
- [x] Callback tests use the correct six-field structure.
- [x] Empty records remain UNKNOWN, never false failure.
- [x] Funding runbook uses `depositTo(beneficiary)`.
- [x] Exit codes correctly fail on every non-healthy state (0 for HEALTHY, 1 for all others).
- [x] Oracle monitoring claims match actual implementation (`setAssetPrice`, `getAssetPrice`).
- [x] README and CLI arguments match (`--reactive-tx-hash`).
- [x] RPC commands have bounded execution time (15s timeout).
- [x] All 36 Python tests pass.
- [x] All 136 Foundry tests still pass.
- [x] No Solidity changes.
- [x] No live interactions or transactions.
- [x] ₹0 budget maintained.

---

## 7. GitHub Actions Continuous Integration (CI) Verification

- **Commit SHA:** `0ed6719436d15966fe7e81b4b51cd91dca8ab579`
- **Workflow Run ID:** `45063501070`
- **Workflow Run URL:** `https://github.com/mahitss/Cross-Chain-Risk-Response-/actions/runs/45063501070`
- **Status:** `completed`
- **Conclusion:** `success`
- **Execution Pipeline:**
  1. `actions/checkout`
  2. `Install Foundry`
  3. `Show Forge version`
  4. `Run Forge fmt` (passed)
  5. `Run Forge build` (passed, sizes verified)
  6. `Run Forge tests` (136/136 tests passed)
  7. `Set up Python` (Python 3.11)
  8. `Run Operational Health Check Unit Tests` (36/36 tests passed)


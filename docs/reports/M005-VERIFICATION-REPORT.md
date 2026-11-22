# M005 Verification & Operations Report: Cross-Chain Observability & Diagnostics

**Milestone:** M005 — Cross-Chain Operational Observability & Failure Diagnosis  
**Repository:** `mahitss/Cross-Chain-Risk-Response-`  
**Working Branch:** `fix/m002-2-omni-callback-correctness`  
**Baseline Commit:** `f3b954619a0fa13a6269f1fafb87de99a8bb80ef`  
**Execution Date:** 2026-11-22  
**Implementation Engineer:** Antigravity  
**Principal Architect & Independent Reviewer:** ChatGPT  
**Product Owner:** Mahit  

---

## 1. Executive Summary

Mission M005 successfully implements the operational observability and failure-diagnosis framework for CrossGuard's 3-chain topology:
- **Origin Chain:** Base Sepolia (Chain ID: `84532`)
- **Reactive Engine:** Reactive Lasna (Chain ID: `5318007`)
- **Destination Chain:** Unichain Sepolia (Chain ID: `1301`)

Under strict budget (₹0), zero-deployment, and zero-transaction constraints, M005 delivers a non-intrusive, read-only operational health-check CLI (`script/ops/crossguard_healthcheck.py`), a comprehensive 20-scenario offline unit test suite (`test/ops/test_crossguard_healthcheck.py`), a detailed 16-scenario operational runbook (`docs/operations/CROSSGUARD-OPERATIONS-RUNBOOK.md`), CI pipeline test automation, and complete historical lineage reconciliation for M004.1.

---

## 2. File Inventory & Integrity

| File Path | Status | SHA-256 Checksum | Description |
| :--- | :--- | :--- | :--- |
| `script/ops/crossguard_healthcheck.py` | Added | `C720D367F83D938D1527BD0DE739110C76AE295B28D2B95B0CB0EE1D52B6CFD9` | Read-only CLI health check tool using Python standard library & Foundry `cast` |
| `test/ops/test_crossguard_healthcheck.py` | Added | `DC8E0C64F1CF5632C5261E183A6313A67A81CA71DF50593F4A85FA5A333DDD67` | 20-scenario offline unit test suite with 100% mocked RPC execution |
| `docs/operations/CROSSGUARD-OPERATIONS-RUNBOOK.md` | Added | `8DD475793964031D3A2514467F39E7F76A4D7C49483EB36030DBF71ECA17970C` | 16-scenario operational diagnosis manual & honest recovery guide |
| `docs/reports/M004-VERIFICATION-REPORT.md` | Modified | `19DB21B04DF484ABE3FDD35425D14D067D83B0BD4F738942C0553A12C301A9C1` | Lineage reconciliation distinguishing commits `b5e38d0...` and `f3b9546...` |
| `.github/workflows/test.yml` | Modified | `E9C933ABD59F7B5A235E297EA5954FB5F6B3138DFCC2715728D7BEB64A5933F9` | CI workflow extended to run Python health check unit tests |
| `.gitignore` | Modified | `CAA8A3A5A1C1C54B2820B97C2B9A9C99E0DEB115AFC39E3E9179789450E49C25` | Unignores `docs/operations/**` and ignores Python bytecode `__pycache__/` |
| `README.md` | Modified | `EA5911867531A07F7D4FAF3FC1B9525EC535DAA8CAFE292ACC68AD52B444E28C` | Updated repository tree, CI documentation, and health check instructions |
| `docs/reports/M005-VERIFICATION-REPORT.md` | Added | `Self-referential` | Milestone verification and operational audit report |

---

## 3. M004.1 Historical Lineage Reconciliation

In the M004.1 milestone, the documentation reconciliation and final verification report update were executed across two distinct commits:

1. **Commit `b5e38d04782d88bd763d81110d7464beb412761b` (M004.1 - Technical Reconciliation):**
   - Corrected `docs/security/M004-THREAT-MODEL.md` to reflect the nonce-watermark architecture.
   - Updated `docs/reports/M004-VERIFICATION-REPORT.md` with baseline SHA and audit evidence.
   - Pushed and validated on GitHub Actions:
     - **CI Run ID:** `45036073217`
     - **CI Run URL:** `https://github.com/mahitss/Cross-Chain-Risk-Response-/actions/runs/45036073217`
     - **Conclusion:** `success` (All jobs completed with 0 failures)

2. **Commit `f3b954619a0fa13a6269f1fafb87de99a8bb80ef` (M004.1 - Report Finalization):**
   - Updated `docs/reports/M004-VERIFICATION-REPORT.md` to reference the final commit hash `b5e38d0...` and its completed CI run ID `45036073217`.
   - Pushed and validated on GitHub Actions:
     - **CI Run ID:** `45038069575`
     - **CI Run URL:** `https://github.com/mahitss/Cross-Chain-Risk-Response-/actions/runs/45038069575`
     - **Conclusion:** `success` (All jobs completed with 0 failures)

Both commits maintain an unbroken linear commit chain from baseline `ffc2911...` without rewriting Git history.

---

## 4. Health-Check Tool Architecture (`crossguard_healthcheck.py`)

### A. Security Boundary & Command Whitelist
`crossguard_healthcheck.py` interacts with EVM networks exclusively via Foundry's `cast` CLI under strict defensive rules:
- **Read-Only Whitelist:** Only four `cast` subcommands are permitted:
  - `cast chain-id`
  - `cast code`
  - `cast call`
  - `cast balance`
- **Rejection of State-Mutating Flags & Commands:** Any command containing `send`, `publish`, `mktx`, `--broadcast`, `--private-key`, `--interactive`, or shell redirection metacharacters is immediately rejected with an exception.
- **Direct Process Execution:** Commands are executed as argument arrays (`subprocess.run(["cast", ...], shell=False)`), preventing shell-injection vulnerabilities.
- **Zero Third-Party Dependencies:** Implemented strictly with Python's standard library (`subprocess`, `json`, `argparse`, `sys`, `re`), eliminating supply-chain risks.

### B. Two-Phase Architecture
The tool strictly separates logic from I/O:
1. **I/O Phase (`RpcRunner`):** Dispatches read-only queries against Base Sepolia, Reactive Lasna, and Unichain Sepolia RPC endpoints.
2. **Pure Evaluation Phase (`check_health`):** Accepts structured RPC response data, validates invariants, and produces a deterministic health report. This decoupling enables 100% offline unit testing without network sockets.

### C. Severity Hierarchy & Exit Codes
The tool classifies system status into 5 discrete severity tiers:
1. `HEALTHY`: Component operates within optimal parameters.
2. `WARNING`: Sub-optimal operational condition that does not immediately break safety (e.g., zero reserve with zero debt, non-blocking operational advisory).
3. `CRITICAL`: Immediate safety or liveness failure (e.g., contract debt, misconfigured wiring, missing code, chain ID mismatch).
4. `UNKNOWN`: Incomplete telemetry or unresolvable state.
5. `ERROR`: Network or RPC infrastructure unreachable.

**Exit Code Behavior:**
- Returns `0` if and only if **all** evaluated components are `HEALTHY`.
- Returns `1` if any component returns `WARNING`, `CRITICAL`, `UNKNOWN`, or `ERROR`, allowing seamless integration with automated CI/CD and alerting monitors.

---

## 5. Cross-Chain Diagnostic Matrix Summary

The 16 operational scenarios documented in `docs/operations/CROSSGUARD-OPERATIONS-RUNBOOK.md` map to the health-check tool capabilities as follows:

| Scenario | Component | Severity | Detectable by Health Check? | Primary Remediation Action |
| :--- | :--- | :--- | :--- | :--- |
| **SC-01** | Origin RPC Outage | `ERROR` | **Yes** (`origin_chain: ERROR`) | Fail over to backup Base Sepolia RPC endpoint. |
| **SC-02** | Paused Oracle | `WARNING` | **Partial** (via position LTV evaluation) | Owner unpauses `TestValuationSource` or updates heartbeat. |
| **SC-03** | Stale / Zero Oracle Price | `CRITICAL` | **Partial** (via valuation reads) | Owner submits fresh asset price quote to oracle. |
| **SC-04** | Origin Zero-ID Rejection | `WARNING` | **No** (Contract behavior is fail-safe) | Client application must supply valid non-zero position ID. |
| **SC-05** | Reactive RPC Outage | `ERROR` | **Yes** (`reactive_chain: ERROR`) | Fail over to backup Reactive Lasna RPC endpoint. |
| **SC-06** | Reactive Contract Debt | `CRITICAL` | **Yes** (`reactive_reserves: CRITICAL`) | Deposit native REACT to System Contract beneficiary address. |
| **SC-07** | Low Callback Gas Limit | `WARNING` / `CRITICAL` | **Yes** (`gas_limit: WARNING/CRITICAL`) | Call `setDestinationConfig` with $\ge 100,000$ gas limit. |
| **SC-08** | Unconfigured Callback Recipient | `CRITICAL` | **Yes** (`wiring: CRITICAL`) | Call `setDestinationConfig` with deployed adapter address. |
| **SC-09** | `pay()` Non-Implementation | `WARNING` | **Yes** (`operational_notes: WARNING`) | Deposit directly to System Contract; do not call `pay()`. |
| **SC-10** | Omni Relayer Latency | `WARNING` | **Partial** (Empty record on pending ID) | Await relayer processing or verify Reactive validator quorum. |
| **SC-11** | Callback Proxy Debt | `CRITICAL` | **Yes** (`proxy_reserves: CRITICAL`) | Deposit native gas token to Unichain Callback Proxy. |
| **SC-12** | Callback Proxy Revert | `CRITICAL` | **Yes** (via `--callback-id` check) | Inspect revert reason byte string in callback record. |
| **SC-13** | Callback Sender Forgery | `CRITICAL` | **Yes** (`wiring: CRITICAL`) | Configure `CrossGuardCallback` with valid Reactive address. |
| **SC-14** | Duplicate / Stale Nonce Revert | `WARNING` | **Yes** (Logs `InvalidNonce()`) | Discard stale callback; re-evaluate position on origin. |
| **SC-15** | Admin Pause Conflict | `WARNING` | **Partial** (via contract state read) | Admin invokes `emergencyResumeBorrowing` with audit reason. |
| **SC-16** | Unregistered Position ID | `CRITICAL` | **Partial** (via contract state read) | Register position on `BorrowingController` before borrowing. |

---

## 6. Callback Retry & Recovery Boundary Disclosure

CrossGuard's architectural security constraints strictly govern cross-chain failure recovery:

1. **No Automatic Destination Retry:**
   - The Reactive Network Omni architecture does not provide an automated destination retry queue for reverted callbacks.
   - If a callback reverts on Unichain Sepolia (due to out-of-gas, authentication mismatch, or temporary state conflicts), the callback status is finalized as failed.

2. **Nonce Monotonicity Invariant:**
   - `BorrowingController` enforces `require(nonce > lastProcessedNonce[positionId], InvalidNonce)`.
   - Even if an operator could re-execute the exact failed callback payload, it would revert with `InvalidNonce()` if the nonce was already processed, or fail Layer 1 / Layer 2 authentication if not executed via the official Callback Proxy.

3. **Canonical Recovery Mechanism:**
   - Safe recovery occurs at the **Origin**:
     - When collateral prices recover or risk parameters change, an operator or keeper invokes `CollateralVault.evaluatePositionRisk(positionId)`.
     - `RiskController` evaluates the position, increments `positionNonce[positionId]`, and emits a fresh `RiskResolved` or `RiskBreach` event with a **higher monotonic nonce**.
     - `CrossGuardReactive` observes the new event and dispatches a fresh callback with the updated nonce, which Unichain Sepolia accepts and processes cleanly.

---

## 7. Verification Evidence

### A. Python Operational Health Check Unit Tests
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

----------------------------------------------------------------------
Ran 20 tests in 0.009s

OK
```

### B. Foundry Unit, Adversarial, and Integration Tests
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

## 8. Budget, Deployment & Transaction Disclosure

- **Total Budget Expended:** ₹0 / $0.
- **Smart Contracts Deployed to Live Networks:** 0.
- **Transactions Broadcast to Live Networks:** 0.
- **Private Keys Loaded, Handled, or Stored:** 0.
- **Methodology:** All unit tests run against in-memory mocked state or deterministic subprocess fixtures. No live network connections or fund expenditures occurred during this milestone.

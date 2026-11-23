# M005.2 Verification Report: Reactive Callback Record Field-Order Correction

**Milestone:** M005.2 — Reactive Callback Record Field-Order Correction  
**Repository:** `mahitss/Cross-Chain-Risk-Response-`  
**Working Branch:** `fix/m002-2-omni-callback-correctness`  
**Baseline Commit:** `158972a6f9d4151e9a7b7cc7cf4cdae983419070`  
**Execution Date:** 2026-11-23  
**Implementation Engineer:** Antigravity  
**Principal Architect & Independent Reviewer:** ChatGPT  
**Product Owner:** Mahit  

---

## 1. Executive Summary

Mission M005.2 corrects the callback record decoder introduced in M005.1 to strictly adhere to the official Reactive Network economy specification:
`https://dev.reactive.network/economy`

Under strict ₹0 budget, zero-deployment, and zero-broadcast constraints, M005.2 establishes:
1. **Official Six-Field ABI Field Order:** Aligns decoding logic with the documented return tuple of `getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])`:
   - Field 1: `uint256 blockNumber` — Reactive Lasna block number when callback was registered.
   - Field 2: `address reactiveContract` — Requesting Reactive Smart Contract address on Lasna.
   - Field 3: `uint256 callbackIndex` — Sequential callback index.
   - Field 4: `uint256 destinationChainId` — Target destination EVM network ID (1301 for Unichain Sepolia).
   - Field 5: `uint256 destinationTxHash` — Transaction hash on destination network (0 if pending relay).
   - Field 6: `bytes error` — Destination execution revert bytes (empty for success).
2. **Field-Specific Validation & Rejection:**
   - Destination chain validation reads **field four** (`destinationChainId`), rejecting mismatches as `CRITICAL`.
   - Requesting Reactive contract validation reads **field two** (`reactiveContract`) and compares against configured `CrossGuardReactive`, rejecting unauthorized originators as `CRITICAL`.
   - Field three is decoded as `callbackIndex` (not a gas limit).
   - Field five is decoded as `destinationTxHash` (not a gas price).
   - Removes erroneous recipient address claims; field two is the requesting Reactive contract, not a destination recipient.
3. **Evidence-Grounded Success & Pending States:**
   - Empty callback array returns `UNKNOWN` (pending or unrecorded).
   - Valid callback with non-zero `destinationTxHash` and empty `error` returns `PASS` (`SUCCESS`).
   - Non-empty `error` bytes return `CRITICAL` (`FAILURE`), preserving raw revert bytes in evidence.
   - Zero or missing `destinationTxHash` returns `UNKNOWN` (`PENDING_DESTINATION_TX`), avoiding false claims of confirmed success without destination inclusion proof.
   - Malformed ABI responses return `ERROR`.
4. **Dual Decoding Paths:** Full test verification across both raw ABI-encoded hexadecimal data and formatted `cast call` tuple strings.
5. **Preservation of M005.1 Controls:** Preserves RPC credential redaction, bounded subprocess timeouts, strict binary exit codes (`0` for `HEALTHY`, `1` otherwise), `depositTo(address)` funding guidance, and all 136 Foundry unit and integration tests.

---

## 2. File Inventory & Integrity

| File Path | Status | SHA-256 Digest | Description |
| :--- | :--- | :--- | :--- |
| `script/ops/crossguard_healthcheck.py` | Modified | `292389D97E393964DB2C305DCCB93453571E034773F25D890E3A7B8059B96B41` | Corrected 6-field callback ABI decoding, field semantics, reactive contract validation, and pending status handling |
| `test/ops/test_crossguard_healthcheck.py` | Modified | `B3E6F920F9FD8CF78499F04CBB39B56B16DC94BAA4AE9789C8639C29FF4863A2` | Expanded from 36 to 45 unit tests covering all 15 required regression scenarios for the corrected ABI schema |
| `docs/operations/CROSSGUARD-OPERATIONS-RUNBOOK.md` | Modified | `594D2E68DFF845E68BF1E1B3B5856EA9CF217B2AEEDCACD7C31D8D254B9F0180` | Updated Scenario 11 and 13 to document the corrected 6-field Reactive economy schema and diagnostic procedures |
| `README.md` | Modified | `B1F91FF8C1856B05496D697E238357F8E93DB1A033B92BAAF6597C46C23323A9` | Documented the official 6-field callback inspection parameters in the health-check overview |
| `docs/reports/M005-2-VERIFICATION-REPORT.md` | Added | *(Self-referential)* | This milestone verification report |

---

## 3. ABI Schema Reconciliation

### A. Comparison of M005.1 vs M005.2 (Official) Schema

| Field Position | Type | M005.1 Erroneous Field | M005.2 Official Field | Operational Diagnostic Role |
| :---: | :--- | :--- | :--- | :--- |
| **Field 1** | `uint256` | `destination_chain_id` | `blockNumber` | Reactive Lasna block height where callback was registered |
| **Field 2** | `address` | `to` (recipient) | `reactiveContract` | Requesting Reactive contract address (must equal `CrossGuardReactive`) |
| **Field 3** | `uint256` | `gas_limit` | `callbackIndex` | Sequential callback identifier for the transaction |
| **Field 4** | `uint256` | `gas_price` | `destinationChainId` | Destination network identifier (must equal `1301` for Unichain Sepolia) |
| **Field 5** | `uint256` | `tx_id` | `destinationTxHash` | Mined destination transaction hash (`0` if pending relay) |
| **Field 6** | `bytes` | `error` | `error` | Destination EVM execution revert data (empty `0x` for success) |

### B. EVM ABI Offset Map for Dynamic Array of Dynamic Tuples

Signature: `getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])`

```
Head Data:
[0x00 .. 0x20] : Offset to array data (0x20 = 32)
[0x20 .. 0x40] : Array element count N
[0x40 .. 0x40 + N*32] : Pointers to each tuple element T[i]

Each Tuple T[i] (192 bytes static head + dynamic tail):
Word 0 [0x00 .. 0x20] : blockNumber (uint256)
Word 1 [0x20 .. 0x40] : reactiveContract (address, 12 bytes zero padding + 20 bytes address at offset 44..64)
Word 2 [0x40 .. 0x60] : callbackIndex (uint256)
Word 3 [0x60 .. 0x80] : destinationChainId (uint256)
Word 4 [0x80 .. 0xa0] : destinationTxHash (uint256)
Word 5 [0xa0 .. 0xc0] : bytes_offset (offset to dynamic error bytes, 0xc0 = 192)
Tail   [0xc0 .. 0xe0] : error bytes length (uint256)
Tail   [0xe0 .. end ] : error bytes payload (padded to 32 bytes)
```

---

## 4. Callback Outcome Diagnostic Matrix

| Observation Condition | Status | Diagnostic Message | Remediation Action |
| :--- | :---: | :--- | :--- |
| **Malformed ABI / Parse Failure** | `ERROR` | `Failed to decode callback records ABI` | Inspect node response and System Contract interface |
| **Empty Callback Array (`[]` / `0x`)** | `UNKNOWN` | `Callback records are pending, not yet recorded, or unavailable` | Wait for cross-chain relaying; do not treat as confirmed failure |
| **Field 2 Mismatch (`reactiveContract`)** | `CRITICAL` | `Callback requesting Reactive contract mismatch` | Query corresponds to unauthorized third-party contract |
| **Field 4 Mismatch (`destinationChainId`)** | `CRITICAL` | `Callback destination chain ID mismatch` | Reconfigure destination chain ID on `CrossGuardReactive` |
| **Field 5 Zero (`destinationTxHash == 0`)** | `UNKNOWN` | `Callback recorded on Reactive Network, but destination transaction hash is zero (0)` | Destination transaction pending or unconfirmed; wait for block inclusion |
| **Field 6 Revert (`error.length > 0`)** | `CRITICAL` | `Callback execution recorded as FAILED on destination chain` | Inspect preserved revert data (e.g. `InvalidNonce`, gas exhaustion) |
| **Valid, non-zero hash, empty error** | `PASS` | `Callback execution recorded as SUCCESS on destination chain 1301` | Normal operations; callback execution confirmed on destination |

---

## 5. Required Regression Suite Verification (Section 4)

All 15 regression test requirements specified in Mission M005.2 are implemented and verified in `test/ops/test_crossguard_healthcheck.py`:

| Requirement | Test Name | Result |
| :--- | :--- | :---: |
| 1. Correct six-field record order | `test_37_callback_record_six_field_order` | **PASS** |
| 2. Correct destination chain ID in field four | `test_38_destination_chain_validation_reads_field_four` | **PASS** |
| 3. Correct Reactive contract address in field two | `test_39_reactive_contract_validation_reads_field_two` | **PASS** |
| 4. Correct callback index in field three | `test_40_callback_index_reads_field_three` | **PASS** |
| 5. Correct destination transaction hash in field five | `test_41_destination_tx_hash_reads_field_five` | **PASS** |
| 6. Successful callback | `test_15_successful_callback_record` & `test_27_callback_abi_single_success_hex` | **PASS** |
| 7. Failed callback with exact revert bytes | `test_16_failed_callback_record_with_error_data` & `test_28_callback_abi_single_failure_hex` | **PASS** |
| 8. Multiple successful records | `test_29_callback_multiple_successful_records` | **PASS** |
| 9. Mixed success and failure | `test_30_callback_mixed_outcomes` | **PASS** |
| 10. Wrong destination chain | `test_32_callback_wrong_destination_chain` | **PASS** |
| 11. Unexpected Reactive contract address | `test_42_unexpected_reactive_contract_triggers_critical` | **PASS** |
| 12. Zero or missing destination transaction hash | `test_33_callback_missing_destination_tx` & `test_45_callback_zero_destination_tx_hash_raw_hex` | **PASS** |
| 13. Empty callback array | `test_14_empty_callback_records` & `test_26_callback_abi_empty_array_hex` | **PASS** |
| 14. Malformed raw ABI | `test_31_callback_malformed_abi` | **PASS** |
| 15. Malformed formatted tuple | `test_43_malformed_formatted_tuple_field_count` & `test_44_malformed_formatted_tuple_invalid_data` | **PASS** |

---

## 6. Full Test Execution Evidence

### A. Python Operational Unit Tests

Command: `python -m unittest discover -s test/ops -p "test_*.py" -v`
```
Ran 45 tests in 0.012s
OK
```

### B. Foundry Unit & Integration Test Suite

Command: `forge test -vvv`
```
Ran 10 test suites in 220.45ms:
- test/unit/BorrowingController.t.sol: 21 passed, 0 failed, 0 skipped
- test/unit/CollateralVault.t.sol: 26 passed, 0 failed, 0 skipped
- test/unit/CrossGuardCallback.t.sol: 14 passed, 0 failed, 0 skipped
- test/unit/CrossGuardReactive.t.sol: 14 passed, 0 failed, 0 skipped
- test/unit/RiskController.t.sol: 16 passed, 0 failed, 0 skipped
- test/unit/TestValuationSource.t.sol: 6 passed, 0 failed, 0 skipped
- test/integration/CrossChainRiskFlow.t.sol: 5 passed, 0 failed, 0 skipped
- test/integration/M003_OriginDestinationIntegration.t.sol: 12 passed, 0 failed, 0 skipped
- test/integration/M004_AdversarialSecurity.t.sol: 18 passed, 0 failed, 0 skipped
- test/integration/M004_InvariantBreachRecovery.t.sol: 4 passed, 0 failed, 0 skipped

Total: 136 passed, 0 failed, 0 skipped (100% PASS)
```

### C. Formatting and Contract Size Verification

Commands:
- `forge fmt --check`: Clean (0 formatting violations).
- `forge build --sizes`: All contracts maintain $\ge 85.0\%$ safety headroom under Spurious Dragon 24,576 byte runtime limit:
  - `BorrowingController`: 2,829 B (21,747 B margin, 88.5% headroom)
  - `CollateralVault`: 3,499 B (21,077 B margin, 85.8% headroom)
  - `CrossGuardCallback`: 2,314 B (22,262 B margin, 90.6% headroom)
  - `CrossGuardReactive`: 3,684 B (20,892 B margin, 85.0% headroom)
  - `RiskController`: 1,826 B (22,750 B margin, 92.6% headroom)
  - `TestValuationSource`: 695 B (23,881 B margin, 97.2% headroom)

---

## 7. Acceptance Criteria Checklist

- [x] **Actual ABI field order implemented correctly:** Field 1 `blockNumber`, Field 2 `reactiveContract`, Field 3 `callbackIndex`, Field 4 `destinationChainId`, Field 5 `destinationTxHash`, Field 6 `error`.
- [x] **Destination chain validation reads field four:** Enforces `destinationChainId == UNICHAIN_SEPOLIA_CHAIN_ID` (`1301`).
- [x] **Reactive contract validation reads field two:** Enforces `reactiveContract == config["reactive_address"]`.
- [x] **Callback index reads field three:** Correctly mapped as `callback_index` (no gas limit interpretation).
- [x] **Destination transaction hash reads field five:** Correctly mapped as `destination_tx_hash` (no gas price interpretation).
- [x] **Error bytes preserved accurately:** Exact revert data preserved byte-for-byte in check evidence.
- [x] **Raw ABI and formatted output both tested:** Both parsing paths verified against real data encodings.
- [x] **All M005.1 safety fixes preserved:** Centralized credential redaction, bounded timeouts, strict binary exit codes, `depositTo` funding procedures.
- [x] **All 136 Foundry tests pass:** Zero regressions in protocol smart contracts.
- [x] **Python regression suite passes:** 45/45 tests passing with 100% success rate.
- [x] **Zero deployments, transactions, and expenditure:** Strictly ₹0 spent.

---

## 8. Commit & CI Execution Evidence

- **Parent Baseline Commit:** `158972a6f9d4151e9a7b7cc7cf4cdae983419070`
- **Implementation Commit:** `8b37179d46f7cbbac891746ba44a2575117243de`
- **Working Branch:** `fix/m002-2-omni-callback-correctness`
- **Remote:** `origin/fix/m002-2-omni-callback-correctness`
- **GitHub Actions CI Workflow Run:**
  - Run ID: `45238357872`
  - URL: `https://github.com/mahitss/Cross-Chain-Risk-Response-/actions/runs/45238357872`
  - Status: `completed`
  - Conclusion: `success`

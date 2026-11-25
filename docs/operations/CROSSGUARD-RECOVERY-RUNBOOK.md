# CrossGuard Cross-Chain Recovery Runbook

**Document Version:** 1.3.0
**Milestones:** M006, M006.1, M006.2 & M007.1 — Recovery Preflight Integrity, Drift Protection, Fee-Model Reconciliation & Canonical Identity Parity
**Target Topology:**
- **Origin Chain:** Base Sepolia (`84532`)
- **Reactive Engine:** Reactive Lasna (`5318007`)
- **Destination Chain:** Unichain Sepolia (`1301`)
**Scope:** Standard Operating Procedure (SOP) for Incident Response, Fail-Closed Preflight Diagnosis, M007.1 Cross-Chain Identity Wiring Verification, Deferred Dispatch Recovery (`DISPATCH_REQUIRED`), and Controlled Same-Nonce Retry (`RETRY_ELIGIBLE`)

---

## 1. Operational Overview & Safety Boundaries

CrossGuard automates cross-chain borrowing risk pauses by monitoring origin events on Base Sepolia and executing authenticated callbacks on Unichain Sepolia via Reactive Lasna. Under M006.1:
- **Durable Pending Dispatch (Path A):** If a valid origin event (`RiskBreach` or `RiskResolved`) arrives while `CrossGuardReactive` has an incomplete destination configuration (for example, Stage-1 deployment prior to running `ConfigureReactive.s.sol`), `CrossGuardReactive.react()` stores the payload with `DispatchStatus.PENDING_DISPATCH` and emits `CallbackDispatchDeferred` instead of losing the state update. Once configuration is complete, the owner invokes `dispatchPendingCallback(positionId, expectedNonce)` with zero retry quota consumed (`retryCount == 0`).
- **Controlled Same-Nonce Retry (Path B):** If a previously submitted callback (`DispatchStatus.REQUESTED`) fails on the destination chain due to EVM revert, destination gas exhaustion, or Callback Proxy funding/debt issues, the owner invokes `retryFailedCallback(positionId, expectedNonce, reasonCode)` once the underlying root cause is fixed.

### Core Operational Principles & Hard Policy Boundaries
1. **Never Diagnose or Recover Without Strict Preflight:** Always run `--recovery-preflight` supplying all three mandatory arguments: `--position-id`, `--expected-nonce`, and `--reactive-tx-hash`. Missing any argument fails closed with `RETRY_UNKNOWN` and non-zero exit code.
2. **Never Confuse Deferred Dispatch With Delivery Failure:** Never call `retryFailedCallback()` for a `DISPATCH_REQUIRED` position (`DispatchStatus.PENDING_DISPATCH`); `CrossGuardReactive` enforces `CallbackNotRequested()` and requires `dispatchPendingCallback()`. Conversely, `dispatchPendingCallback()` enforces `DispatchNotPending()` and cannot substitute for `retryFailedCallback()`.
3. **Same-Nonce Principle:** A failed destination callback rolls back destination EVM state, leaving `lastProcessedNonce` unchanged. Retries MUST target the exact stored origin nonce (`expectedNonce == latestCallback.nonce`) and payload. Never advance origin nonces artificially to retry.
4. **Strict Retry Quota:** A maximum of 3 retries (`MAX_RETRIES = 3`) are permitted per `REQUESTED` origin event. Valid newer origin transitions supersede earlier state and reset `retryCount` to `0`.
5. **No Unchecked Automated Mutations:** The `--recovery-preflight` diagnostic tool is strictly read-only. It never broadcasts transactions, never runs automated funding or retry loops, and intentionally keeps `suggested_command = None` (never emitting copy-paste `cast send` commands).
6. **Three-Way Recipient Drift Equality & Migration Policy (M006.2 P1):** Because `CrossGuardReactive.retryFailedCallback()` submits a retry to the **currently configured** `destinationCallback()`, historical `CallbackRequest` evidence alone is NOT sufficient. For `RETRY_ELIGIBLE`, preflight enforces exact 20-byte EVM equality across all three addresses: `expected_callback == historical_callback_request_recipient == current_destination_callback`. For `DISPATCH_REQUIRED`, preflight requires `expected_callback == current_destination_callback`. Any mismatch fails closed as `RETRY_BLOCKED` (or `RETRY_UNKNOWN` on historical mismatch/malformed address) and never auto-adopts a drifted callback address; operators must execute an explicitly reviewed configuration migration before recovering.
7. **Reconciled Payment Paths, Fee Formula & `_maxChargeGas` Semantics (M006.2 P2):**
   - Callback execution fees follow `fee = p_base * (C / 1000) * (g_used + K)` where `p_base = max(gas_price, base_fee)`, `C = _gasPriceCoeffPer1000`, and `K = _extraGas`.
   - `_maxChargeGas` limits gas available for payment-settlement execution only and is **never** added to or used as a cap on `(g_used + K)`.
   - Payment paths are strictly separated: **Destination Callback Proxy** debt or insufficient ETH reserves on Unichain Sepolia (`0x9299...7FC4`) is a hard blocker (`RETRY_BLOCKED`), whereas **Reactive System Contract** debt or low REACT reserves on Reactive Lasna (`0x8888...8888`) suspends automated `react()` execution and emits `REACTIVE_PATH_WARNING` without blocking owner EOA recovery transactions by default (use `--require-reactive-reserves` for conservative whole-pipeline blocking).
   - Configured `callbackGasLimit` is NOT exact forwarded destination execution gas (`_extraGas` + settlement overhead reduce forwarded gas strictly below configured limits). Any missing or malformed economic field fails closed as `RETRY_UNKNOWN`.
8. **Authoritative Event ABI Only (M006.2):** Only modern Omni `CallbackRequest(uint256 indexed chainId, address indexed sender, address indexed recipient, CallbackVersion version, bytes configuration)` (`version == 0` / `V_1_0` with valid inner `CallbackConfiguration_V_1_0`) is accepted. Legacy/mock `CallbackRequestedV1` signatures fail closed as `RETRY_UNKNOWN`.
9. **M007.1 Canonical Identity & Vault Domain Parity:** All operational health checks and `--recovery-preflight` diagnostics require `BASE_COLLATERAL_VAULT` (`--origin-collateral-vault`) and verify bytecode + cross-chain equality across `CollateralVault.riskController()`, `RiskController.authorizedVaults(vault)`, `CrossGuardReactive.originCollateralVault()`, `BorrowingController.trustedOriginChainId()` (`84532`), `BorrowingController.trustedOriginRiskController()`, and `BorrowingController.trustedOriginVault()`. Missing or mismatched origin vault / trusted-origin bindings fail closed (`RETRY_BLOCKED` / `RETRY_UNKNOWN`).
10. **Credential Isolation:** Never expose private keys, seed phrases, or unredacted RPC URLs in logs, terminal output, or incident reports.

---

## 2. Six-Phase Incident Response Procedure

```mermaid
flowchart TD
    P1["Phase 1: Detection & Alert Triaging"] --> P2["Phase 2: Evidence Collection & Strict Preflight"]
    P2 --> P3{"Phase 3: Deterministic Classification"}
    P3 -->|"RETRY_ALREADY_SUCCEEDED"| Done["Close Incident (No Action)"]
    P3 -->|"RETRY_PENDING"| Wait["Wait for Relayer / Record Finalization"]
    P3 -->|"RETRY_SUPERSEDED"| Origin["Evaluate Current Origin / Reactive State"]
    P3 -->|"RETRY_UNKNOWN"| P4["Phase 4: Fix RPC / Inputs / Economics Diagnostics"]
    P3 -->|"RETRY_BLOCKED"| P4["Phase 4: Remediate Debt / Reserves / Gas / Config"]
    P3 -->|"DISPATCH_REQUIRED"| PA["Path A (Phase 5A): Configure Dest & dispatchPendingCallback()"]
    P3 -->|"RETRY_ELIGIBLE"| PB["Path B (Phase 5B): Controlled Retry via retryFailedCallback()"]
    P4 --> P2
    PA --> P6["Phase 6: Post-Recovery Reconciliation"]
    PB --> P6
    P6 --> Done
```

---

### Phase 1: Detection & Alert Triaging
Identify an anomalous or stalled cross-chain state:
- **Symptom A:** An origin position on Base Sepolia has breached its risk threshold (`LTV >= 80%`), but borrowing remains active on Unichain Sepolia.
- **Symptom B:** Reactive Lasna health checker reports `CRITICAL` or `WARNING` status on `callback_record_inspection`.
- **Symptom C:** The routine operational health check reports outstanding debt on the Reactive System Contract or Callback Proxy.

**Initial Triage Action:**
Run the standard read-only operational health check:
```bash
python script/ops/crossguard_healthcheck.py --json
```

---

### Phase 2: Evidence Collection & Strict Preflight Diagnostics
Execute the read-only recovery preflight tool with all three mandatory correlation inputs (`--position-id`, `--expected-nonce`, and `--reactive-tx-hash`):
```bash
python script/ops/crossguard_healthcheck.py \
  --recovery-preflight \
  --origin-collateral-vault 0x<BASE_COLLATERAL_VAULT> \
  --position-id 0x<POSITION_ID_64_HEX_CHARS> \
  --expected-nonce <EXPECTED_NONCE> \
  --reactive-tx-hash 0x<REACTIVE_ORIGINATING_TX_HASH> \
  --safety-multiplier 2
```
*Note: Missing or invalid `--origin-collateral-vault` (or `BASE_COLLATERAL_VAULT` env), `--position-id`, `--expected-nonce` ($\ge 1$), or `--reactive-tx-hash` causes the tool to fail closed with `RETRY_UNKNOWN` (or `RETRY_BLOCKED` on zero vault address) and exit code `1`. `--safety-multiplier` expects an integer (default: `2`).*

The preflight tool inspects and correlates:
1. **Origin State & Vault Identity Pairing:** `positionNonce(bytes32)` and `isPositionBreached(bytes32)` on Base Sepolia `RiskController`, plus `CollateralVault.riskController()` and `RiskController.authorizedVaults(vault)`.
2. **Reactive State:** `latestOriginNonce(bytes32)`, 5-field `getLatestCallback(bytes32)` `(nonce, eventType, payload, retryCount, dispatchStatus)`, `originCollateralVault()`, and destination config (`destinationChainId`, `destinationCallback`, `callbackGasLimit >= 100_000`) on Reactive Lasna `CrossGuardReactive`.
3. **Destination State & Trusted Origin Anchors:** `lastProcessedNonce(bytes32)`, `isBorrowingPaused(bytes32)`, `pausedByRiskBreach(bytes32)`, `pausedByAdmin(bytes32)`, `trustedOriginChainId()`, `trustedOriginRiskController()`, and `trustedOriginVault()` on Unichain Sepolia `BorrowingController`.
4. **Economics & Reconciled Fee Reserves:** Separately reports `reactive_event_processing_path` (`SystemContract`, `REACT`, conservative operational warning by default unless `--require-reactive-reserves` is set) and `destination_callback_delivery_path` (`CallbackProxy`, `ETH`, hard delivery blocker on debt or shortfall), queries `_gasPriceCoeffPer1000()`, `_extraGas()`, `_maxChargeGas()`, and `gas-price` / `base-fee`, evaluates `fee = p_base * (C / 1000) * (gas_limit + extra_gas)`, tracks `_maxChargeGas` settlement gas independently (`--settlement-gas-requirement`), and fails closed (`RETRY_UNKNOWN`) on missing/malformed inputs or uint256 overflow.
5. **Receipt, Authoritative `CallbackRequest` ABI & 6-Field Callback Correlation:** Verifies `ReactiveBreachProcessed` / `ReactiveResolvedProcessed` / `CallbackDispatchDeferred` / `CallbackDispatchSubmitted` / `CallbackRetryRequested` and authoritative `CallbackRequest(uint256,address,address,uint8,bytes)` (`version == 0`, valid `CallbackConfiguration_V_1_0`, matching payload/chain/sender/recipient) using pure-Python Ethereum Keccak-256 topics (rejecting legacy `CallbackRequestedV1`), enforces 3-way recipient drift equality (`config_comparison`), and unambiguously correlates `getCallbacks(uint256)` 6-field tuples (`blockNumber`, `reactiveContract`, `callbackIndex`, `destinationChainId`, `destinationTxHash`, `error`).

> **Read-Only Guarantee:** `--recovery-preflight` keeps `suggested_command = None` across all outcomes and never emits executable `cast send` commands, never triggers auto-funding, and never runs automatic retry loops.

---

### Phase 3: Classification & Root Cause Identification

The preflight tool categorizes recovery eligibility into one of seven deterministic outcomes:

| Classification | Exit Code | Meaning | Required Operator Action |
|---|---|---|---|
| **`DISPATCH_REQUIRED`** | `0` | Valid origin event is stored on Reactive with `DispatchStatus.PENDING_DISPATCH`, `expected_callback == current_destination_callback`, destination wiring valid, and Callback Proxy funded cleanly. | Review any `REACTIVE_PATH_WARNING` alerts, then follow **Path A (Phase 5A): `dispatchPendingCallback()`**. |
| **`RETRY_ELIGIBLE`** | `0` | `REQUESTED` callback confirmed failed (non-empty `error` + nonzero matched `destinationTxHash`), destination nonce unadvanced, `retryCount < 3`, 3-way recipient equality (`expected == historical == current`) holds, valid `CallbackRequest` V1_0 config verified, Callback Proxy debt `== 0`, and proxy reserves adequate. | Review any `REACTIVE_PATH_WARNING` alerts, then proceed to **Path B (Phase 5B): `retryFailedCallback()`**. |
| **`RETRY_ALREADY_SUCCEEDED`** | `0` | Destination has already processed `expectedNonce` (`lastProcessedNonce >= expectedNonce`) without drift or contradictions. | Do NOT dispatch or retry. Incident is resolved; update monitoring. |
| **`RETRY_PENDING`** | `1` | Callback is `REQUESTED` and either `getCallbacks` array is empty or matched record has zero `destinationTxHash` with empty error (relayer in-flight / unconfirmed). Never inferred as failure or success. | Do NOT retry yet. Wait 2-5 minutes for relayer finalization and re-run preflight. |
| **`RETRY_SUPERSEDED`** | `1` | Origin `positionNonce` or Reactive `latestOriginNonce` or stored callback nonce has exceeded `expectedNonce`. | Do NOT dispatch or retry obsolete nonce. Re-run preflight against the latest nonce if still unpaused. |
| **`RETRY_BLOCKED`** | `1` | Recovery cannot proceed due to callback recipient drift (`expected != current` or `historical != current`), unconfigured destination, `callbackGasLimit < 100_000`, Callback Proxy debt `> 0`, insufficient Callback Proxy reserves, zero/insufficient `_maxChargeGas` settlement gas, retry limit exhausted (`3/3`), or conservative `--require-reactive-reserves` failure. | Proceed to **Phase 4** (Remediation / Reviewed Configuration Migration). Never override drift blindly. |
| **`RETRY_UNKNOWN`** | `1` | Missing mandatory input, malformed/truncated EVM address, RPC/ABI failure, unparseable fee telemetry, uint256 overflow, unsupported `CallbackVersion` / malformed `CallbackRequest` data / legacy `CallbackRequestedV1`, ambiguous multiple callback records, or cross-chain contradictions. | Resolve connectivity, input, receipt ABI, or contradiction before any state mutation. Never retry blindly. |

---

### Phase 4: Remediation of Underlying Cause

Before invoking `dispatchPendingCallback()` or `retryFailedCallback()`, every root cause blocking Phase 3 MUST be resolved manually (cross-chain debts and reserves are strictly tracked separately per chain):

#### Root Cause 0: Destination Callback Recipient Drift (`RETRY_BLOCKED`)
- **Diagnosis:** `expected_callback != current_destination_callback` or `historical_callback_request_recipient != current_destination_callback` in `configuration_comparison`. Because `CrossGuardReactive.retryFailedCallback()` dispatches to the **current** `destinationCallback()`, a recipient drift means historical evidence no longer authorizes the destination target.
- **Remediation:** Do NOT attempt to bypass drift via CLI address overrides. Operator must execute an explicitly reviewed configuration migration: verify `CrossGuardCallback.authorizedReactiveSender()`, `BorrowingController.callbackAdapter()`, and `CrossGuardReactive.setDestinationConfig(1301, <MIGRATED_CALLBACK>, <GAS >= 100000>)`, or trigger a fresh origin risk evaluation if recovering stale callbacks across migrated adapters.

#### Root Cause 1: Destination Unconfigured / Deferred Dispatch (`DISPATCH_REQUIRED` or `RETRY_BLOCKED`)
- **Diagnosis:** Origin event was stored with `DispatchStatus.PENDING_DISPATCH` while `destinationCallback == address(0)` or destination config was invalid.
- **Remediation:** Owner configures destination adapter (`chainId = 1301`, `callbackGasLimit >= 100_000`; `300_000` recommended):
  ```bash
  cast send <CROSSGUARD_REACTIVE_ADDRESS> \
    "setDestinationConfig(uint256,address,uint64)" 1301 <CROSSGUARD_CALLBACK_ADDRESS> 300000 \
    --rpc-url $REACTIVE_LASNA_RPC_URL \
    --private-key $OWNER_PRIVATE_KEY
  ```

#### Root Cause 2: Reactive System Contract Debt or Insufficient Reserves (`REACTIVE_PATH_WARNING` / Optional Conservative `RETRY_BLOCKED`)
- **Diagnosis:** System Contract `debt(reactiveContract) > 0` or `reserves(reactiveContract)` low on Reactive Lasna (`0x8888...8888`). Note this suspends future automated `react()` processing; manual owner `dispatchPendingCallback()`/`retryFailedCallback()` emits a `REACTIVE_PATH_WARNING` by default (blocked only under `--require-reactive-reserves`).
- **Remediation:** Deposit native `REACT` funds to the Reactive System Contract on Reactive Lasna (never send funds directly to `CrossGuardReactive.pay()` unless using `depositTo`):
  ```bash
  cast send 0x8888888888888888888888888888888888888888 \
    "depositTo(address)" <CROSSGUARD_REACTIVE_ADDRESS> \
    --value <AMOUNT_WEI> \
    --rpc-url $REACTIVE_LASNA_RPC_URL \
    --private-key $OPERATOR_PRIVATE_KEY
  ```

#### Root Cause 3: Outstanding Callback Proxy Debt or Insufficient Destination Reserves (`RETRY_BLOCKED`)
- **Diagnosis:** Callback Proxy `debt(callbackContract) > 0` OR net proxy reserves are below `estimated_callback_fee_wei * safety_multiplier` on Unichain Sepolia (`0x9299...7FC4`).
- **Remediation:** Deposit native `ETH` to the Callback Proxy on Unichain Sepolia:
  ```bash
  cast send 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4 \
    "depositTo(address)" <CROSSGUARD_CALLBACK_ADDRESS> \
    --value <AMOUNT_WEI> \
    --rpc-url $UNICHAIN_SEPOLIA_RPC_URL \
    --private-key $OPERATOR_PRIVATE_KEY
  ```

#### Root Cause 4: Insufficient Callback Gas Limit (`RETRY_BLOCKED`)
- **Diagnosis:** `callbackGasLimit < 100_000` (`MIN_CALLBACK_GAS_LIMIT`) or destination out-of-gas revert observed. Note `CrossGuardReactive` rejects any config or dispatch with `callbackGasLimit < 100_000`.
- **Remediation:** Owner updates destination config with `>= 100_000` gas (`300_000` recommended) via `setDestinationConfig(1301, <CROSSGUARD_CALLBACK_ADDRESS>, 300000)`.

#### Root Cause 5: Retry Budget Exhausted (`RETRY_BLOCKED`)
- **Diagnosis:** 3 retries have already been consumed (`retryCount == 3`, `DispatchStatus.REQUESTED`).
- **Remediation:** `retryFailedCallback()` is locked for this nonce. Operator must trigger a fresh risk evaluation on Base Sepolia (`evaluatePositionRisk`) if the risk condition requires a newer nonce, or execute governed emergency intervention on Unichain Sepolia (`emergencyPauseBorrowing` / `emergencyResumeBorrowing`).

---

### Phase 5: Controlled Dispatch or Retry Execution

Re-run Phase 2 `--recovery-preflight` after Phase 4 remediation to confirm either `DISPATCH_REQUIRED` (for Path A) or `RETRY_ELIGIBLE` (for Path B). Do not proceed under `RETRY_BLOCKED`, `RETRY_PENDING`, `RETRY_SUPERSEDED`, `RETRY_ALREADY_SUCCEEDED`, or `RETRY_UNKNOWN`.

#### Path A (Phase 5A): Initial Dispatch for Deferred Pending Callback (`DISPATCH_REQUIRED`)
Use ONLY when `getLatestCallback(positionId)` has `status == PENDING_DISPATCH (1)` and destination config is valid:
- Calls `dispatchPendingCallback(bytes32 positionId, uint256 expectedNonce)` as `onlyOwner`.
- Sets `status = REQUESTED (2)`, emits `CallbackDispatchSubmitted`, requests the Omni callback, and preserves `retryCount == 0` (does NOT burn any retry quota).
- Requires operator manual invocation (`--recovery-preflight` never outputs a copy-paste `cast send` command):
  - Contract: `<CROSSGUARD_REACTIVE_ADDRESS>` on Reactive Lasna (`5318007`)
  - Signature: `dispatchPendingCallback(bytes32,uint256)` with `<POSITION_ID>` and `<EXPECTED_NONCE>`

#### Path B (Phase 5B): Controlled Retry for Confirmed Delivery Failure (`RETRY_ELIGIBLE`)
Use ONLY when `getLatestCallback(positionId)` has `status == REQUESTED (2)`, `retryCount < 3`, and destination delivery failure is confirmed:
- Calls `retryFailedCallback(bytes32 positionId, uint256 expectedNonce, bytes32 reasonCode)` as `onlyOwner`.
- Increments `retryCount`, emits `CallbackRetryRequested(positionId, expectedNonce, retryAttempt, reasonCode)`, and re-requests the exact stored payload.
- Requires operator manual invocation (`--recovery-preflight` never outputs a copy-paste `cast send` command):
  - Contract: `<CROSSGUARD_REACTIVE_ADDRESS>` on Reactive Lasna (`5318007`)
  - Signature: `retryFailedCallback(bytes32,uint256,bytes32)` with `<POSITION_ID>`, `<EXPECTED_NONCE>`, and one of the standardized `bytes32 reasonCode` constants below.

#### Standard Supported Reason Codes (`bytes32` for Path B `retryFailedCallback`):

| Reason Code String | Hex Representation (`bytes32`) | Description |
|---|---|---|
| `RECOVERY_GAS_EXHAUSTION` | `0x5245434f564552595f4741535f45584841555354494f4e000000000000000000` | Prior callback failed due to destination out-of-gas. Gas limit was increased. |
| `RECOVERY_DESTINATION_REVERT` | `0x5245434f564552595f44455354494e4154494f4e5f5245564552540000000000` | Destination execution reverted due to transient logic or dependency failure. |
| `RECOVERY_PROXY_DEBT_CLEARED` | `0x5245434f564552595f50524f58595f444542545f434c45415245440000000000` | Callback was held due to proxy debt or insufficient reserves. Reserves replenished via `depositTo()`. |
| `RECOVERY_RELAY_TIMEOUT` | `0x5245434f564552595f52454c41595f54494d454f555400000000000000000000` | Relayer failed to deliver transaction within SLA window; re-requesting dispatch. |
| `RECOVERY_CONFIG_CORRECTED` | `0x5245434f564552595f434f4e4649475f434f5252454354454400000000000000` | Destination adapter or chain ID was misconfigured and has been updated. |

---

### Phase 6: Post-Recovery Reconciliation & Verification

1. **Verify Reactive Event Emission:**
   - **Path A:** Confirm `CallbackDispatchSubmitted(bytes32 indexed positionId, uint256 indexed nonce, CallbackType indexed eventType)` and Omni `CallbackRequest` were emitted, and `getLatestCallback(positionId).status == REQUESTED (2)` with `retryCount == 0`.
   - **Path B:** Confirm `CallbackRetryRequested(bytes32 indexed positionId, uint256 indexed nonce, uint8 retryAttempt, bytes32 reasonCode)` and Omni `CallbackRequest` were emitted.
2. **Verify Destination State Synchronization:**
   Query destination `BorrowingController` on Unichain Sepolia:
   ```bash
   cast call <BORROWING_CONTROLLER_ADDRESS> "lastProcessedNonce(bytes32)(uint256)" <POSITION_ID> --rpc-url $UNICHAIN_SEPOLIA_RPC_URL
   cast call <BORROWING_CONTROLLER_ADDRESS> "isBorrowingPaused(bytes32)(bool)" <POSITION_ID> --rpc-url $UNICHAIN_SEPOLIA_RPC_URL
   ```
   - `lastProcessedNonce` must equal `<EXPECTED_NONCE>` (or higher if a newer origin transition occurred).
   - `isBorrowingPaused` must match the intended risk state (or remain `true` if `pausedByAdmin` is set).
3. **Run Final Preflight Verification:**
   Re-running `--recovery-preflight` against `--position-id`, `--expected-nonce`, and the new reactive transaction hash should report `RETRY_ALREADY_SUCCEEDED` (or `RETRY_SUPERSEDED` if a newer event already arrived).
4. **Log Incident Report:** Record position ID, expected nonce, path taken (Path A `dispatchPendingCallback` vs Path B `retryFailedCallback`), reason code (if Path B), redacted telemetry, and both Reactive and Destination transaction hashes.

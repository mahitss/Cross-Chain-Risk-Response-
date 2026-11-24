# M006 & M006.1 — Controlled Callback Recovery & Cross-Chain Threat Model

**Document Version:** 1.1.0  
**Milestones:** M006 (Controlled Callback Recovery) & M006.1 (Recovery Preflight Integrity, Durable Event Dispatch & Failure Reconciliation)  
**Repository:** `mahitss/Cross-Chain-Risk-Response-`  
**Working Branch:** `fix/m002-2-omni-callback-correctness`  
**Topology:**  
- **Origin Chain:** Base Sepolia (`84532`)  
- **Reactive Engine:** Reactive Lasna (`5318007`)  
- **Destination Chain:** Unichain Sepolia (`1301`)  
**Security Category:** Threat Modeling, Adversarial Failure Modes, Recovery Invariants  

---

## 1. Executive Summary

Missions M006 and M006.1 establish protocol-level resilience against asynchronous cross-chain message failures, network partitioning, unconfigured-destination race windows, event replay, out-of-order deliveries, and false-positive recovery diagnostics. In cross-chain risk systems, failure to deliver an automated risk pause leaves borrowing markets vulnerable to insolvent collateral drain. Conversely, unrestricted or malformed recovery mechanisms introduce replay attack vectors or premature retry consumption.

This threat model analyzes 29 adversarial and operational failure vectors across CrossGuard's M006 and M006.1 architecture:
1. **Origin Event Idempotency:** Transition-only event emission in `RiskController.sol`.
2. **Reactive Monotonic Nonce Ordering & Durable Pending Dispatch:** Per-position ordering gates, `DispatchStatus.PENDING_DISPATCH` / `REQUESTED` lifecycle, and `dispatchPendingCallback()` in `CrossGuardReactive.sol`.
3. **Controlled Same-Nonce Retry:** Bounded (max 3), owner-gated recovery using exact stored payloads (`retryFailedCallback()`, restricted strictly to `REQUESTED` callbacks).
4. **Consistent Destination Minimum Gas Enforcement:** `MIN_CALLBACK_GAS_LIMIT = 100_000` enforced across constructor (including Stage-1 nonzero gas), `setDestinationConfig()`, `dispatchPendingCallback()`, and `retryFailedCallback()`.
5. **Destination Replay Protection:** Strictly monotonic nonce enforcement in `BorrowingController.sol`.
6. **Fail-Closed Read-Only Preflight Verification:** Mandatory 3-key correlation (`--position-id`, `--expected-nonce`, `--reactive-tx-hash`), pure-Python Ethereum Keccak-256 receipt matching, strict ABI decoding, fail-closed fee/reserve adequacy, and `suggested_command = None` in `crossguard_healthcheck.py`.

---

## 2. Cross-Chain Threat Matrix & Vector Analysis

### Threat Vector 1: Replay of Previous Callback Payload After Legitimate Resolution
- **Threat Description:** An adversary intercepts a prior `handleRiskBreach` callback payload and attempts to re-execute it on Unichain Sepolia after the borrower has brought their position back to a healthy collateral ratio and resolved the risk state.
- **Attacker Capability:** Attacker has access to public destination mempool and historical transaction data.
- **Expected Behavior:** Destination contract rejects the replayed callback transaction without pausing borrowing or corrupting the resolved state.
- **Protocol Mitigation:** `BorrowingController.pauseBorrowing` enforces strict nonce monotonicity: `require(nonce > lastProcessedNonce[positionId])`. Once resolution advances `lastProcessedNonce` (e.g. from 1 to 2), any replay of the breach callback with nonce 1 reverts with `InvalidNonce(1, 2)`.
- **Test Evidence:** `test/unit/M006Recovery.t.sol::test05_RetryAfterSuccessfulDeliveryRevertsOnDestination`, `test/unit/M004AdversarialSecurity.t.sol::testDuplicateAndStaleNonces`.
- **Residual Risk & Remaining Limitations:** If an attacker attempts relaying on Unichain, the transaction reverts; the attacker wastes gas with zero protocol state mutation.

---

### Threat Vector 2: Rapid Successive Breach Evaluations Causing Nonce Race
- **Threat Description:** A price oracle drops rapidly, causing multiple off-chain bots or collateral evaluations to query `assessRisk()` in rapid succession while the position remains breached.
- **Attacker Capability:** Any caller can invoke `evaluatePositionRisk()` on `CollateralVault` repeatedly during high volatility.
- **Expected Behavior:** `RiskController` emits exactly one `RiskBreach` event upon entering the breached state. Repeated evaluations while breached do not increment `positionNonce` and do not emit redundant `RiskBreach` events.
- **Protocol Mitigation:** Transition-only idempotency guard in `RiskController.sol`:
  ```solidity
  if (currentLtvBps >= riskThresholdBps) {
      isBreached = true;
      if (!isPositionBreached[positionId]) {
          isPositionBreached[positionId] = true;
          nonce = ++positionNonce[positionId];
          emit RiskBreach(...);
      } else {
          nonce = positionNonce[positionId];
      }
  }
  ```
- **Test Evidence:** `test/unit/RiskController.t.sol::testRepeatedBreachAssessmentsDoNotIncrementNonceOrEmitEvents`, `test/unit/M006Recovery.t.sol::test02_DuplicateOriginEvaluationIdempotency`.
- **Residual Risk & Remaining Limitations:** Off-chain listeners only receive one event per discrete state transition, preventing downstream subscription congestion.

---

### Threat Vector 3: Unauthorized Caller Invoking Retry Mechanism
- **Threat Description:** An unauthorized third party calls `retryFailedCallback()` on `CrossGuardReactive` to trigger arbitrary callbacks to Unichain Sepolia or grief system contract reserves.
- **Attacker Capability:** Any external account calling public functions on Reactive Lasna.
- **Expected Behavior:** The transaction immediately reverts without requesting a callback or incrementing the retry counter.
- **Protocol Mitigation:** `retryFailedCallback` is protected by OpenZeppelin's `onlyOwner` modifier. Calls from any account other than the designated contract owner revert with `OwnableUnauthorizedAccount`.
- **Test Evidence:** `test/unit/M006Recovery.t.sol::test09_UnauthorizedRetryReverts`, `test/unit/CrossGuardReactive.t.sol::testRetryFailedCallbackRevertsOnInvalidConditions`.
- **Residual Risk & Remaining Limitations:** Compromise of the owner private key would allow triggering retries; owner key must be a multisig or timelock in production.

---

### Threat Vector 4: Retrying with Arbitrary or Forged Callback Payloads
- **Threat Description:** An attacker or compromised operator attempts to pass arbitrary calldata into the retry mechanism to invoke unintended functions on destination contracts.
- **Attacker Capability:** Invoking retry interface with custom payload parameters.
- **Expected Behavior:** Reactive contract does not accept payload parameters from the caller; it exclusively re-dispatches the exact payload created and stored during the initial valid origin event interception.
- **Protocol Mitigation:** `CrossGuardReactive` stores `latestCallback[positionId].payload` internally during `react()`. `retryFailedCallback(positionId, expectedNonce, reasonCode)` takes no payload argument; it forwards `state.payload` directly to `systemContract.requestCallbackV_1_0`.
- **Test Evidence:** `test/unit/M006Recovery.t.sol::test04_SuccessfulSameNonceRecovery`, `test/integration/CrossGuardE2E.t.sol::testEndToEndControlledCallbackRecoveryLifecycle`.
- **Residual Risk & Remaining Limitations:** Payload integrity is strictly bound to the initial verified event log interception.

---

### Threat Vector 5: Retrying with Outdated Nonce After Position Has Recovered
- **Threat Description:** A transient breach occurs (nonce 1), but callback delivery fails. The borrower deposits collateral and recovers (nonce 2). An operator or automated script subsequently attempts to retry failed breach nonce 1.
- **Attacker Capability:** Operator initiates retry with stale nonce 1 after nonce 2 has been processed on Reactive Lasna.
- **Expected Behavior:** Reactive contract reverts the retry attempt, protecting the recovered position from being improperly re-paused.
- **Protocol Mitigation:** Strict nonce matching in `retryFailedCallback`:
  `if (state.nonce != expectedNonce) revert NonceMismatch(expectedNonce, state.nonce);`
  When resolution event nonce 2 arrives, `state.nonce` is updated to 2. A retry passing `expectedNonce = 1` reverts with `NonceMismatch(1, 2)`.
- **Test Evidence:** `test/unit/M006Recovery.t.sol::test07_OldRetryAfterNewerStateRejected`.
- **Residual Risk & Remaining Limitations:** If operator passes expectedNonce = 2, it would re-dispatch resolution, which is safe.

---

### Threat Vector 6: Infinite Retry Exhaustion Causing Destination Griefing / Debt
- **Threat Description:** A broken destination callback contract reverts continuously. An operator repeatedly retries, draining Reactive Lasna prepaid reserves and accumulating unpaid debt on destination Callback Proxy.
- **Attacker Capability:** Owner repeatedly invoking retry function.
- **Expected Behavior:** Retries are strictly capped at 3 attempts per origin event. The 4th attempt reverts fail-closed.
- **Protocol Mitigation:** `uint8 public constant MAX_RETRIES = 3;`. In `retryFailedCallback`:
  `if (state.retryCount >= MAX_RETRIES) revert RetryLimitExceeded(positionId, state.retryCount, MAX_RETRIES);`
  `state.retryCount++;`
  The counter only resets when a genuine new origin event with a higher nonce is processed by `react()`.
- **Test Evidence:** `test/unit/M006Recovery.t.sol::test08_RetryLimitEnforcement`, `test/unit/CrossGuardReactive.t.sol::testRetryFailedCallbackFullLifecycle`.
- **Residual Risk & Remaining Limitations:** Operator must diagnose and fix destination root cause before exhausting the 3 retries.

---

### Threat Vector 7: Cross-Chain Reordering Where Resolution Arrives Before Breach Callback
- **Threat Description:** Due to network latency or relayer routing, a `RiskResolved` callback (nonce 2) reaches Unichain Sepolia before the original `RiskBreach` callback (nonce 1).
- **Attacker Capability:** Exploiting variable network latency or asynchronous relayer queues.
- **Expected Behavior:** Resolution establishes unpaused state with nonce 2. When the delayed breach with nonce 1 subsequently arrives, it is rejected without pausing borrowing.
- **Protocol Mitigation:** `BorrowingController.resolveBorrowing` accepts nonce 2 and advances `lastProcessedNonce[positionId] = 2`. When breach nonce 1 arrives, `pauseBorrowing` enforces `require(nonce > lastProcessedNonce)`, which evaluates `1 > 2 == false` and reverts with `InvalidNonce(1, 2)`.
- **Test Evidence:** `test/unit/M004AdversarialSecurity.t.sol::testResolutionArrivingBeforeBreachConvergesSafely`.
- **Residual Risk & Remaining Limitations:** Resolution safely clears risk pause even if breach was skipped.

---

### Threat Vector 8: Cross-Chain Reordering Where Delayed Breach Arrives at Reactive Engine
- **Threat Description:** Origin logs are emitted in order (breach nonce 1, resolution nonce 2), but the Reactive Network Omni system delivers resolution log 2 to `CrossGuardReactive.react()` before breach log 1.
- **Attacker Capability:** Asynchronous log delivery across distributed nodes.
- **Expected Behavior:** Reactive contract processes resolution log 2 and advances `latestOriginNonce[positionId] = 2`. When delayed breach log 1 arrives, Reactive contract ignores it and emits `StaleOriginEventIgnored`.
- **Protocol Mitigation:** Monotonic origin nonce watermark in `CrossGuardReactive.react()`:
  `if (nonce <= latestOriginNonce[positionId]) { emit StaleOriginEventIgnored(positionId, nonce, latestOriginNonce[positionId]); emit ReactiveEventRejected(topic0, positionId, nonce, "STALE_OR_DUPLICATE_NONCE"); return; }`
- **Test Evidence:** `test/unit/M006Recovery.t.sol::test06_OutOfOrderEventHandling`, `test/unit/CrossGuardReactive.t.sol::testReactRejectsLowerNonce`.
- **Residual Risk & Remaining Limitations:** Reactive state never regresses to an older origin state.

---

### Threat Vector 9: Replaying Stale Origin Events Directly to Reactive Lasna
- **Threat Description:** An adversary captures raw origin `RiskBreach` event logs from Base Sepolia and attempts to trigger duplicate callbacks by submitting them to `CrossGuardReactive.react()`.
- **Attacker Capability:** Intercepting historical origin logs.
- **Expected Behavior:** Direct caller is rejected unless calling from the official Omni System Contract (`0x8888...8888`). If delivered through system contract, duplicate nonce is dropped by the monotonic nonce ordering check.
- **Protocol Mitigation:**
  1. `modifier onlySystem()` requires `msg.sender == address(systemContract)`.
  2. `if (nonce <= latestOriginNonce[positionId]) return;` drops any duplicate or lower nonce.
- **Test Evidence:** `test/unit/CrossGuardReactive.t.sol::testRevertReactUnauthorizedCaller`, `test/unit/CrossGuardReactive.t.sol::testReactRejectsDuplicateNonce`.
- **Residual Risk & Remaining Limitations:** Complete defense-in-depth across sender authentication and stateful monotonic gating.

---

### Threat Vector 10: Retrying a Position That Is Administratively Emergency-Paused
- **Threat Description:** An administrator has executed `emergencyPauseBorrowing()` on Unichain Sepolia due to an external protocol emergency. An automated recovery script triggers `retryFailedCallback()` for a resolved position, attempting to resume borrowing.
- **Attacker Capability:** Triggering callback execution during administrative pause.
- **Expected Behavior:** Risk resolution clears `pausedByRiskBreach`, but `isBorrowingPaused` remains strictly `true` because `pausedByAdmin` remains active.
- **Protocol Mitigation:** Independent state tracking in `BorrowingController.sol`:
  `isBorrowingPaused[positionId] = pausedByRiskBreach[positionId] || pausedByAdmin[positionId];`
  In `resolveBorrowing`:
  ```solidity
  pausedByRiskBreach[positionId] = false;
  if (!pausedByAdmin[positionId]) {
      isBorrowingPaused[positionId] = false;
  }
  ```
- **Test Evidence:** `test/unit/M006Recovery.t.sol::test12_AdministrativePauseProtection`, `test/unit/M004AdversarialSecurity.t.sol::testAdministrativePauseSurvivesRiskResolution`.
- **Residual Risk & Remaining Limitations:** Admin pause can only be unpaused by explicit owner call to `resumeBorrowing()` or `emergencyResumeBorrowing()`.

---

### Threat Vector 11: Callback Handling or Retry When Destination Adapter Is Unconfigured or Misconfigured
- **Threat Description:** A valid origin risk event arrives while `destinationCallback == address(0)` (e.g., Stage-1 deployment), or an operator attempts `dispatchPendingCallback()` / `retryFailedCallback()` while destination config is unset or invalid.
- **Attacker Capability:** Event timing during deployment window or invoking recovery during invalid configuration state.
- **Expected Behavior:** During `react()`, valid events are durably stored with `DispatchStatus.PENDING_DISPATCH` and `CallbackDispatchDeferred` is emitted (preventing silent event loss). Both `dispatchPendingCallback()` and `retryFailedCallback()` revert fail-closed with `DestinationNotConfigured()` until valid configuration is active (`destinationCallback != address(0)`, `destinationChainId == 1301`, `callbackGasLimit >= 100_000`).
- **Protocol Mitigation:**
  ```solidity
  // In dispatchPendingCallback() and retryFailedCallback():
  if (
      destinationCallback == address(0) || destinationChainId != UNICHAIN_SEPOLIA_CHAIN_ID
          || callbackGasLimit < MIN_CALLBACK_GAS_LIMIT
  ) {
      revert DestinationNotConfigured();
  }
  ```
- **Test Evidence:** `test/unit/M006Recovery.t.sol::test13_ConfigurationCorrection`, `test/unit/CrossGuardReactive.t.sol::testRetryFailedCallbackRevertsOnInvalidConditions`, `test/unit/CrossGuardReactive.t.sol::testDurablePendingDispatchLifecycle`.
- **Residual Risk & Remaining Limitations:** Operator must configure destination via `setDestinationConfig` before dispatching or retrying.

---

### Threat Vector 12: Zero Position ID, Zero Nonce, or Zero Reason Code Injection in Retry
- **Threat Description:** Caller invokes `retryFailedCallback` with null bytes or zero values for parameters.
- **Attacker Capability:** Passing edge-case parameters to retry function.
- **Expected Behavior:** Explicit reverts with descriptive custom errors: `InvalidPositionId()`, `InvalidReasonCode()`, or `NoCallbackPayloadStored()`.
- **Protocol Mitigation:**
  ```solidity
  if (positionId == bytes32(0)) revert InvalidPositionId();
  if (reasonCode == bytes32(0)) revert InvalidReasonCode();
  if (state.nonce == 0 || state.payload.length == 0) revert NoCallbackPayloadStored(positionId);
  ```
- **Test Evidence:** `test/unit/M006Recovery.t.sol::test10_InvalidRetryInputs`.
- **Residual Risk & Remaining Limitations:** Zero inputs fail-closed before any external calls or state changes.

---

### Threat Vector 13: System Contract Debt Blocking Callback Delivery
- **Threat Description:** Prepaid execution reserves on Reactive System Contract (`0x8888...8888`) are exhausted, causing the System Contract to record debt against `CrossGuardReactive`. Subsequent callback requests may be held or dropped.
- **Attacker Capability:** High message volume exhausting prepaid funds.
- **Expected Behavior:** System Contract accumulates debt. Recovery preflight tool flags status as `RETRY_BLOCKED` and instructs operator to deposit reserves before initiating retry.
- **Protocol Mitigation:**
  1. `crossguard_healthcheck.py --recovery-preflight` queries `debt(address)` on System Contract and halts retry recommendation if debt > 0.
  2. Remediation directs operator to `depositTo(reactiveContract)` on Reactive Lasna.
- **Test Evidence:** `test/ops/test_crossguard_healthcheck.py::test_52_preflight_blocked_system_contract_debt`, `test/unit/M006Recovery.t.sol::test14_InsufficientFundingDebtDiagnosis`.
- **Residual Risk & Remaining Limitations:** Operators must monitor reserves via healthcheck tool.

---

### Threat Vector 14: Callback Proxy Debt on Destination Chain Rejecting Callback
- **Threat Description:** `CrossGuardCallback` on Unichain Sepolia accumulates unpaid callback execution fees on the Callback Proxy (`0x9299...7FC4`). The Proxy rejects incoming callbacks.
- **Attacker Capability:** Depleted ETH balance on Unichain Sepolia.
- **Expected Behavior:** Callback Proxy reverts incoming callback execution. Recovery preflight identifies proxy debt > 0 and marks status as `RETRY_BLOCKED`.
- **Protocol Mitigation:** `run_recovery_preflight` checks `debt(address)` on Callback Proxy. Blocks retry and outputs remediation: `depositTo(callbackContract)` with native ETH on Unichain Sepolia.
- **Test Evidence:** `test/ops/test_crossguard_healthcheck.py::test_53_preflight_blocked_callback_proxy_debt`.
- **Residual Risk & Remaining Limitations:** Debt must be settled prior to triggering retry to ensure callback succeeds.

---

### Threat Vector 15: Cross-Position Cross-Talk / State Leakage During Retry
- **Threat Description:** Retrying a failed callback for Position A unintentionally mutates the nonce, retry counter, or pause state of Position B.
- **Attacker Capability:** Multiple positions undergoing concurrent risk transitions and recoveries.
- **Expected Behavior:** Each position maintains complete state isolation across Origin, Reactive Engine, and Destination.
- **Protocol Mitigation:** All storage mappings are strictly keyed by unique `bytes32 positionId`:
  `latestOriginNonce[positionId]`, `latestCallback[positionId]`, `lastProcessedNonce[positionId]`, `isBorrowingPaused[positionId]`.
- **Test Evidence:** `test/unit/M006Recovery.t.sol::test11_MultiPositionIsolation`, `test/unit/RiskController.t.sol::testSeparatePositionsMaintainSeparateNonceSequences`.
- **Residual Risk & Remaining Limitations:** Hash collisions on `bytes32 positionId` are cryptographically infeasible ($2^{256}$ space).

---

### Threat Vector 16: Malicious or Corrupted Reason Code Exploiting Off-Chain Parsers
- **Threat Description:** Operator supplies corrupted strings or injection strings in reason codes during retry, attempting to break JSON logging or indexing pipelines.
- **Attacker Capability:** Submitting arbitrary bytes32 as reasonCode.
- **Expected Behavior:** EVM treats `bytes32 reasonCode` as a fixed-length raw byte word. Emission in `CallbackRetryRequested` is strictly typed.
- **Protocol Mitigation:** `bytes32 reasonCode` enforces fixed 32-byte representation without string decoding in Solidity. Off-chain healthcheck sanitizes all inputs.
- **Test Evidence:** `test/unit/M006Recovery.t.sol::test15_FuzzRecoveryInvariants`.
- **Residual Risk & Remaining Limitations:** Standard operational runbook prescribes standardized hex reason codes (e.g., `RECOVERY_GAS_EXHAUSTION`).

---

### Threat Vector 17: Incomplete Destination Callback Execution Due to Gas Limit Exhaustion
- **Threat Description:** `callbackGasLimit` configured in `CrossGuardReactive` is insufficient to complete destination state updates and emit events, causing destination revert.
- **Attacker Capability:** Misconfiguring callback gas limit below the minimum safe threshold (`100_000`).
- **Expected Behavior:** Configuration updates, constructors (including Stage-1 nonzero gas limits), `dispatchPendingCallback()`, and `retryFailedCallback()` reject values below `MIN_CALLBACK_GAS_LIMIT` (`100_000`), and preflight blocks retry/dispatch below `100_000` gas.
- **Protocol Mitigation:**
  1. `CrossGuardReactive` enforces `callbackGasLimit >= MIN_CALLBACK_GAS_LIMIT (100_000)` uniformly across constructor, `setDestinationConfig()`, `dispatchPendingCallback()`, and `retryFailedCallback()` (`InvalidGasLimit` / `DestinationNotConfigured`).
  2. Preflight tool requires `callbackGasLimit >= 100_000` (recommends 300,000).
- **Test Evidence:** `test/ops/test_crossguard_healthcheck.py::test_56_preflight_blocked_gas_limit_too_low`, `test/unit/CrossGuardReactive.t.sol::testGasLimitMinimumValidation`, `test/unit/CrossGuardReactive.t.sol::testConstructorStageOneRejectsNonzeroGasBelowMinimum`, `test/unit/M006Recovery.t.sol::test04_SuccessfulSameNonceRecovery`.
- **Residual Risk & Remaining Limitations:** Gas limits must still be sized above the `100_000` floor for destination contract complexity (300,000 recommended).

---

### Threat Vector 18: Front-Running Retry Transaction by Malicious Actor
- **Threat Description:** An adversary sees an owner's retry or deferred-dispatch transaction in the Reactive Lasna mempool and attempts to front-run or sandwich it.
- **Attacker Capability:** Mempool monitoring on Reactive Lasna.
- **Expected Behavior:** Since both `dispatchPendingCallback` and `retryFailedCallback` are strictly `onlyOwner`, unauthorized third parties cannot execute either. Duplicate owner submissions revert (`DispatchNotPending` on second dispatch; destination `InvalidNonce` once delivered).
- **Protocol Mitigation:** Strict access control (`onlyOwner`), `DispatchStatus` state transitions, and destination nonce watermark (`nonce > lastProcessedNonce`) prevent third-party exploitation.
- **Test Evidence:** `test/unit/CrossGuardReactive.t.sol::testRetryFailedCallbackRevertsOnInvalidConditions`, `test/unit/CrossGuardReactive.t.sol::testDurablePendingDispatchLifecycle`, `test/unit/M006Recovery.t.sol::test05_RetryAfterSuccessfulDeliveryRevertsOnDestination`.
- **Residual Risk & Remaining Limitations:** Once delivery succeeds on destination, any subsequent redundant delivery is safely rejected by `InvalidNonce`.

---

### Threat Vector 19: Valid Origin Risk Event Lost Forever During Stage-1 Unconfigured Destination Window
- **Threat Description:** Under M006, if a valid `RiskBreach` or `RiskResolved` event arrived before `ConfigureReactive.s.sol` linked `destinationCallback`, `CrossGuardReactive.react()` rejected it with `"DESTINATION_NOT_CONFIGURED"` without recording `latestOriginNonce` or `latestCallback`. Because `RiskController` suppresses duplicate emissions, that transition was permanently lost for retry.
- **Attacker / Failure Mode:** Asynchronous timing gap between `DeployOrigin`/`DeployReactive` and `ConfigureReactive.s.sol`.
- **Expected Behavior:** Valid origin events are durably stored (`DispatchStatus.PENDING_DISPATCH`, `retryCount = 0`) even when destination configuration is incomplete, emitting `CallbackDispatchDeferred`.
- **Protocol Mitigation:** `CrossGuardReactive.react()` validates event integrity first, commits `latestOriginNonce` and `CallbackState` (`PENDING_DISPATCH`), and defers only the `systemContract.requestCallbackV_1_0(...)` call until owner configures destination and calls `dispatchPendingCallback()`.
- **Test Evidence:** `test/unit/CrossGuardReactive.t.sol::testDurablePendingDispatchLifecycle`, `test/unit/CrossGuardReactive.t.sol::testDeployWithUnsetDestinationCallbackAndConfigureLater`, `test/integration/CrossGuardE2E.t.sol::testEndToEndDeferredDispatchAndControlledRecovery`.
- **Residual Risk & Remaining Limitations:** Operator monitoring must alert on `CallbackDispatchDeferred` / `DISPATCH_REQUIRED` and run `dispatchPendingCallback()`.

---

### Threat Vector 20: Duplicate Manual Dispatch via `dispatchPendingCallback()`
- **Threat Description:** Operator accidentally submits two `dispatchPendingCallback(positionId, expectedNonce)` transactions for the same pending event, or attempts to re-dispatch after initial dispatch succeeded or failed.
- **Attacker Capability:** Double-submission by operator or mempool replay of owner transaction.
- **Expected Behavior:** The first call atomically transitions `status` from `PENDING_DISPATCH` to `REQUESTED` before external call; the second call reverts fail-closed with `DispatchNotPending()`.
- **Protocol Mitigation:** Strict Checks-Effects-Interactions transition (`if (state.status != DispatchStatus.PENDING_DISPATCH) revert DispatchNotPending(); state.status = DispatchStatus.REQUESTED;`) and revert propagation on `requestCallbackV_1_0` failure.
- **Test Evidence:** `test/unit/CrossGuardReactive.t.sol::testDurablePendingDispatchLifecycle`, `test/unit/CrossGuardReactive.t.sol::testExternalSystemRequestFailureRevertsAtomicallyAndPreservesState`, `test/unit/M006Recovery.t.sol::invariant_PendingAndRequestedNeverConfused`.
- **Residual Risk & Remaining Limitations:** If the first `dispatchPendingCallback` succeeds at Reactive Lasna but fails at destination, subsequent recovery must use `retryFailedCallback()`.

---

### Threat Vector 21: Premature Consumption of Retry Quota While Event Is Still `PENDING_DISPATCH`
- **Threat Description:** Operator mistakenly calls `retryFailedCallback()` instead of `dispatchPendingCallback()` on a deferred event, burning the limited 3-attempt retry quota or dispatching without `CallbackDispatchSubmitted` provenance.
- **Attacker Capability:** Operator tooling/runbook confusion between deferred dispatch and destination failure retry.
- **Expected Behavior:** `retryFailedCallback()` reverts fail-closed with `CallbackNotRequested()` whenever `state.status != DispatchStatus.REQUESTED`; initial dispatch must use `dispatchPendingCallback()`, leaving `retryCount == 0`.
- **Protocol Mitigation:** `DispatchStatus` enum separation in `CrossGuardReactive.sol` plus `DISPATCH_REQUIRED` status separation in `crossguard_healthcheck.py`.
- **Test Evidence:** `test/unit/M006Recovery.t.sol::test16_DeferredPendingDispatchCannotBeRetriedUntilSubmitted`, `test/unit/M006Recovery.t.sol::invariant_PendingAndRequestedNeverConfused`, `test/ops/test_crossguard_healthcheck.py::test_75_dispatch_required_on_deferred_event`.
- **Residual Risk & Remaining Limitations:** Strict on-chain state gating guarantees `retryFailedCallback` cannot run on `PENDING_DISPATCH` states.

---

### Threat Vector 22: False-Positive `RETRY_ELIGIBLE` Classification When Delivery Actually Succeeded or Is In-Flight
- **Threat Description:** Under incomplete evidence, a preflight check misclassifies an unconfirmed callback or destination-lagging read as `RETRY_ELIGIBLE`, prompting unnecessary retries that waste quota.
- **Attacker / Failure Mode:** Race condition with relayer delivery (`destinationTxHash == 0`) or stale read across chains.
- **Expected Behavior:** `RETRY_ELIGIBLE` requires explicit destination failure evidence (`non-empty error` AND `nonzero destinationTxHash`) alongside `lastProcessedNonce < expectedNonce`, clear debts, adequate reserves, and verified receipt correlation. Records with `destinationTxHash == 0` and empty error stay `RETRY_PENDING`; records with `error` bytes and `destinationTxHash == 0` fail closed as `RETRY_UNKNOWN`.
- **Protocol Mitigation:** Strict multi-condition gate in `run_recovery_preflight()` (`crossguard_healthcheck.py`) plus `CallbackRequest` correlation.
- **Test Evidence:** `test/ops/test_crossguard_healthcheck.py::test_48_preflight_contradictory_empty_error_with_dest_behind`, `test_49_preflight_pending_zero_destination_tx_hash`, `test_78_error_bytes_with_zero_destination_tx_hash`, `test_82_three_state_contradictions_return_unknown`.
- **Residual Risk & Remaining Limitations:** If relayer confirmed delivery with a receipt after the snapshot, destination `BorrowingController` still blocks duplicate execution via `InvalidNonce`.

---

### Threat Vector 23: Wrong `--reactive-tx-hash` Receipt Supplied During Preflight Correlation
- **Threat Description:** Operator pastes a Reactive transaction hash belonging to an unrelated transaction, failed tx (`status == 0`), wrong contract emitter, or missing `CallbackRequest`.
- **Attacker / Failure Mode:** Human copy-paste error or spoofed/malformed receipt data.
- **Expected Behavior:** Preflight fails closed as `RETRY_UNKNOWN` if receipt is missing, reverted (`status != 0x1`), malformed JSON, emitted by wrong `CrossGuardReactive` address, missing valid `CallbackRequest` log, or missing expected event topic.
- **Protocol Mitigation:** Pure-Python Ethereum Keccak-256 event signature derivation (`keccak256_topic`, using `0x01` Keccak domain separator verified against `cast keccak`) matching `ReactiveBreachProcessed`, `ReactiveResolvedProcessed`, `CallbackDispatchDeferred`, `CallbackDispatchSubmitted`, `CallbackRetryRequested`, and Omni `CallbackRequest`.
- **Test Evidence:** `test/ops/test_crossguard_healthcheck.py::test_69_receipt_missing_or_reverted`, `test_70_malformed_receipt_json`, `test_74_receipt_callback_request_validation_failures`, `test_84_ethereum_keccak256_event_signature_verification`, `test_87_wrong_crossguard_emitter_and_multiple_callback_requests`.
- **Residual Risk & Remaining Limitations:** Relies on authentic Reactive Lasna JSON-RPC receipt responses.

---

### Threat Vector 24: Wrong `--position-id` or Wrong `--expected-nonce` Supplied to Preflight
- **Threat Description:** Operator investigates Position A using Position B's receipt hash or passes an outdated/mismatched `--expected-nonce`.
- **Attacker / Failure Mode:** Operator confusion during multi-position incidents.
- **Expected Behavior:** Preflight checks indexed `positionId`, `nonce`, and `eventType` inside the receipt events against CLI inputs and `latestCallback(positionId)` / origin `positionNonce(positionId)` / destination `lastProcessedNonce(positionId)`; mismatches return `RETRY_UNKNOWN` (or `RETRY_SUPERSEDED` if superseded by a newer nonce).
- **Protocol Mitigation:** Mandatory `--position-id`, `--expected-nonce`, and `--reactive-tx-hash` CLI flags and cross-chain nonce/type consistency checks in `run_recovery_preflight()`.
- **Test Evidence:** `test/ops/test_crossguard_healthcheck.py::test_68_missing_mandatory_inputs_return_unknown`, `test_71_receipt_position_mismatch`, `test_72_receipt_nonce_mismatch`, `test_73_receipt_multiple_conflicting_events`, `test_76_deferred_receipt_superseded_and_mismatch_states`, `test_90_cli_missing_mandatory_args_exits_nonzero_with_unknown`.
- **Residual Risk & Remaining Limitations:** None within documented 3-chain lookup semantics.

---

### Threat Vector 25: Ambiguous Matching Across Multiple `getCallbacks` Records
- **Threat Description:** `getCallbacks(uint256)` returns multiple records for a block/transaction or contains records for multiple chains/contracts/indices, risking evaluating the wrong callback's `error` or `destinationTxHash`.
- **Attacker / Failure Mode:** Multiple Reactive callbacks originating from the same reactive block or multi-callback batch.
- **Expected Behavior:** Preflight filters strictly for `reactiveContract == reactive_address` and `destinationChainId == 1301`. If ambiguity remains (multiple non-uniform valid records that cannot be deterministically disambiguated) or if `callbackRequest` correlation cannot isolate the record, preflight fails closed with `RETRY_UNKNOWN`.
- **Protocol Mitigation:** Unambiguous record matching logic in `run_recovery_preflight()` (`crossguard_healthcheck.py`).
- **Test Evidence:** `test/ops/test_crossguard_healthcheck.py::test_77_callback_records_unambiguous_and_ambiguous_matching`, `test_86_callback_lookup_exception_and_malformed_abi`.
- **Residual Risk & Remaining Limitations:** Operators must resolve ambiguous historical transactions via block-explorer forensic trace before intervening.

---

### Threat Vector 26: RPC Query Failure or Malformed ABI Response Treated as Zero Debt or Healthy State
- **Threat Description:** An unstable RPC endpoint returns `"0x"`, malformed hex, timeout, or non-integer response during debt, reserve, nonce, or `getLatestCallback` inspection. If coerced silently to `0`, tooling might report `debt == 0` and approve an unsafe retry.
- **Attacker / Failure Mode:** Degraded RPC infrastructure, rate-limiting HTML/JSON error leaked into parser, or proxy upgrade schema drift.
- **Expected Behavior:** Strict typed decoders (`decode_uint_strict`, `decode_bool_strict`, `decode_address_strict`, `decode_bytes_strict`, `decode_get_latest_callback_strict`) raise exceptions on empty/non-canonical/oversized inputs, immediately classifying preflight as `RETRY_UNKNOWN`.
- **Protocol Mitigation:** Fail-closed parsing across all origin, reactive, destination, economic, and fee queries (`_safe_int` / heuristic zero fallback completely eliminated from preflight economic & state paths).
- **Test Evidence:** `test/ops/test_crossguard_healthcheck.py::test_79_economic_queries_fail_closed_never_zero`, `test_85_strict_decoders`.
- **Residual Risk & Remaining Limitations:** Temporary RPC downtime blocks preflight automation (intended fail-closed behavior).

---

### Threat Vector 27: Callback Reserve Exhaustion Falsely Masked by `reserves > debt` Check
- **Threat Description:** A Callback Proxy account holds `debt == 0` and `1 wei` in `reserves` — enough to pass a naive `reserves >= debt` check, yet completely insufficient to cover an actual destination callback gas fee, causing an immediate post-retry out-of-funds hold.
- **Attacker / Failure Mode:** Near-depleted proxy ETH reserve on Unichain Sepolia during elevated base fees.
- **Expected Behavior:** Preflight queries Callback Proxy parameters (`_gasPriceCoeffPer1000()`, `_extraGas()`, `_maxChargeGas()`) and Unichain fee telemetry (`gas-price`, `base-fee`), computes `estimated_callback_fee_wei`, enforces `net_reserves >= estimated_callback_fee_wei * safety_multiplier` (default integer `2`), and classifies shortfalls as `RETRY_BLOCKED` (or missing/zero fee telemetry as `RETRY_UNKNOWN`).
- **Protocol Mitigation:** Fail-closed `estimate_callback_fee_wei()` and reserve adequacy validation in `crossguard_healthcheck.py`.
- **Test Evidence:** `test/ops/test_crossguard_healthcheck.py::test_80_insufficient_or_zero_reserves_blocked`, `test_81_fee_estimator_formula_and_assumptions`, `test_89_newer_reactive_nonce_and_zero_gas_price_fail_closed`.
- **Residual Risk & Remaining Limitations:** Assumes fee multiplier (`--safety-multiplier 2`) covers normal base-fee volatility between preflight and execution.

---

### Threat Vector 28: Nonzero Sub-100k Gas Limit Accepted During Stage-1 Deployment
- **Threat Description:** During two-stage deployment (`destinationCallback == address(0)`), a constructor invocation passes `_gasLimit = 50_000` (below `MIN_CALLBACK_GAS_LIMIT = 100_000`), leaving inconsistent validation between Stage-1 constructor and `setDestinationConfig()`.
- **Attacker / Failure Mode:** Deployment script misconfiguration.
- **Expected Behavior:** Constructor explicitly rejects any nonzero `_gasLimit < 100_000` even when `_destCallback == address(0)` (`if (_gasLimit != 0 && _gasLimit < MIN_CALLBACK_GAS_LIMIT) revert InvalidGasLimit(_gasLimit);`).
- **Protocol Mitigation:** Unified `MIN_CALLBACK_GAS_LIMIT = 100_000` invariant across all entrypoints in `CrossGuardReactive.sol`.
- **Test Evidence:** `test/unit/CrossGuardReactive.t.sol::testConstructorStageOneRejectsNonzeroGasBelowMinimum`, `test/unit/CrossGuardReactive.t.sol::testGasLimitMinimumValidation`.
- **Residual Risk & Remaining Limitations:** Stage-1 deploys with `_gasLimit == 0` remain permitted specifically because `callbackGasLimit` is stored as `0` until `setDestinationConfig` sets a value `>= 100_000`.

---

### Threat Vector 29: Dispatch of Superseded `PENDING_DISPATCH` Event After Newer Origin Transition
- **Threat Description:** Position transitions `Breach (nonce 1, PENDING_DISPATCH)` and before owner calls `dispatchPendingCallback(pos, 1)`, position transitions to `Resolved (nonce 2)` which supersedes nonce 1. Operator subsequently submits `dispatchPendingCallback(pos, 1)`.
- **Attacker / Failure Mode:** Asynchronous race between origin state recovery and delayed operator action.
- **Expected Behavior:** When nonce 2 arrives while nonce 1 is `PENDING_DISPATCH`, `react()` emits `PendingCallbackSuperseded(pos, 1, 2)` and overwrites `latestCallback[pos]` with nonce 2. Subsequent `dispatchPendingCallback(pos, 1)` reverts fail-closed with `NonceMismatch(1, 2)`.
- **Protocol Mitigation:** `PendingCallbackSuperseded` audit event plus strict `state.nonce == expectedNonce` guard in `dispatchPendingCallback()` and `retryFailedCallback()`.
- **Test Evidence:** `test/unit/CrossGuardReactive.t.sol::testPendingDispatchSupersededByNewerOriginEvent`, `test/ops/test_crossguard_healthcheck.py::test_89_newer_reactive_nonce_and_zero_gas_price_fail_closed`.
- **Residual Risk & Remaining Limitations:** Operator must monitor for `PendingCallbackSuperseded` and re-run preflight with the latest nonce (`2`).

---

## 3. Summary of Invariant Verifications

| Invariant ID | Security Property | Enforcing Contract / Component | Verification Test |
|---|---|---|---|
| **INV-01** | Transition-Only Risk Breach Emission | `RiskController.sol` | `testRepeatedBreachAssessmentsDoNotIncrementNonceOrEmitEvents` |
| **INV-02** | Monotonic Origin Nonce Gating | `CrossGuardReactive.sol` | `testReactRejectsDuplicateNonce`, `testReactRejectsLowerNonce`, `invariant_AcceptedNoncesNeverDecrease` |
| **INV-03** | Exact Stored Payload Retry Integrity | `CrossGuardReactive.sol` | `testRetryFailedCallbackFullLifecycle`, `invariant_NoDuplicateOrStaleDestinationApplication` |
| **INV-04** | Bounded Retry Budget ($\le 3$) | `CrossGuardReactive.sol` | `test08_RetryLimitEnforcement`, `invariant_RetryCountNeverExceedsThree` |
| **INV-05** | Destination Nonce Monotonicity | `BorrowingController.sol` | `testRevertWhenDuplicateNonce`, `test05_RetryAfterSuccessfulDeliveryRevertsOnDestination`, `invariant_DestinationProcessedNoncesNeverDecrease` |
| **INV-06** | Multi-Position Isolation | All Contracts | `test11_MultiPositionIsolation`, `invariant_PositionIsolationPreserved` |
| **INV-07** | Administrative Pause Invariance | `BorrowingController.sol` | `test12_AdministrativePauseProtection` |
| **INV-08** | Read-Only Recovery Preflight Safety | `crossguard_healthcheck.py` | `test_46_preflight_eligible_destination_failure` through `test_67_recovery_exit_code_behavior` |
| **INV-09** | Durable `PENDING_DISPATCH` & `REQUESTED` Separation | `CrossGuardReactive.sol` | `test16_DeferredPendingDispatchCannotBeRetriedUntilSubmitted`, `invariant_PendingAndRequestedNeverConfused` |
| **INV-10** | Atomic Revert Preservation on External Call Failure | `CrossGuardReactive.sol` | `testExternalSystemRequestFailureRevertsAtomicallyAndPreservesState` |
| **INV-11** | Uniform Minimum Callback Gas Limit ($100,000$) | `CrossGuardReactive.sol` | `testGasLimitMinimumValidation`, `testConstructorStageOneRejectsNonzeroGasBelowMinimum` |
| **INV-12** | Mandatory 3-Key Preflight Correlation & Keccak-256 Receipts | `crossguard_healthcheck.py` | `test_68_missing_mandatory_inputs_return_unknown` through `test_74`, `test_84_ethereum_keccak256_event_signature_verification` |
| **INV-13** | Fail-Closed Economic Decoding & Reserve Adequacy | `crossguard_healthcheck.py` | `test_79_economic_queries_fail_closed_never_zero`, `test_80_insufficient_or_zero_reserves_blocked`, `test_81_fee_estimator_formula_and_assumptions`, `test_85_strict_decoders`, `test_89_newer_reactive_nonce_and_zero_gas_price_fail_closed` |
| **INV-14** | No Emitted Mutating Command (`suggested_command = None`) | `crossguard_healthcheck.py` | `test_66_preflight_report_safety_disclaimer_and_no_cast_send`, `test_75_dispatch_required_on_deferred_event`, `test_90_cli_missing_mandatory_args_exits_nonzero_with_unknown` |

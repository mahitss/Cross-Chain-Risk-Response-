# M006 — Controlled Callback Recovery & Cross-Chain Threat Model

**Document Version:** 1.0.0  
**Milestone:** M006 — Controlled Callback Recovery, Event Idempotency & Cross-Chain Reconciliation  
**Repository:** `mahitss/Cross-Chain-Risk-Response-`  
**Working Branch:** `fix/m002-2-omni-callback-correctness`  
**Topology:**  
- **Origin Chain:** Base Sepolia (`84532`)  
- **Reactive Engine:** Reactive Lasna (`5318007`)  
- **Destination Chain:** Unichain Sepolia (`1301`)  
**Security Category:** Threat Modeling, Adversarial Failure Modes, Recovery Invariants  

---

## 1. Executive Summary

Mission M006 establishes protocol-level resilience against asynchronous cross-chain message failures, network partitioning, event replay, and out-of-order deliveries. In cross-chain risk systems, failure to deliver an automated risk pause leaves borrowing markets vulnerable to insolvent collateral drain. Conversely, unrestricted or malformed recovery mechanisms introduce replay attack vectors that could permanently freeze healthy borrowing positions or bypass legitimate state transitions.

This threat model analyzes the 18 critical failure modes and adversarial vectors governing CrossGuard's M006 architecture:
1. **Origin Event Idempotency:** Transition-only event emission in `RiskController.sol`.
2. **Reactive Monotonic Nonce Ordering:** Per-position ordering gates in `CrossGuardReactive.sol`.
3. **Controlled Same-Nonce Retry:** Bounded (max 3), owner-gated recovery using exact stored payloads.
4. **Destination Replay Protection:** Strictly monotonic nonce enforcement in `BorrowingController.sol`.
5. **Read-Only Preflight Verification:** Comprehensive state classification via `crossguard_healthcheck.py`.

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

### Threat Vector 11: Retrying Callback When Destination Adapter Is Unconfigured or Misconfigured
- **Threat Description:** An operator calls `retryFailedCallback()` before `destinationCallback` has been set or after an invalid configuration update.
- **Attacker Capability:** Invoking retry during unconfigured or invalid destination state.
- **Expected Behavior:** Reactive contract reverts fail-closed with `DestinationNotConfigured()`.
- **Protocol Mitigation:**
  ```solidity
  if (destinationCallback == address(0) || destinationChainId != UNICHAIN_SEPOLIA_CHAIN_ID || callbackGasLimit == 0) {
      revert DestinationNotConfigured();
  }
  ```
- **Test Evidence:** `test/unit/M006Recovery.t.sol::test13_ConfigurationCorrection`, `test/unit/CrossGuardReactive.t.sol::testRetryFailedCallbackRevertsOnInvalidConditions`.
- **Residual Risk & Remaining Limitations:** Operator must configure destination via `setDestinationConfig` before retrying.

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
- **Attacker Capability:** Misconfiguring callback gas limit below execution requirements.
- **Expected Behavior:** Transaction reverts on destination EVM; destination nonce is not advanced; retry preflight flags low gas limit and blocks retry until configured >= 100,000 gas.
- **Protocol Mitigation:**
  1. `CrossGuardReactive.setDestinationConfig` requires `_gasLimit > 0`.
  2. Preflight tool requires `callbackGasLimit >= 100_000` (recommends 300,000).
- **Test Evidence:** `test/ops/test_crossguard_healthcheck.py::test_56_preflight_blocked_gas_limit_too_low`, `test/unit/M006Recovery.t.sol::test04_SuccessfulSameNonceRecovery`.
- **Residual Risk & Remaining Limitations:** Gas limits must be verified against destination contract bytecode complexity.

---

### Threat Vector 18: Front-Running Retry Transaction by Malicious Actor
- **Threat Description:** An adversary sees an owner's retry transaction in the Reactive Lasna mempool and attempts to front-run or sandwich it.
- **Attacker Capability:** Mempool monitoring on Reactive Lasna.
- **Expected Behavior:** Since `retryFailedCallback` is strictly `onlyOwner`, unauthorized third parties cannot execute the retry. If an attacker submits a duplicate owner transaction, only one succeeds; subsequent attempts increment retry counter or revert if limit is reached.
- **Protocol Mitigation:** Strict access control (`onlyOwner`) and destination nonce watermark (`nonce > lastProcessedNonce`) prevent third-party exploitation.
- **Test Evidence:** `test/unit/CrossGuardReactive.t.sol::testRetryFailedCallbackRevertsOnInvalidConditions`, `test/unit/M006Recovery.t.sol::test05_RetryAfterSuccessfulDeliveryRevertsOnDestination`.
- **Residual Risk & Remaining Limitations:** Once the first retry succeeds on destination, any subsequent redundant delivery is safely rejected by `InvalidNonce`.

---

## 3. Summary of Invariant Verifications

| Invariant ID | Security Property | Enforcing Contract | Verification Test |
|---|---|---|---|
| **INV-01** | Transition-Only Risk Breach Emission | `RiskController.sol` | `testRepeatedBreachAssessmentsDoNotIncrementNonceOrEmitEvents` |
| **INV-02** | Monotonic Origin Nonce Gating | `CrossGuardReactive.sol` | `testReactRejectsDuplicateNonce`, `testReactRejectsLowerNonce` |
| **INV-03** | Exact Stored Payload Retry Integrity | `CrossGuardReactive.sol` | `testRetryFailedCallbackFullLifecycle` |
| **INV-04** | Bounded Retry Budget ($\le 3$) | `CrossGuardReactive.sol` | `test08_RetryLimitEnforcement` |
| **INV-05** | Destination Nonce Monotonicity | `BorrowingController.sol` | `testRevertWhenDuplicateNonce`, `test05_RetryAfterSuccessfulDeliveryRevertsOnDestination` |
| **INV-06** | Multi-Position Isolation | All Contracts | `test11_MultiPositionIsolation` |
| **INV-07** | Administrative Pause Invariance | `BorrowingController.sol` | `test12_AdministrativePauseProtection` |
| **INV-08** | Read-Only Recovery Preflight Safety | `crossguard_healthcheck.py` | `test_46_preflight_eligible_destination_failure` through `test_67` |

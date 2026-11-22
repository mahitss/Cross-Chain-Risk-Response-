# CrossGuard Threat Model & Adversarial Attack Matrix

**Milestone:** M004 — Adversarial Security & Cross-Chain Reliability<br>
**Date:** 2026-11-22<br>
**Repository:** `mahitss/Cross-Chain-Risk-Response-`<br>
**Working Branch:** `fix/m002-2-omni-callback-correctness`<br>
**Baseline Commit:** `c82c5c5390a86e7882503992fe37b71cf899d631`<br>
**Current Multi-Chain Topology:**
- Origin: Base Sepolia (`84532`)
- Reactive Engine: Reactive Lasna (`5318007`)
- Destination: Unichain Sepolia (`1301`)

---

## 1. Assets and State to Protect

1. **Destination Lending Facility Solvency (`BorrowingController`):**
   - Protection against uncollateralized or underwater borrowing.
   - Preservation of borrowing pause states under adversarial conditions.
   - Ensuring positions paused due to risk breaches cannot continue borrowing while collateral on Base Sepolia is compromised.
2. **Origin Collateral & Debt Records (`CollateralVault`):**
   - Integrity of user collateral deposits and recorded debt.
   - Prevention of unsafe borrowing against uncollateralized or already-breached positions.
3. **Position Ownership & Access Control:**
   - Position ownership mapping (`positionOwners` on destination, `_positions[positionId].user` on origin).
   - Ensuring only authenticated position owners can initiate debt on their respective positions.
4. **State Machine Integrity & Monotonic Nonces:**
   - Per-position monotonic sequence nonces (`positionNonce` on origin, `lastProcessedNonce` on destination).
   - Replay protection invariants across all state transitions.
   - Independence of pause dimensions: administrative emergency pauses must not be conflated with or clobbered by autonomous risk-resolution events.
5. **Configuration and Authorization Pointers:**
   - Origin: `authorizedVaults`, `riskThresholdBps`, `valuationSource`.
   - Reactive: `originChainId`, `originRiskController`, `destinationChainId`, `destinationCallback`, `callbackGasLimit`.
   - Destination: `callbackProxy`, `authorizedReactiveSender`, `callbackAdapter`.

---

## 2. Cross-Chain Trust Boundaries

```
[Origin: Base Sepolia (84532)]
   CollateralVault / RiskController / TestValuationSource
   ------------------ Trust Boundary 1 ------------------
   (Log Emission -> Reactive Network Validator Ingestion)
[Reactive Engine: Reactive Lasna (5318007)]
   Omni System Contract (0x8888...8888) -> CrossGuardReactive.react()
   ------------------ Trust Boundary 2 ------------------
   (Callback Request -> Cross-Chain Relayer Transport -> Unichain Callback Proxy)
[Destination: Unichain Sepolia (1301)]
   Callback Proxy (0x9299...7FC4) -> CrossGuardCallback -> BorrowingController
```

### Boundary 1: Origin to Reactive Engine
- **Mechanism:** Asynchronous event log observation across validator consensus.
- **Assumptions:** Reactive Network validators observe canonical finalized blocks on Base Sepolia and deliver untampered logs to `CrossGuardReactive.react()` via the Omni System Contract (`0x8888888888888888888888888888888888888888`).
- **Application Validation:** `CrossGuardReactive` does not accept raw logs blindly. It strictly enforces caller authentication (`msg.sender == address(systemContract)`), origin chain ID (`84532`), origin emitter address (`originRiskController`), topic signature, indexed parameter formatting, payload word count (96 bytes), threshold bounds, and semantic sanity (LTV $\ge$ threshold for breach, LTV $<$ threshold for resolution).

### Boundary 2: Reactive Engine to Destination
- **Mechanism:** Callback request via `systemContract.requestCallbackV_1_0()` transported by the Reactive relayer network to the official destination Callback Proxy (`0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`).
- **Authentication:**
  - **Layer 1:** Destination callback receiver enforces `msg.sender == callbackProxy`.
  - **Layer 2:** The relayer overwrites the first 160 bits of calldata with the deployed `CrossGuardReactive` contract address on Lasna. `CrossGuardCallback` enforces `reactiveSender == authorizedReactiveSender`.
- **Limitation:** Unichain Sepolia cannot inspect bytecode on Reactive Lasna (`extcodesize` across separate EVM chains is 0). Security depends on correct deployment sequencing and configuration.

---

## 3. Authorized Actors & Privileged Actions

| Actor | Target Contract | Privileged Operations |
| :--- | :--- | :--- |
| **Contract Owner (Origin)** | `CollateralVault` | Set valuation source oracle. |
| **Contract Owner (Origin)** | `RiskController` | Authorize/deauthorize vaults, adjust risk threshold (1–10,000 bps). |
| **Authorized Vault (`CollateralVault`)** | `RiskController` | Call `assessRisk(...)` to trigger risk evaluations and event emissions. |
| **Position Owner (Origin)** | `CollateralVault` | Deposit collateral, record borrow on own position. |
| **Omni System Contract (`0x8888...`)** | `CrossGuardReactive` | Invoke `react(LogRecord calldata log)`. |
| **Contract Owner (Reactive)** | `CrossGuardReactive` | Set destination callback parameters, withdraw native tokens. |
| **Official Callback Proxy (`0x9299...`)** | `CrossGuardCallback` | Invoke `handleRiskBreach(...)` and `handleRiskResolved(...)`. |
| **Contract Owner (Destination)** | `CrossGuardCallback` | Set authorized Reactive sender, set target borrowing controller. |
| **Callback Adapter (`CrossGuardCallback`)** | `BorrowingController` | Call `pauseBorrowing(...)` and `resolveBorrowing(...)`. |
| **Contract Owner (Destination)** | `BorrowingController` | Register position for user, set callback adapter, execute emergency pause, execute emergency resume with audit reason. |
| **Position Owner (Destination)** | `BorrowingController` | Register self as position owner, execute `borrow(...)` when unpaused. |

---

## 4. Nonce & Replay Model

- **Origin Nonce Invariant:** Each position has an independent `positionNonce` initialized to 0. It increments strictly monotonically (`++positionNonce[positionId]`) upon every breach evaluation and every recovery transition (`breached -> healthy`). Repeated healthy evaluations without state transition do not increment the nonce.
- **Destination Replay Protection:** `BorrowingController` tracks `lastProcessedNonce[positionId]`. Any callback presenting `nonce <= lastProcessedNonce[positionId]` **strictly reverts with `InvalidNonce`**.
- **Watermark Progression vs Duplicate Nonce Rejection:** A critical distinction exists between rejecting duplicate nonces and advancing the watermark on newer resolution:
  - *Duplicate / Stale Rejection:* Resubmitting a previously executed nonce (or an older delayed nonce) strictly reverts with `InvalidNonce`. Stale or duplicate callbacks cannot roll back or re-execute state transitions.
  - *Newer Nonce Progression on Resolution:* If a resolution callback presents a strictly newer nonce (`nonce > lastProcessedNonce[positionId]`), it is accepted even if the position is currently not paused (`isBorrowingPaused == false`). It clears `pausedByRiskBreach` and advances the watermark `lastProcessedNonce[positionId] = nonce`. This ensures that if a resolution arrives before an earlier breach (due to message reordering), it establishes the healthy state and advances the nonce watermark, causing the older delayed breach (e.g., nonce 1 arriving after nonce 2) to be rejected as stale (`InvalidNonce(1, 2)`).
- **Position Isolation:** Nonces and pause flags are mapped per `bytes32 positionId`. Mutation of one position's state cannot affect another position.

---

## 5. Callback Delivery & Execution Failure Modes

1. **Reordered Delivery (Resolution Arrives Before Breach):**
   - **Scenario:** If origin emits Breach (nonce 1), then quickly recovers and emits Resolution (nonce 2), but network latency or packet loss causes Resolution (nonce 2) to arrive at the destination before Breach (nonce 1).
   - **Baseline Vulnerability (Pre-Remediation):** In the baseline implementation, `resolveBorrowing` required `isBorrowingPaused == true`, reverting with `PositionNotPaused` if unpaused. If nonce 2 arrived while unpaused, it reverted without updating `lastProcessedNonce` (leaving it at 0). When the delayed Breach (nonce 1) arrived later, it was accepted (since $1 > 0$), locking the position in a paused state despite being healthy on origin.
   - **Remediated Behaviour (Post-Remediation):** `resolveBorrowing` is idempotent with respect to the pause flag while strictly monotonic with respect to nonces. When Resolution (nonce 2) arrives before Breach (nonce 1), it safely establishes the healthy state (`pausedByRiskBreach = false`) and advances `lastProcessedNonce` to 2. When the delayed Breach (nonce 1) arrives later, it is rejected by the monotonic watermark check (`1 <= 2 -> revert InvalidNonce(1, 2)`), preventing liveness traps and converging safely to the healthy state.
2. **Dropped / Lost Callback:**
   - A breach message is dropped. The position remains unpaused on destination. If a subsequent resolution message arrives, it establishes that the position is healthy up to that nonce and advances the watermark.
3. **Duplicate / Stale Delivery:**
   - Relayers or adversaries resubmit an earlier callback. Handled cleanly: reverts with `InvalidNonce`.
4. **Execution Gas Exhaustion / Target Revert:**
   - If callback execution reverts on the destination, the transaction reverts atomically. State and nonces are not partially updated.
5. **Cross-Chain Relayer Downtime:**
   - If the Reactive relayer is partitioned or unavailable, autonomous recovery cannot be delivered. The protocol provides an explicit administrative circuit breaker (`emergencyResumeBorrowing`) with mandatory audit logging.

---

## 6. Emergency Recovery Assumptions

- **Normal Administrative Resume (`resumeBorrowing`):** Can only be used to clear an administrative pause. If `pausedByRiskBreach == true`, it **must revert** (`CannotBypassActiveRiskBreach`).
- **Emergency Administrative Override (`emergencyResumeBorrowing`):** Intended strictly as a last resort during cross-chain infrastructure failure. Requires caller to be contract owner, position to be paused, and provides a non-empty `reason` string that is permanently emitted in an on-chain audit event (`EmergencyBorrowingResumed`).
- **Independence of Pauses:** An administrative emergency pause placed by governance must not be cleared by an autonomous cross-chain risk resolution callback.

---

## 7. Known Limitations of the Local Mock Environment

- **In-Memory Synchrony:** `MockOmniSystemContract` and `MockCallbackProxy` execute calls synchronously within the same EVM transaction. Real-world asynchronous latency, block reorganizations, gas price spikes, and network partitions are simulated logically rather than physically.
- **Mock Gas Accounting:** In-memory execution in Foundry does not enforce Reactive Lasna gas metering or destination gas-refund economics.
- **Cross-Chain Code Querying:** In tests, `address(crossGuardReactive).code.length` is non-zero because all contracts exist in the same test state, whereas across live separate chains `extcodesize` is 0.

---

## 8. Adversarial Attack Matrix

| # | Attack Scenario | Attacker Capability | Target Contract / Function | Expected Secure Behaviour | Baseline Existing Test | M004 Regression / Verification Test | Post-Remediation Status |
|---|---|---|---|---|---|---|---|
| **A01** | Unauthorized caller invokes callback adapter | Arbitrary EOA or contract caller | `CrossGuardCallback.handleRiskBreach` | Revert (`authorizedSenderOnly` / not proxy) | `CrossGuardCallbackTest.testRevertWhenUnauthorizedProxyCalls` | `M004AdversarialSecurityTest.testDirectAttackerCallsToCallbackReceiverRevert` | **PASS** |
| **A02** | Correct proxy, forged Reactive sender | Malicious relayer or caller via proxy | `CrossGuardCallback.handleRiskBreach` | Revert (`UnauthorizedReactiveSender`) | `CrossGuardCallbackTest.testRevertWhenForgedReactiveSenderCalls` | `M004AdversarialSecurityTest.testForgedReactiveSenderThroughProxyReverts` | **PASS** |
| **A03** | Unauthorized caller calls `BorrowingController.pauseBorrowing` | Non-callback adapter caller | `BorrowingController.pauseBorrowing` | Revert (`UnauthorizedCallback`) | `BorrowingControllerTest.testRevertWhenNonCallbackCallsPauseBorrowing` | `M004AdversarialSecurityTest.testDirectAttackerCallsToCallbackReceiverRevert` | **PASS** |
| **A04** | Duplicate callback replay | Intercepted calldata re-broadcast | `BorrowingController.pauseBorrowing` | Revert (`InvalidNonce`) | `BorrowingControllerTest.testRevertWhenDuplicateNonce` | `M004AdversarialSecurityTest.testDuplicateAndStaleNonces` | **PASS** |
| **A05** | Outdated / stale nonce injection | Older callback delivered after newer | `BorrowingController.pauseBorrowing` | Revert (`InvalidNonce`) | `BorrowingControllerTest.testRevertWhenOutdatedNonce` | `M004AdversarialSecurityTest.testDuplicateAndStaleNonces` | **PASS** |
| **A06** | **Resolution callback clears administrative emergency pause** | Autonomous callback arrives while admin pause is set | `BorrowingController.resolveBorrowing` | **Admin pause must remain active; borrowing must remain paused** | None *(Conflated in baseline)* | `M004AdversarialSecurityTest.testAdministrativePauseSurvivesRiskResolution`, `testBothPauseReasonsActiveSimultaneously` | **PASS (Remediated)** |
| **A07** | **Resolution arrives before breach (Out-of-order)** | Network reordering: nonce 2 arrives before nonce 1 | `BorrowingController.resolveBorrowing` | **Nonce 2 accepted, position healthy; delayed nonce 1 rejected** | None *(Liveness lock in baseline)* | `M004AdversarialSecurityTest.testResolutionArrivingBeforeBreachConvergesSafely`, `BorrowingControllerTest.testResolveBorrowingWhenNotPausedSucceedsAndSetsNonce` | **PASS (Remediated)** |
| **A08** | Ordinary owner resumes position during active risk breach | Contract owner calls `resumeBorrowing` | `BorrowingController.resumeBorrowing` | Revert (`CannotBypassActiveRiskBreach`) | `BorrowingControllerTest.testOrdinaryOwnerResumeCannotBypassActiveRiskBreach` | `M004AdversarialSecurityTest.testBothPauseReasonsActiveSimultaneously` | **PASS** |
| **A09** | Emergency resume with empty audit reason | Contract owner calls `emergencyResumeBorrowing` | `BorrowingController.emergencyResumeBorrowing` | Revert (`EmptyEmergencyReason`) | `BorrowingControllerTest.testRevertEmergencyResumeEmptyReasonOrNotPaused` | `M004AdversarialSecurityTest.testEmergencyResumeClearsBothPausesWithAudit` | **PASS** |
| **A10** | Zero position ID injection on state transition | Caller supplies `bytes32(0)` | Origin & Destination state-changing functions | Revert (`InvalidPositionId`) | All unit suites | `M004AdversarialSecurityTest.testZeroPositionIdThroughCallbackReceiverReverts` | **PASS** |
| **A11** | Zero nonce log injection | Malicious/spoofed log in Reactive | `CrossGuardReactive.react` | Log rejected (`ReactiveEventRejected(..., "ZERO_NONCE")`) | `CrossGuardReactiveTest.testReactRejectsZeroNonce` | `M004AdversarialSecurityTest.testReactiveRejectsAllInvalidLogMutations` | **PASS** |
| **A12** | Spoofed origin chain ID or emitter | Malicious log from foreign contract/chain | `CrossGuardReactive.react` | Log rejected without callback request | `CrossGuardReactiveTest.testReactIgnoresWrongChainId` | `M004AdversarialSecurityTest.testReactiveRejectsAllInvalidLogMutations` | **PASS** |
| **A13** | Truncated / malformed log data payload | Malformed log with data length $\ne 96$ | `CrossGuardReactive.react` | Log rejected (`INVALID_DATA_LENGTH`) | `CrossGuardReactiveTest.testReactRejectsTruncatedData` | `M004AdversarialSecurityTest.testReactiveRejectsAllInvalidLogMutations` | **PASS** |
| **A14** | Semantic spoofing: breach log with LTV $<$ threshold | Inconsistent log emitted on origin | `CrossGuardReactive.react` | Log rejected (`BREACH_BELOW_THRESHOLD`) | `CrossGuardReactiveTest.testReactRejectsBreachWithLtvBelowThreshold` | `M004AdversarialSecurityTest.testReactiveRejectsAllInvalidLogMutations`, `testFuzzReactiveRiskThresholdSanity` | **PASS** |
| **A15** | Cross-position state interference | Actions on Position A affecting Position B | `BorrowingController` / `CollateralVault` | Position states and nonces completely isolated | Implicit | `M004AdversarialSecurityTest.testPositionIsolationUnderAdversarialCallbacks` | **PASS** |
| **A16** | Replayed callback after emergency resume | Stale callback delivered after admin override | `BorrowingController.pauseBorrowing` | Revert if `nonce <= lastProcessedNonce` | Implicit | `M004AdversarialSecurityTest.testDelayedMessagesAfterEmergencyResume` | **PASS** |
| **A17** | Changed callback adapter / Reactive sender | Attacker reconfigures authorized addresses | Destination contracts | Revert (`OwnableUnauthorizedAccount`) | `BorrowingControllerTest` / `CrossGuardCallbackTest` | `M004AdversarialSecurityTest.testChangedCallbackAdapterPreventsOldAdapterCalls`, `testUnauthorizedConfigChangesOnCallbackReceiverRevert` | **PASS** |
| **A18** | Callback target reverts during execution | Malformed call or state conflict | Destination execution | Call reverts atomically, no partial state mutation | Implicit | `M004AdversarialSecurityTest.testCallbackRevertLeavesStateUnmutated` | **PASS** |

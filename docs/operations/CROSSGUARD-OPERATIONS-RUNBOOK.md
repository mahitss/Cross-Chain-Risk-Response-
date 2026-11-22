# CrossGuard Operations, Failure Diagnosis & Runbook

**Protocol:** CrossGuard — Autonomous Cross-Chain Risk-Response Protocol
**Milestone:** MISSION M005 / M005.1 — Operational Observability, Safety & ABI Correctness
**Date:** 2026-11-23
**Multi-Chain Topology:**
- Origin: Base Sepolia (`84532`)  
- Reactive Engine: Reactive Lasna (`5318007`)  
- Destination: Unichain Sepolia (`1301`)  

---

## 1. Operational Overview & Health-Check Tooling

CrossGuard coordinates origin risk observation, reactive event evaluation, and destination borrowing containment across three independent EVM networks. To maintain operational integrity, protocol operators rely on the read-only operational health-check script:

```bash
# Basic run with environment variables
python script/ops/crossguard_healthcheck.py

# Explicit parameter run with optional callback record inspection
python script/ops/crossguard_healthcheck.py \
  --base-rpc "$BASE_SEPOLIA_RPC_URL" \
  --reactive-rpc "$REACTIVE_LASNA_RPC_URL" \
  --unichain-rpc "$UNICHAIN_SEPOLIA_RPC_URL" \
  --origin-risk-controller "$BASE_RISK_CONTROLLER" \
  --reactive-address "$REACTIVE_CROSSGUARD" \
  --callback-address "$UNICHAIN_CALLBACK_ADAPTER" \
  --borrowing-controller-address "$BORROWING_CONTROLLER_ADDRESS" \
  --reactive-tx-hash "$REACTIVE_TX_HASH" \
  --json
```

### Safety & Operational Constraints
- **Strictly Read-Only:** The health checker only executes whitelisted read-only queries (`cast chain-id`, `cast code`, `cast call`, `cast balance`). It strictly forbids transaction broadcasting, wallet access, or private key handling.
- **Credential Redaction:** The tool automatically redacts all RPC credentials, user-info, sensitive path segments, and query tokens from terminal outputs, JSON reports, and error messages.
- **Bounded Execution Timeouts:** Subprocess RPC queries enforce a 15-second default timeout to prevent hanging on unresponsive endpoints.
- **Strict Exit Codes:** Returns exit code `0` for `HEALTHY`, and exit code `1` for `WARNING`, `CRITICAL`, `UNKNOWN`, and `ERROR` to facilitate reliable monitoring automation.
- **Human-in-the-Loop Remediation:** Any remediation requiring state changes or funding requires an authorized human operator executing verified, audited transactions. No automated scripts are permitted to hold private keys or execute unilateral recovery transactions.

---

## 2. Standard 5-Step Diagnostic Procedure

Every failure scenario must follow this rigorous five-step diagnostic procedure:

```
[1. Detection] ──> [2. Evidence Collection] ──> [3. Root-Cause Isolation] ──> [4. Authorized Remediation] ──> [5. Post-Remediation Verification]
```

1. **Detection:** Identify the anomaly via `crossguard_healthcheck.py` status or on-chain monitoring alerts.
2. **Evidence Collection:** Query exact contract state, RPC responses, event logs, and accounting metrics using `cast`.
3. **Root-Cause Isolation:** Match symptoms against protocol invariants and failure modes.
4. **Authorized Remediation:** Carry out sanctioned manual intervention with appropriate role credentials.
5. **Post-Remediation Verification:** Re-run diagnostics to confirm operational recovery.

---

## 3. Comprehensive Failure Diagnosis Scenarios

### Scenario 1: Base Sepolia RPC Unavailable
1. **Detection:** Health checker reports `network_base_sepolia: ERROR` or `UNKNOWN`.
2. **Evidence Collection:**
   ```bash
   cast chain-id --rpc-url "$BASE_SEPOLIA_RPC_URL"
   ```
3. **Root-Cause Isolation:** The Base Sepolia RPC provider is offline, rate-limiting requests, or experiencing network partitions. Origin risk condition observation cannot be verified by the operator.
4. **Authorized Remediation:** Failover to an alternate healthy Base Sepolia RPC endpoint in operator configuration. Note: The Reactive Network validator set monitors Base Sepolia independently; local RPC downtime affects operator observability, not necessarily decentralized validator observation.
5. **Post-Remediation Verification:** Run `python script/ops/crossguard_healthcheck.py` and confirm `network_base_sepolia: PASS`.

---

### Scenario 2: Reactive Lasna RPC Unavailable
1. **Detection:** Health checker reports `network_reactive_lasna: ERROR` or `UNKNOWN`.
2. **Evidence Collection:**
   ```bash
   cast chain-id --rpc-url "$REACTIVE_LASNA_RPC_URL"
   ```
3. **Root-Cause Isolation:** Reactive Lasna RPC node is unreachable or desynchronized. Operator cannot inspect `CrossGuardReactive` state, System Contract debt, or callback request logs.
4. **Authorized Remediation:** Check official Reactive Network RPC status (`https://lasna-rpc.rnk.dev/`) or failover to secondary Lasna RPC endpoints.
5. **Post-Remediation Verification:** Run health check and confirm chain ID `5318007` returns `PASS`.

---

### Scenario 3: Unichain Sepolia RPC Unavailable
1. **Detection:** Health checker reports `network_unichain_sepolia: ERROR` or `UNKNOWN`.
2. **Evidence Collection:**
   ```bash
   cast chain-id --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"
   ```
3. **Root-Cause Isolation:** Destination node RPC is offline. Operator cannot verify destination borrowing status or Callback Proxy state.
4. **Authorized Remediation:** Switch to secondary Unichain Sepolia provider in operator environment.
5. **Post-Remediation Verification:** Verify `network_unichain_sepolia: PASS` (Chain ID `1301`).

---

### Scenario 4: Reactive Contract Has Debt
> [!WARNING]
> Remediation requires spending native REACT tokens on Reactive Lasna and paying gas fees. Do not execute in automated scripts.

1. **Detection:** Health checker reports `funding_reactive_system_debt: CRITICAL`.
2. **Evidence Collection:**
   ```bash
   cast call 0x8888888888888888888888888888888888888888 "debt(address)(uint256)" "$REACTIVE_CROSSGUARD" --rpc-url "$REACTIVE_LASNA_RPC_URL"
   ```
3. **Root-Cause Isolation:** `CrossGuardReactive` has unpaid execution fees on the Reactive Omni System Contract (`0x8888888888888888888888888888888888888888`). In the Reactive economy, outstanding debt suspends `react()` log processing, halting autonomous risk responses.
4. **Authorized Remediation:**
   - *Operational Rule:* Funding must use the System Contract's documented `depositTo(address)` route. The deposit settles outstanding debt first before crediting any remainder to prepaid reserves.
   - *Critical Warning:* Direct transfers to the System Contract credit `msg.sender`'s own accounting balance, **not** the contract beneficiary.
   - *Contract Constraint:* `CrossGuardReactive.pay(uint256)` reverts with `"Not implemented"` and must **never** be invoked as a recovery action.
   - *Action (Human Operator Only):*
     ```bash
     cast send 0x8888888888888888888888888888888888888888 "depositTo(address)" "$REACTIVE_CROSSGUARD" \
       --value <AMOUNT_WEI> \
       --rpc-url "$REACTIVE_LASNA_RPC_URL" \
       --private-key "$OPERATOR_PRIVATE_KEY"
     ```
5. **Post-Remediation Verification:** Re-query `debt(address)` and confirm value returns `0`.

---

### Scenario 5: Callback Contract Has Debt
> [!WARNING]
> Remediation requires spending native gas tokens (ETH) on Unichain Sepolia and paying gas fees. Do not execute in automated scripts.

1. **Detection:** Health checker reports `funding_callback_proxy_debt: CRITICAL`.
2. **Evidence Collection:**
   ```bash
   cast call 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4 "debt(address)(uint256)" "$UNICHAIN_CALLBACK_ADAPTER" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"
   ```
3. **Root-Cause Isolation:** Destination `CrossGuardCallback` has unpaid settlement debt with the Unichain Callback Proxy (`0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`). Outstanding debt blocks delivery of subsequent cross-chain callbacks.
4. **Authorized Remediation:**
   - *Operational Rule:* Settle callback debt by calling `depositTo(address)` on the Callback Proxy. This settles outstanding debt and replenishes execution reserves for `$UNICHAIN_CALLBACK_ADAPTER`.
   - *Critical Warning:* A direct transfer to the proxy credits the sender, not the callback contract.
   - *Action (Human Operator Only):*
     ```bash
     cast send 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4 "depositTo(address)" "$UNICHAIN_CALLBACK_ADAPTER" \
       --value <AMOUNT_WEI> \
       --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" \
       --private-key "$OPERATOR_PRIVATE_KEY"
     ```
5. **Post-Remediation Verification:** Confirm `debt(address)` returns `0`.

---

### Scenario 6: Reactive Reserves Exhausted
> [!WARNING]
> Remediation requires spending native REACT tokens on Reactive Lasna. Do not execute in automated scripts.

1. **Detection:** Health checker reports `funding_reactive_system_reserves: WARNING`.
2. **Evidence Collection:**
   ```bash
   cast call 0x8888888888888888888888888888888888888888 "reserves(address)(uint256)" "$REACTIVE_CROSSGUARD" --rpc-url "$REACTIVE_LASNA_RPC_URL"
   ```
3. **Root-Cause Isolation:** Prepaid gas reserves on the System Contract are 0. The contract will incur debt upon the next origin event trigger.
4. **Authorized Remediation:** Call `depositTo(address)` on the System Contract with native REACT targeting `$REACTIVE_CROSSGUARD`.
5. **Post-Remediation Verification:** Confirm `reserves(address) > 0`.

---

### Scenario 7: Callback Proxy Reserves Exhausted
> [!WARNING]
> Remediation requires spending native gas tokens (ETH) on Unichain Sepolia. Do not execute in automated scripts.

1. **Detection:** Health checker reports `funding_callback_proxy_reserves: WARNING`.
2. **Evidence Collection:**
   ```bash
   cast call 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4 "reserves(address)(uint256)" "$UNICHAIN_CALLBACK_ADAPTER" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"
   ```
3. **Root-Cause Isolation:** Destination callback reserves on the Callback Proxy are 0.
4. **Authorized Remediation:** Call `depositTo(address)` on the Callback Proxy on Unichain Sepolia targeting `$UNICHAIN_CALLBACK_ADAPTER`.
5. **Post-Remediation Verification:** Confirm `reserves(address) > 0`.

---

### Scenario 8: Invalid Callback Gas Configuration
1. **Detection:** Health checker reports `callback_gas_limit_check: CRITICAL`.
2. **Evidence Collection:**
   ```bash
   cast call "$REACTIVE_CROSSGUARD" "callbackGasLimit()(uint64)" --rpc-url "$REACTIVE_LASNA_RPC_URL"
   ```
3. **Root-Cause Isolation:** Configured `callbackGasLimit` is below the official Reactive minimum of `100,000` gas. The Reactive Network drops or rejects callbacks with sub-minimum gas envelopes.
4. **Authorized Remediation:** The contract owner must call `setDestinationConfig(1301, callbackAdapter, 300000)` on `CrossGuardReactive` to restore gas limit to at least 100,000 gas (protocol standard: 300,000 gas).
5. **Post-Remediation Verification:** Query `callbackGasLimit()` and confirm it returns `300000`.

---

### Scenario 9: Wrong Callback Recipient
1. **Detection:** Health checker reports `config_reactive_dest_callback: CRITICAL`.
2. **Evidence Collection:**
   ```bash
   cast call "$REACTIVE_CROSSGUARD" "destinationCallback()(address)" --rpc-url "$REACTIVE_LASNA_RPC_URL"
   ```
3. **Root-Cause Isolation:** `CrossGuardReactive` points to an incorrect or outdated destination callback address on Unichain Sepolia. Dispatched callbacks are delivered to the wrong contract.
4. **Authorized Remediation:** Deployer/owner executes `ConfigureReactive.s.sol` or invokes `setDestinationConfig` with the correct `CrossGuardCallback` contract address.
5. **Post-Remediation Verification:** Re-run health checker and confirm `config_reactive_dest_callback: PASS`.

---

### Scenario 10: Wrong Authorized Reactive Sender
1. **Detection:** Health checker reports `config_callback_authorized_reactive: CRITICAL`.
2. **Evidence Collection:**
   ```bash
   cast call "$UNICHAIN_CALLBACK_ADAPTER" "authorizedReactiveSender()(address)" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"
   ```
3. **Root-Cause Isolation:** `CrossGuardCallback` on Unichain Sepolia expects a different Reactive contract address. All incoming callbacks will revert with `UnauthorizedReactiveSender`.
4. **Authorized Remediation:** Owner of `CrossGuardCallback` calls `setAuthorizedReactiveSender(address)` passing the deployed `CrossGuardReactive` contract address on Lasna.
5. **Post-Remediation Verification:** Confirm getter matches deployed Reactive contract.

---

### Scenario 11: Destination Callback Failure (`CallbackFailure`)
1. **Detection:** Health check `--reactive-tx-hash <HASH>` reports `callback_record_inspection: CRITICAL` with error data.
2. **Evidence Collection:**
   ```bash
   cast call 0x8888888888888888888888888888888888888888 \
     "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])" \
     <HASH_AS_UINT> \
     --rpc-url "$REACTIVE_LASNA_RPC_URL"
   ```
   Inspect decoded six-field records: `(uint256 destination_chain_id, address to, uint256 gas_limit, uint256 gas_price, uint256 tx_id, bytes error)`.
   - Empty `error` bytes (`0x`): Execution was successful.
   - Non-empty `error` bytes: Execution reverted. Common signatures:
     - `0x4e487b71`: Panic / assert.
     - `0x08c379a0`: Error(string).
     - Custom errors: `InvalidNonce`, `CannotBypassActiveRiskBreach`, `UnauthorizedCallback`.
3. **Root-Cause Isolation:** Destination callback execution reverted during proxy delivery. Destination state was not mutated, but gas and fees were charged.
4. **Authorized Remediation:** Decode the error data using `cast decode-error` or `cast 4byte`. If caused by temporary state misalignment or relayer disruption, an authorized operator must evaluate whether manual administrative containment (`emergencyPauseBorrowing`) is required.
5. **Post-Remediation Verification:** Query `BorrowingController.isBorrowingPaused(positionId)` to confirm position protection status.

---

### Scenario 12: Insufficient Gas Revert (`InsufficientGas`)
1. **Detection:** Destination callback reverts with out-of-gas error or `CallbackFailure`.
2. **Evidence Collection:** Compare configured gas limit (`300,000`) against proxy accounting overhead.
3. **Root-Cause Isolation:** The callback method or proxy settlement logic required more gas than provided in the forwarded budget.
4. **Authorized Remediation:** Call `setDestinationConfig` on `CrossGuardReactive` to increase `callbackGasLimit` (e.g. to `500,000` gas).
5. **Post-Remediation Verification:** Confirm new gas limit on Lasna.

---

### Scenario 13: No Callback Records Found (Pending State)
1. **Detection:** Health check reports `callback_record_inspection: UNKNOWN` ("Callback records are pending, not yet recorded, or unavailable").
2. **Evidence Collection:**
   ```bash
   cast call 0x8888888888888888888888888888888888888888 \
     "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])" \
     <HASH_AS_UINT> \
     --rpc-url "$REACTIVE_LASNA_RPC_URL"
   ```
3. **Root-Cause Isolation:** The transaction is either still propagating, unfinalized on the destination chain, or the relayer has not yet written back the callback receipt to the System Contract.
4. **Authorized Remediation:** **Do not treat as confirmed failure.** Wait for block finalization across Unichain Sepolia and Reactive Lasna (typically 30–120 seconds).
5. **Post-Remediation Verification:** Query `getCallbacks` again after confirmation window.

---

### Scenario 14: Delayed Callback Arrival
1. **Detection:** Origin emitted `RiskBreach`, but destination borrowing is not yet paused after expected latency window.
2. **Evidence Collection:**
   - Origin block & tx: verify `RiskBreach` event on Base Sepolia.
   - Lasna tx: verify `react()` executed on `CrossGuardReactive`.
   - Destination state: verify `isBorrowingPaused(positionId)`.
3. **Root-Cause Isolation:** Cross-chain relayer latency, network congestion, or temporary gas fee spikes on Unichain Sepolia.
4. **Authorized Remediation:** If market risk is critical and active latency threatens protocol solvency, an authorized operator may invoke the administrative circuit breaker on Unichain Sepolia:
   ```bash
   # Emergency administrative pause (requires owner private key)
   cast send "$BORROWING_CONTROLLER_ADDRESS" "emergencyPauseBorrowing(bytes32)" "$POSITION_ID" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"
   ```
5. **Post-Remediation Verification:** Confirm `BorrowingController.isBorrowingPaused(positionId) == true` and `pausedByAdmin(positionId) == true`.

---

### Scenario 15: Duplicate Callback Replay
1. **Detection:** Relayer logs show revert with `InvalidNonce(uint256,uint256)`.
2. **Evidence Collection:**
   ```bash
   cast call "$BORROWING_CONTROLLER_ADDRESS" "lastProcessedNonce(bytes32)(uint256)" "$POSITION_ID" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"
   ```
3. **Root-Cause Isolation:** An already-executed callback was resubmitted by relayer retry or adversarial rebroadcast. Replay protection is functioning as designed.
4. **Authorized Remediation:** None required. Rejection is the expected secure protocol behavior.
5. **Post-Remediation Verification:** Confirm `lastProcessedNonce` remains monotonically advanced and state remains intact.

---

### Scenario 16: Cross-Chain Relayer Unavailable
1. **Detection:** All Reactive callbacks cease arriving at Unichain Sepolia across multiple blocks.
2. **Evidence Collection:** Multiple reactive transactions show empty callback records over an extended duration (> 1 hour).
3. **Root-Cause Isolation:** External infrastructure failure: Reactive Network relayer network partition or Unichain relayer bridge outage.
4. **Authorized Remediation:**
   - Escalate to Reactive Network infrastructure operators.
   - For positions at risk: Use `emergencyPauseBorrowing(positionId)`.
   - For positions verified safe through off-chain auditing: Use `emergencyResumeBorrowing(positionId, string reason)` with a documented reason string.
5. **Post-Remediation Verification:** Confirm destination state reflects manual administrative containment.

---

## 4. Honest Callback Retry & Recovery Architecture

### What CrossGuard Can Do (Current Implementation)
1. **Autonomous Log Interception:** `CrossGuardReactive` reliably intercepts `RiskBreach` and `RiskResolved` logs from Base Sepolia via the Omni System Contract.
2. **Structural & Semantic Validation:** Validates origin parameters, data length (96 bytes), and threshold consistency before dispatching callbacks.
3. **Monotonic Nonce Enforcement:** Rejects replayed, stale, or duplicated callbacks at destination lending facility via `require(nonce > lastProcessedNonce[positionId], InvalidNonce)`.
4. **Orthogonal Pause Dimensions:** Autonomous risk resolutions clear `pausedByRiskBreach` without clobbering manual governance emergency pauses (`pausedByAdmin`).
5. **Out-of-Order Convergence:** If resolution arrives before breach, it safely advances `lastProcessedNonce` and establishes healthy status, causing the older delayed breach to be rejected as stale.

### What CrossGuard Cannot Currently Do
1. **No Guaranteed Destination Execution:** Calling `systemContract.requestCallbackV_1_0()` requests relay transport; it does **not** guarantee destination inclusion or successful EVM execution.
2. **No Automatic Callback Retry Service:** If a destination callback reverts (e.g., due to temporary gas exhaustion, transient state lock, or proxy debt), the protocol **does not automatically retry** the failed callback.
3. **No Retries via Replaying Stale Callbacks:** Because `BorrowingController` enforces strictly increasing nonces, an operator cannot simply replay an old failed callback transaction payload; it will revert with `InvalidNonce`.
4. **No Automated Oracle Freshness or Position LTV Telemetry:** The current `TestValuationSource` only provides `setAssetPrice(address,uint256)` and `getAssetPrice(address)`. It does not support `pause()`, `unpause()`, price timestamps, or heartbeats. The health checker does not monitor price staleness or position LTV health.

### Future Engineering Recommendations (Post-M005.1)
1. **Origin Re-Evaluation Trigger:** An off-chain monitor observing a `CallbackFailure` on Lasna can trigger a new `evaluatePositionRisk()` on Base Sepolia. If the breach condition persists, this emits a new event with an incremented nonce, generating a fresh, valid cross-chain callback.
2. **Decentralized Oracle Feed Integration:** Upgrade `TestValuationSource` to integrate Chainlink/Pyth feeds with staleness thresholds, heartbeat monitoring, and automated circuit breakers.
3. **Destination Reconciliation Queue:** A pull-based reconciliation oracle where destination contracts can query verified origin states directly if push callbacks fail.

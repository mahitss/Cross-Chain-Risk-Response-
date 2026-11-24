# CrossGuard: Autonomous Cross-Chain Risk-Response Protocol

CrossGuard is an autonomous cross-chain risk mitigation protocol engineered for the **Reactive Network Omni Architecture**.

When collateral risk conditions (such as market crashes or loan-to-value health deterioration) occur on **Base Sepolia (Chain ID: 84532)**, the protocol's Reactive Smart Contract on **Reactive Lasna (Chain ID: 5318007)** autonomously intercepts origin event logs, validates origin parameters, and dispatches an authenticated cross-chain callback to **Unichain Sepolia (Chain ID: 1301)**. On Unichain Sepolia, an authorized callback adapter receives the message and executes to pause further borrowing for the affected position, preventing toxic debt accumulation once callback delivery and execution complete.

---

## 📌 Executive Summary

### The Problem CrossGuard Solves
Cross-chain and multi-chain lending protocols separate user collateral (locked on an origin chain) from borrowing facilities (deployed across secondary or destination chains). In traditional cross-chain lending architectures:
- If collateral devalues on the origin chain, destination lending pools have no native awareness of the risk breach.
- Protocols rely on **off-chain centralized bots, cron jobs, or private keepers** to observe the origin chain, sign transactions, and pay gas on the destination chain to pause borrowing.
- If these off-chain keepers experience network congestion, cloud provider outages, or RPC throttling, there is a dangerous latency window during which users can continue borrowing uncollateralized assets, resulting in protocol insolvency and toxic debt.

### Why Reactive Network Is Essential
Reactive Network solves this by providing **inversion of control** at the smart-contract layer:
- **Autonomous On-Chain Execution:** Instead of off-chain servers continuously polling origin state, `CrossGuardReactive` is deployed directly on the Reactive Network (Lasna Testnet).
- **Native Log Subscriptions:** Through the Reactive Omni System Contract (`0x8888888888888888888888888888888888888888`), the reactive contract subscribes directly to origin log topics across the validator network.
- **Trust-Minimized Relaying:** When an origin risk event is emitted, the Reactive Network validator network routes the log to `CrossGuardReactive.react()`, which verifies the origin parameters and dispatches an authenticated cross-chain callback to the destination chain.
- **Cryptographic Sender Injection:** The Reactive relayer overwrites the first 160 bits of the callback payload with the deployed Reactive contract address, allowing the destination callback receiver to authenticate the reactive smart contract deterministically.

---

## 🏗️ Protocol Architecture & Topology

```
                  ORIGIN CHAIN: BASE SEPOLIA (Chain ID: 84532)
   +------------------------------------------------------------------------+
   |                          TestValuationSource                           |
   |   - Mock pricing oracle for collateral & debt (8 decimals, 1e8)        |
   +-----------------------------------+------------------------------------+
                                       |
                                       v
   +------------------------------------------------------------------------+
   |                            CollateralVault                             |
   |   - Tracks collateral & debt positions (18 decimals, 1e18)             |
   |   - recordBorrow(): Enforces zero-collateral & breach safety checks    |
   |   - evaluatePositionRisk(): Triggers canonical risk evaluation         |
   +-----------------------------------+------------------------------------+
                                       |
                                       v
   +------------------------------------------------------------------------+
   |                             RiskController                             |
   |   - Sole authoritative origin risk policy                              |
   |   - Configurable risk threshold (e.g., 8,000 bps = 80.00% LTV)         |
   |   - calculateLtvBps(): 512-bit intermediate math, overflow-protected   |
   |   - Emits: RiskBreach(...) or RiskResolved(...) with monotonic nonce   |
   +-----------------------------------+------------------------------------+
                                       |
                                       | Event Logs Emitted on Base Sepolia
                                       v
               REACTIVE NETWORK: LASNA TESTNET (Chain ID: 5318007)
   +------------------------------------------------------------------------+
   |                         Omni System Contract                           |
   |   - Address: 0x8888888888888888888888888888888888888888               |
   |   - Delivers validated event logs to subscribed reactive contracts     |
   +-----------------------------------+------------------------------------+
                                       |
                                       v
   +------------------------------------------------------------------------+
   |                          CrossGuardReactive                            |
   |   - Validates origin chainId (84532), emitter, topic, payload & bounds |
   |   - Enforces single authoritative policy (no secondary filtering)      |
   |   - Dispatches Omni callback V_1_0 to Unichain Sepolia (1301)          |
   +-----------------------------------+------------------------------------+
                                       |
                                       | Authenticated Callback via Relayer
                                       v
               DESTINATION CHAIN: UNICHAIN SEPOLIA (Chain ID: 1301)
   +------------------------------------------------------------------------+
   |                        Official Callback Proxy                         |
   |   - Address: 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4               |
   |   - Injects deployed CrossGuardReactive contract address               |
   +-----------------------------------+------------------------------------+
                                       |
                                       v
   +------------------------------------------------------------------------+
   |                           CrossGuardCallback                           |
   |   - Layer 1: Enforces msg.sender == UNICHAIN_CALLBACK_PROXY            |
   |   - Layer 2: Authenticates injected reactiveSender == expected         |
   |   - Calls BorrowingController.pauseBorrowing() or resolveBorrowing()   |
   +-----------------------------------+------------------------------------+
                                       |
                                       v
   +------------------------------------------------------------------------+
   |                          BorrowingController                           |
   |   - Destination lending facility tracking borrowing against positions  |
   |   - Strict monotonic nonce verification (rejects replay/stale nonces)  |
   |   - Distinct emergency administrative controls with audit reasons      |
   +------------------------------------------------------------------------+
```

---

## 🔍 Contract Responsibilities

| Contract | Network | Chain ID | Primary Responsibility |
| :--- | :--- | :--- | :--- |
| **`TestValuationSource.sol`** | Base Sepolia | `84532` | Configurable mock oracle providing asset USD prices scaled to 8 decimals ($10^8$). |
| **`CollateralVault.sol`** | Base Sepolia | `84532` | Manages collateral deposits and borrow records ($10^{18}$ decimals). Evaluates position health and blocks borrowing on breached or uncollateralized positions. |
| **`RiskController.sol`** | Base Sepolia | `84532` | Sole authoritative origin risk policy engine. Calculates canonical LTV using 512-bit arithmetic, manages position breach status, and emits events with monotonic per-position nonces. |
| **`CrossGuardReactive.sol`** | Reactive Lasna | `5318007` | Subscribes to `RiskBreach` and `RiskResolved` origin events via Omni System Contract, validates event structure and semantics, and dispatches callbacks to Unichain Sepolia. |
| **`CrossGuardCallback.sol`** | Unichain Sepolia | `1301` | Destination callback adapter enforcing dual-layer authentication: official Callback Proxy verification and injected Reactive contract address validation. |
| **`BorrowingController.sol`** | Unichain Sepolia | `1301` | Destination lending pool that enforces borrowing pauses, rejects replayed or stale callbacks via monotonic nonces, and provides separated administrative emergency overrides. |

---

## 🔒 Security Model & Architectural Invariants

### 1. Canonical Risk Calculation & Arithmetic Safety
- **Decimal Conventions:**
  - Token balances: 18 decimals ($10^{18}$).
  - Oracle asset prices: 8 decimals ($10^8$, Chainlink standard).
  - USD valuations: 8 decimals ($10^8$).
  - LTV scale: Basis points ($10,000 = 100.00\%$).
- **512-Bit Intermediate Precision:** LTV is computed as $\frac{\text{debtValueUsd} \times 10,000}{\text{collateralValueUsd}}$ using `Math.mulDiv` and assembly `mulmod`/`mul` bounds checks. If the intermediate quotient exceeds $2^{256}-1$, it deterministically caps at `type(uint256).max` rather than overflowing.
- **Dust & Zero Valuation Handling:**
  - Zero debt: $0\text{ bps}$ (Healthy).
  - Zero collateral with positive debt: $10,000\text{ bps}$ (Max risk / Breached).
  - Zero collateral and zero debt: $0\text{ bps}$ (Healthy).
- **Single Authoritative Policy:** `RiskController` is the sole authority for risk thresholds. `CollateralVault` delegates all breach decisions and projected LTV checks to `RiskController`, guaranteeing that emitted LTVs and breach events cannot disagree.

### 2. Origin Borrow Safety & Stale Breach Protection
- `CollateralVault.recordBorrow()` enforces four mandatory checks:
  1. Position cannot have zero collateral (`PositionUncollateralized`).
  2. Position cannot be in an active breached state (`PositionInBreachedState`).
  3. Projected LTV with new debt cannot meet or exceed `riskThresholdBps` (`PositionUnsafeOrBreached`).
  4. Caller must be the registered position owner or contract owner (`UnauthorizedUser`).
- **Explicit Recovery Requirement:** If a position breaches and the oracle subsequently recovers, borrowing on the origin remains blocked until an explicit `evaluatePositionRisk()` transaction evaluates the position as healthy and clears `isPositionBreached[positionId]`.

### 3. Full-Lifecycle Cross-Chain Recovery Propagation
- CrossGuard supports both incident response and automated recovery:
  - **Breach Flow:** When LTV $\ge$ threshold, `RiskController` sets `isPositionBreached = true`, increments nonce, and emits `RiskBreach`. Reactive dispatches `handleRiskBreach` to initiate destination borrowing pause.
  - **Recovery Flow:** When an underwater position is re-evaluated with LTV $<$ threshold, `RiskController` clears `isPositionBreached = false`, increments nonce, and emits `RiskResolved`. Reactive dispatches `handleRiskResolved` to resume destination borrowing.
- **Eventual Pause Outcome:** Destination borrowing is paused as an eventual outcome following successful origin emission, Reactive event ingestion, callback dispatch, relayer transport, and destination transaction execution. It is not an instantaneous local action.

### 4. Monotonic Nonce Replay Protection & Callback Ordering
- **No Reliance on Timestamp Ordering:** Callback ordering and replay resistance do not rely on block timestamps or synchronized clocks across chains.
- **Strict Monotonic Nonces:** Each position maintains an independent `positionNonce` incremented on every state transition.
- **Rejection of Stale / Duplicate Callbacks:** `BorrowingController` enforces `require(nonce > lastProcessedNonce[positionId], InvalidNonce)`.
- **Duplicate Nonces Revert:** Destination callbacks are **not** idempotent; duplicate or out-of-order nonces strictly revert to protect state sequencing.

### 5. Reactive Origin Event Validation
- `CrossGuardReactive.react()` operates exclusively on event logs delivered by the trusted Reactive Network Omni System Contract (`0x8888888888888888888888888888888888888888`).
- Inside `react()`, the contract performs exhaustive parameter and structural checks:
  1. Caller authentication (`msg.sender == address(systemContract)` via `onlySystem`).
  2. Origin chain ID match (`log.chain_id == 84532`).
  3. Origin emitter match (`log._contract == originRiskController`).
  4. Topic 0 match (`RISK_BREACH_TOPIC_0` or `RISK_RESOLVED_TOPIC_0`).
  5. Indexed parameter formatting (non-zero position ID, valid non-zero user address in lower 160 bits, non-zero nonce).
  6. Payload data length verification (exactly 96 bytes / 3 ABI words: `currentLtvBps`, `riskThresholdBps`, `timestamp`).
  7. Threshold bounds validation ($1 \le \text{riskThresholdBps} \le 10,000$).
  8. Non-zero timestamp check.
  9. Semantic LTV sanity (breach requires $\text{currentLtvBps} \ge \text{riskThresholdBps}$; resolution requires $\text{currentLtvBps} < \text{riskThresholdBps}$).
- Log transport, consensus, and block inclusion are validated natively by the Reactive Network validator set; the smart contract verifies caller authority, origin parameters, and data semantics.

### 6. Dual-Layer Destination Authentication
- **Layer 1 (Callback Proxy Verification):** Destination `CrossGuardCallback` inherits OpenZeppelin-compatible `AbstractCallback` and enforces `authorizedSenderOnly`, guaranteeing `msg.sender == UNICHAIN_CALLBACK_PROXY` (`0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`).
- **Layer 2 (Injected Contract Address Authentication):** The Reactive Network relayer replaces the first 160 bits of calldata with the actual deployed `CrossGuardReactive` contract address on Lasna. `CrossGuardCallback` validates that `reactiveSender == authorizedReactiveSender`.
- *Note:* The authenticated identifier is the deployed smart contract address on Reactive Lasna, not a legacy deployer RVM ID.

### 7. Administrative Controls, Orthogonal Pause Dimensions & Delivery Convergence
- **Orthogonal Pause Tracking:** `BorrowingController` decouples administrative pauses from autonomous risk pauses using two distinct tracking mappings:
  - `pausedByAdmin[positionId]`: Tracks manual emergency pauses placed by the contract owner via `emergencyPauseBorrowing(positionId)`.
  - `pausedByRiskBreach[positionId]`: Tracks automated risk breach pauses dispatched by the cross-chain callback adapter via `pauseBorrowing(positionId, nonce, ...)`.
  - `isBorrowingPaused[positionId]`: Represents the effective composite pause state (`pausedByAdmin || pausedByRiskBreach`). Borrowing is blocked if either condition is active.
- **Independence & Non-Clobbering:** When an autonomous risk-resolution callback arrives (`resolveBorrowing`), it clears `pausedByRiskBreach[positionId] = false`. If `pausedByAdmin[positionId]` is true, `isBorrowingPaused[positionId]` remains `true`, `BorrowingResumed` is not emitted, and borrowing remains safely paused. Autonomous risk recovery cannot clobber governance actions.
- **Ordinary Owner Resume:** `BorrowingController.resumeBorrowing(positionId)` is restricted to clearing administrative pauses (`pausedByAdmin`). If the position is actively paused due to a cross-chain risk breach (`pausedByRiskBreach == true`), it **reverts with `CannotBypassActiveRiskBreach`**.
- **Out-of-Order Delivery Convergence:** `resolveBorrowing` is designed to be idempotent with respect to the pause flag while strictly monotonic with respect to nonces. If network delay or dropped packets cause a resolution callback (e.g., nonce 2) to arrive before an earlier breach callback (e.g., nonce 1), `resolveBorrowing` safely advances `lastProcessedNonce` to 2 and establishes the healthy state without reverting. When the delayed breach message (nonce 1) arrives later, it is rejected as stale (`InvalidNonce(1, 2)`), preventing permanent liveness locks.
- **Emergency Circuit Breaker:** `emergencyResumeBorrowing(positionId, string calldata reason)` allows owner override to clear both pause dimensions only if cross-chain relay infrastructure is permanently disrupted. It mandates a non-empty audit reason string and emits `EmergencyBorrowingResumed` with the caller address, reason, and timestamp for complete on-chain transparency.

### 8. Position ID Invariant on State-Changing Functions
- Zero position IDs (`bytes32(0)`) are invalid protocol-wide for state transitions.
- Every state-changing function across origin and destination that initializes, registers, evaluates, borrows against, pauses, or resumes positions enforces:
  ```solidity
  if (positionId == bytes32(0)) revert InvalidPositionId();
  ```
  This applies to `depositCollateral`, `recordBorrow`, `evaluatePositionRisk`, `assessRisk`, `registerPosition`, `registerPositionFor`, `pauseBorrowing`, `resolveBorrowing`, `emergencyPauseBorrowing`, `resumeBorrowing`, `emergencyResumeBorrowing`, `borrow`, `handleRiskBreach`, and `handleRiskResolved`.
- `CrossGuardReactive.react()` silently rejects event logs containing zero position IDs (`ReactiveEventRejected(..., "ZERO_POSITION_ID")`).
- Read-only mapping getters (such as `getPosition`, `positionOwners`, `isBorrowingPaused`, `positionNonce`) return default empty values for uninitialized keys in accordance with standard EVM mapping behavior without reverting.

### 9. Fail-Closed Deployment Network Preflight Guards
- Every deployment and configuration script enforces a fail-closed `block.chainid` preflight check before calling `vm.startBroadcast()`:

| Script | Target Network | Enforced Chain ID | Preflight Guard Revert Message |
| :--- | :--- | :---: | :--- |
| `DeployOrigin.s.sol` | Base Sepolia | `84532` | `"Unsupported execution network: must run on Base Sepolia (84532)"` |
| `DeployReactive.s.sol` | Reactive Lasna | `5318007` | `"Unsupported execution network: must run on Reactive Lasna (5318007)"` |
| `DeployDestination.s.sol` | Unichain Sepolia | `1301` | `"Unsupported execution network: must run on Unichain Sepolia (1301)"` |
| `ConfigureReactive.s.sol` | Reactive Lasna | `5318007` | `"Unsupported execution network: must run on Reactive Lasna (5318007)"` |

- **Destination Deployment Limitation:** In `DeployDestination.s.sol`, the script rejects zero address (`address(0)`) and the deployer's own EOA address for `REACTIVE_CROSSGUARD`. However, because `REACTIVE_CROSSGUARD` lives on Reactive Lasna (`5318007`) while the script executes on Unichain Sepolia (`1301`), the Unichain node cannot inspect bytecode on the foreign chain (`extcodesize` on Unichain for a Lasna address is 0). Verification across chains depends on strict deployment sequencing and operational address verification.

### 10. Controlled Callback Recovery, Durable Event Dispatch & Cross-Chain Reconciliation (M006, M006.1 & M006.2)
- **Origin Event Idempotency:** `RiskController.assessRisk()` enforces transition-only event emission. When an evaluated position remains breached across multiple evaluations, `isPositionBreached` remains true, `positionNonce` does not advance, and redundant `RiskBreach` events are suppressed. Events emit strictly on state transitions (`Healthy -> Breached` and `Breached -> Healthy`).
- **Reactive Monotonic Nonce Ordering & Durable Pending Dispatch (M006.1):** `CrossGuardReactive.react()` enforces monotonic per-position nonces (`latestOriginNonce[positionId]`), dropping duplicate or out-of-order events via `StaleOriginEventIgnored`. When a valid origin event arrives while destination configuration is incomplete (`destinationCallback == address(0)` or `callbackGasLimit < MIN_CALLBACK_GAS_LIMIT`), `CrossGuardReactive` durably stores the payload with `DispatchStatus.PENDING_DISPATCH`, emits `CallbackDispatchDeferred`, and emits `PendingCallbackSuperseded` if superseded by a newer transition.
  - Once configured (`destinationCallback != address(0)`, `destinationChainId == 1301`, `callbackGasLimit >= 100_000`), the authorized owner dispatches the stored event via `dispatchPendingCallback(positionId, expectedNonce)` with `retryCount == 0` preserved and emits `CallbackDispatchSubmitted`.
- **Uniform Callback Gas Minimum (`MIN_CALLBACK_GAS_LIMIT = 100_000`):** Enforced across constructor (including Stage-1 nonzero gas limits), `setDestinationConfig()`, `dispatchPendingCallback()`, and `retryFailedCallback()`.
- **Controlled Same-Nonce Retry:** If a `DispatchStatus.REQUESTED` destination callback fails (e.g., transient revert, gas exhaustion, or proxy funding issue), the authorized owner calls `retryFailedCallback(positionId, expectedNonce, reasonCode)` on Reactive Lasna:
  - Strictly requires `status == DispatchStatus.REQUESTED` (reverts with `CallbackNotRequested` if still `PENDING_DISPATCH`), validates non-zero `reasonCode`, reuses exact stored payload and origin nonce, and is strictly bounded to 3 retries (`MAX_RETRIES = 3`). New origin transitions reset `retryCount` to 0.
- **Destination Monotonic Gating:** `BorrowingController` enforces `require(nonce > lastProcessedNonce[positionId])`. Delivered callbacks advance `lastProcessedNonce` and reject duplicates via `InvalidNonce`, while failed deliveries leave destination state unmutated for safe same-nonce recovery.
- **Configuration Drift Protection, Reconciled Fee Model & Modern ABI Validation (M006.2):** `crossguard_healthcheck.py --recovery-preflight` enforces mandatory `--position-id`, `--expected-nonce`, and `--reactive-tx-hash`, validates exact 20-byte EVM addresses (`validate_evm_address`), enforces 3-way recipient equality (`expected_callback == historical_callback_request_recipient == current_destination_callback` for `RETRY_ELIGIBLE`; `expected_callback == current_destination_callback` for `DISPATCH_REQUIRED`), accepts only authoritative modern `CallbackRequest(uint256,address,address,uint8,bytes)` (`version == 0` / `V_1_0` + valid `CallbackConfiguration_V_1_0`, rejecting legacy `CallbackRequestedV1`), computes conservative fees via `fee = p_base * (_gasPriceCoeffPer1000 / 1000) * (gas_limit + _extraGas)` (keeping `_maxChargeGas` strictly for payment-settlement gas limits), distinguishes System Contract `REACT` warnings from hard Unichain `CallbackProxy` `ETH` delivery blockers, and keeps `suggested_command = None`.

---

## 📁 Repository Structure

```text
├── .github/
│   └── workflows/
│       └── test.yml                    # CI workflow (formatting, build, test)
├── docs/
│   ├── operations/
│   │   ├── CROSSGUARD-OPERATIONS-RUNBOOK.md # Multi-chain operational incident runbook & diagnostic guide
│   │   └── CROSSGUARD-RECOVERY-RUNBOOK.md   # M006/M006.1 SOP for preflight, deferred dispatch & retry
│   ├── reports/                        # Milestone verification and audit reports
│   │   ├── M006-VERIFICATION-REPORT.md   # M006 formal verification & reconciliation report
│   │   ├── M006.1-VERIFICATION-REPORT.md # M006.1 remediation & invariant verification report
│   │   └── M006.2-VERIFICATION-REPORT.md # M006.2 drift, fee-model & ABI reconciliation report
│   └── security/
│       ├── M004-THREAT-MODEL.md        # Comprehensive multi-chain threat model & adversarial matrix
│       └── M006-RECOVERY-THREAT-MODEL.md # M006/M006.1/M006.2 recovery threat model (34 vectors)
├── script/
│   ├── ops/
│   │   └── crossguard_healthcheck.py   # Read-only health check & recovery preflight diagnostic CLI
│   ├── DeployOrigin.s.sol              # Base Sepolia origin deployment script (network-guarded: 84532)
│   ├── DeployDestination.s.sol         # Unichain Sepolia destination deployment script (network-guarded: 1301)
│   ├── DeployReactive.s.sol            # Reactive Lasna deployment script (network-guarded: 5318007)
│   └── ConfigureReactive.s.sol         # Reactive Lasna destination linking script (network-guarded: 5318007)
├── src/
│   ├── interfaces/
│   │   ├── IBorrowingController.sol    # Destination lending pool interface
│   │   ├── ICollateralVault.sol        # Origin vault interface
│   │   ├── ICrossGuardCallback.sol     # Destination callback receiver interface
│   │   ├── IRiskController.sol         # Origin risk engine interface
│   │   ├── ISystemContract.sol         # Reactive Omni system interface
│   │   └── ITestValuationSource.sol    # Valuation oracle interface
│   ├── origin/
│   │   ├── CollateralVault.sol         # Vault managing collateral, debt, and borrow safety
│   │   ├── RiskController.sol          # Authoritative fixed-point risk engine & event emitter
│   │   └── TestValuationSource.sol     # Configurable mock price oracle
│   ├── destination/
│   │   ├── BorrowingController.sol     # Lending controller with nonce replay checks & emergency modes
│   │   └── CrossGuardCallback.sol      # Callback proxy & injected address authenticator
│   └── reactive/
│       └── CrossGuardReactive.sol      # Autonomous reactive event listener, storage & controlled retry
├── test/
│   ├── integration/
│   │   └── CrossGuardE2E.t.sol         # Full cross-chain reactive lifecycle & recovery simulation
│   ├── mocks/
│   │   └── MockOmniSystemContract.sol  # In-memory mock of Reactive Omni System Contract
│   ├── ops/
│   │   └── test_crossguard_healthcheck.py # Offline unit tests for operational health check & preflight (104 tests)
│   └── unit/
│       ├── BorrowingController.t.sol   # Unit tests for destination lending & nonce mechanics
│       ├── CollateralVault.t.sol       # Unit tests for collateral vault & borrow safety
│       ├── ConfigurationConsistency.t.sol # Cross-chain configuration & topology consistency tests
│       ├── CrossGuardCallback.t.sol    # Unit tests for callback proxy & sender authentication
│       ├── CrossGuardReactive.t.sol    # Unit tests for reactive event filtering, pending storage & retry
│       ├── M004AdversarialSecurity.t.sol # Adversarial security, out-of-order delivery & invariant fuzzing
│       ├── M006Recovery.t.sol          # 18 unit recovery scenarios + 6 stateful handler invariants (256 runs)
│       ├── RiskController.t.sol        # Unit tests for fixed-point LTV math & transition idempotency
│       ├── ScriptPreflight.t.sol       # Unit tests for all 4 deployment network guards
│       └── TestValuationSource.t.sol   # Unit tests for valuation oracle
├── .env.example                        # Template for multi-chain RPCs and contract addresses
├── foundry.toml                        # Foundry toolchain configuration (cancun, via_ir)
└── remappings.txt                      # Library dependency remappings
```

---

## 🧪 Testing, Simulation & Verification

The testing strategy strictly distinguishes between **unit testing**, **in-memory simulation**, and **live-network deployment**.

> [!IMPORTANT]
> **Simulation vs Live Testnet Execution:**
> - All integration tests (`CrossGuardE2E.t.sol`) execute as **in-memory Foundry simulations** using `MockOmniSystemContract` and `MockCallbackProxy`.
> - **Zero smart contracts have been deployed to live public testnets or mainnets.**
> - Zero live transactions have been broadcast, and zero real or testnet funds have been expended.

### Local Reproduction Instructions

Clone the repository and run all tests locally using Foundry:

```bash
# 1. Verify Foundry toolchain version
forge --version
# Expected: forge Version: 1.8.3 (commit cae51ad458f6abb64852b7709eb784352429825d)

# 2. Check code formatting
forge fmt --check

# 3. Compile contracts and check bytecode sizes
forge build --sizes

# 4. Execute all 169 unit, recovery, invariant, and integration tests with detailed traces
forge test -vvv

# 5. Execute 104 operational health-check and recovery preflight unit tests (mocked RPC)
python -m unittest discover -s test/ops -p "test_*.py"

# 6. Generate local coverage report
forge coverage --ir-minimum
```

### Verified Test Results

```text
Ran 12 Foundry test suites:
- test/unit/BorrowingController.t.sol:BorrowingControllerTest: 20 passed, 0 failed, 0 skipped
- test/unit/CrossGuardReactive.t.sol:CrossGuardReactiveTest: 33 passed, 0 failed, 0 skipped
- test/unit/CollateralVault.t.sol:CollateralVaultTest: 19 passed, 0 failed, 0 skipped
- test/unit/RiskController.t.sol:RiskControllerTest: 21 passed, 0 failed, 0 skipped
- test/unit/CrossGuardCallback.t.sol:CrossGuardCallbackTest: 14 passed, 0 failed, 0 skipped
- test/unit/ConfigurationConsistency.t.sol:ConfigurationConsistencyTest: 10 passed, 0 failed, 0 skipped
- test/unit/TestValuationSource.t.sol:TestValuationSourceTest: 4 passed, 0 failed, 0 skipped
- test/unit/ScriptPreflight.t.sol:ScriptPreflightTest: 4 passed, 0 failed, 0 skipped
- test/unit/M004AdversarialSecurity.t.sol:M004AdversarialSecurityTest: 21 passed, 0 failed, 0 skipped
- test/unit/M006Recovery.t.sol:M006RecoveryTest: 18 passed, 0 failed, 0 skipped
- test/unit/M006Recovery.t.sol:M006RecoveryInvariantTest: 1 passed, 0 failed, 0 skipped (6 stateful invariants; 256 runs, 128,000 calls, 0 reverts)
- test/integration/CrossGuardE2E.t.sol:CrossGuardE2ETest: 4 passed, 0 failed, 0 skipped

Total Foundry Tests: 169 passed, 0 failed, 0 skipped (100% pass rate)

Ran Operational Health Check & Recovery Preflight Test Suite:
- test/ops/test_crossguard_healthcheck.py: 104 passed, 0 failed, 0 errors (100% pass rate)
```

### Verified Contract Bytecode Sizes

| Contract | Runtime Size (Bytes) | Max Limit (24,576 Bytes) | Safety Margin |
| :--- | :--- | :--- | :--- |
| `BorrowingController` | 2,829 B | 24,576 B | 21,747 B (88.5% margin) |
| `CollateralVault` | 3,499 B | 24,576 B | 21,077 B (85.8% margin) |
| `CrossGuardCallback` | 2,314 B | 24,576 B | 22,262 B (90.6% margin) |
| `CrossGuardReactive` | 6,689 B | 24,576 B | 17,887 B (72.8% margin) |
| `RiskController` | 1,847 B | 24,576 B | 22,729 B (92.5% margin) |
| `TestValuationSource` | 695 B | 24,576 B | 23,881 B (97.2% margin) |

### Local Code Coverage Snapshot (`forge coverage --ir-minimum`, M006 Baseline)

> [!NOTE]
> Coverage numbers are measured locally using `forge coverage --ir-minimum`. The GitHub Actions CI workflow runs automated compilation, formatting, and unit tests, but does not run `forge coverage`.

| Source File | Line Coverage | Statement Coverage | Branch Coverage | Function Coverage |
| :--- | :--- | :--- | :--- | :--- |
| `src/destination/BorrowingController.sol` | **97.50%** (78/80) | **94.87%** (74/78) | **84.00%** (21/25) | **100.00%** (11/11) |
| `src/destination/CrossGuardCallback.sol` | **94.59%** (35/37) | **94.44%** (34/36) | **77.78%** (7/9) | **100.00%** (5/5) |
| `src/origin/CollateralVault.sol` | **93.59%** (73/78) | **93.27%** (97/104) | **91.67%** (22/24) | **100.00%** (7/7) |
| `src/origin/RiskController.sol` | **90.91%** (40/44) | **91.49%** (43/47) | **100.00%** (12/12) | **100.00%** (6/6) |
| `src/origin/TestValuationSource.sol` | **100.00%** (10/10) | **100.00%** (9/9) | **100.00%** (2/2) | **100.00%** (3/3) |
| `src/reactive/CrossGuardReactive.sol` | **94.62%** (88/93) | **96.12%** (99/103) | **78.57%** (22/28) | **85.71%** (6/7) |
| `script/ConfigureReactive.s.sol` | **55.56%** (15/27) | **60.61%** (20/33) | 0.00% (0/12) | **100.00%** (1/1) |
| `script/DeployDestination.s.sol` | **44.44%** (12/27) | **45.16%** (14/31) | 0.00% (0/11) | **100.00%** (1/1) |
| `script/DeployOrigin.s.sol` | **37.50%** (6/16) | **35.00%** (7/20) | 0.00% (0/2) | **100.00%** (1/1) |
| `script/DeployReactive.s.sol` | **43.33%** (13/30) | **50.00%** (18/36) | 0.00% (0/17) | **100.00%** (1/1) |
| **All Production Contracts Combined** | **> 94.5%** | **> 94.0%** | **> 85.0%** | **> 97.0%** |

### Verified Continuous Integration (CI)

The repository runs automated GitHub Actions CI (`.github/workflows/test.yml`) validating `forge fmt --check`, `forge build --sizes`, `forge test -vvv`, and Python operational unit tests on Ubuntu runners.

- **Automated Steps:**
  1. `forge --version`
  2. `forge fmt --check`
  3. `forge build --sizes`
  4. `forge test -vvv`
  5. `actions/setup-python@v5` (Python 3.11)
  6. `python -m unittest discover -s test/ops -p "test_*.py"`
- *Note:* CI verifies formatting, build, contract unit/integration tests, and Python health check tests on every push and pull request; coverage reporting is conducted locally.

---

## 🚀 Deterministic 4-Step Deployment Sequence

Because `CrossGuardCallback` on Unichain Sepolia requires the deployed `CrossGuardReactive` address, and `CrossGuardReactive` on Lasna requires the destination callback address, CrossGuard implements a **deterministic 4-stage deployment sequence** to eliminate circular dependency:

```
[Step 1: Base Sepolia (84532)]
 Deploy TestValuationSource, RiskController, CollateralVault
 Record BASE_RISK_CONTROLLER address
                  |
                  v
[Step 2: Reactive Lasna (5318007)]
 Deploy CrossGuardReactive with BASE_RISK_CONTROLLER and UNICHAIN_CALLBACK_ADAPTER = address(0)
 Record REACTIVE_CROSSGUARD address
                  |
                  v
[Step 3: Unichain Sepolia (1301)]
 Deploy BorrowingController and CrossGuardCallback passing REACTIVE_CROSSGUARD
 Record UNICHAIN_CALLBACK_ADAPTER address
                  |
                  v
[Step 4: Reactive Lasna (5318007)]
 Run ConfigureReactive script to call setDestinationConfig(1301, UNICHAIN_CALLBACK_ADAPTER, 300000)
 Cross-chain pipeline fully linked and active
```

### Deployment Commands

#### Step 1: Deploy Origin Infrastructure (Base Sepolia)
*Enforces `block.chainid == 84532` runtime preflight check:*
```bash
forge script script/DeployOrigin.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC \
  --broadcast
```

#### Step 2: Deploy Reactive Engine (Reactive Lasna)
*Enforces `block.chainid == 5318007` runtime preflight check:*
```bash
BASE_RISK_CONTROLLER=<deployed_controller_address> \
forge script script/DeployReactive.s.sol \
  --rpc-url $REACTIVE_LASNA_RPC \
  --broadcast
```

#### Step 3: Deploy Destination Infrastructure (Unichain Sepolia)
*Enforces `block.chainid == 1301` runtime preflight check:*
```bash
REACTIVE_CROSSGUARD=<deployed_reactive_contract_address> \
forge script script/DeployDestination.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --broadcast
```

#### Step 4: Link Destination Callback in Reactive Contract (Reactive Lasna)
*Enforces `block.chainid == 5318007` runtime preflight check:*
```bash
REACTIVE_CROSSGUARD=<deployed_reactive_contract_address> \
UNICHAIN_CALLBACK_ADAPTER=<deployed_callback_adapter_address> \
forge script script/ConfigureReactive.s.sol \
  --rpc-url $REACTIVE_LASNA_RPC \
  --broadcast
```

---

## 🛠️ Operational Observability & Diagnostics

CrossGuard includes an automated, read-only operational health check CLI and an incident diagnosis runbook to monitor and triage the multi-chain deployment:

### 1. Read-Only Health Check CLI (`script/ops/crossguard_healthcheck.py`)

A standalone Python utility using Foundry's `cast` binary under strict operational constraints:
- **Strict Read-Only Command Whitelist:** Only permits `cast chain-id`, `cast code`, `cast call`, `cast balance`, `cast receipt`, `cast gas-price`, and `cast base-fee`. Automatically rejects mutating or state-modifying subcommands (`send`, `publish`, `mktx`, `--broadcast`, `--private-key`).
- **Zero Third-Party Python Dependencies:** Built strictly using Python's standard library (`subprocess`, `json`, `argparse`, `sys`, `urllib.parse`).
- **Centralized RPC Credential Redaction:** Automatically scrubs user-info, sensitive path segments, and query parameters from all terminal outputs, JSON reports, and error messages.
- **Bounded Query Execution:** Enforces a configurable timeout (default: 15.0s) on all subprocess queries to prevent hanging on stalled RPC endpoints.
- **Deterministic Monitoring Exit Codes:** Returns exit code `0` for `HEALTHY`, and exit code `1` for `WARNING`, `CRITICAL`, `UNKNOWN`, and `ERROR` for automated monitoring pipelines.
- **Exhaustive Multi-Chain Inspection:**
  1. Network connectivity and chain ID validation (Base Sepolia `84532`, Reactive Lasna `5318007`, Unichain Sepolia `1301`).
  2. Contract bytecode verification at all configured addresses.
  3. Cross-chain contract configuration wiring (matching controller addresses and callback recipient).
  4. Reactive reserve and debt accounting for both the Reactive System Contract (`0x8888...8888`) and the Unichain Callback Proxy (`0x9299...7FC4`).
  5. Callback gas limit verification (enforcing $\ge 100,000$ gas).
  6. Operational advisory for `CrossGuardReactive.pay()` (`"Not implemented"` warning; funds must be routed via `depositTo(address)`).
  7. Historical callback status checks via optional `--reactive-tx-hash` using official 6-field return schema `getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])` (`blockNumber`, `reactiveContract`, `callbackIndex`, `destinationChainId`, `destinationTxHash`, `error`), validating destination execution confirmation and preserving exact revert bytes.

#### Running the Health Check

```bash
# Execute health check using environment variables from .env
python script/ops/crossguard_healthcheck.py

# Output structured JSON for automated alerting / monitoring pipelines
python script/ops/crossguard_healthcheck.py --json

# Run health check against custom RPCs and contract addresses
python script/ops/crossguard_healthcheck.py \
  --base-rpc https://sepolia.base.org \
  --reactive-rpc https://lasna-rpc.reactive.network \
  --unichain-rpc https://sepolia.unichain.org \
  --origin-risk-controller 0x... \
  --reactive-address 0x... \
  --callback-address 0x... \
  --borrowing-controller-address 0x... \
  --reactive-tx-hash 0x...

# Execute the 104-scenario offline unit test suite (100% mocked RPC)
python -m unittest discover -s test/ops -p "test_*.py"
```

### 2. Read-Only Recovery Preflight Diagnostic Tool (`--recovery-preflight`)

When a cross-chain delivery failure or deferred pending dispatch occurs, operators run the strict fail-closed preflight tool before initiating any manual on-chain recovery action:
```bash
python script/ops/crossguard_healthcheck.py \
  --recovery-preflight \
  --position-id 0x<POSITION_ID> \
  --expected-nonce <EXPECTED_NONCE> \
  --reactive-tx-hash 0x<REACTIVE_ORIGINATING_TX_HASH>
```

- **3-Way Callback Recipient Equality & Drift Detection:** For `RETRY_ELIGIBLE`, enforces exact 20-byte EVM equality `expected_callback == historical_callback_request_recipient == current_destination_callback`; for `DISPATCH_REQUIRED`, requires `expected_callback == current_destination_callback`. Mismatches fail closed (`RETRY_BLOCKED` / `RETRY_UNKNOWN`) and never auto-adopt drifted recipients.
- **Reconciled Fee & Settlement Model:** Applies `fee = p_base * (_gasPriceCoeffPer1000 / 1000) * (gas_limit + _extraGas)` (`p_base = max(gas_price, base_fee)`). `_maxChargeGas` limits payment-settlement gas only and is never added to or compared against `gas_limit + _extraGas`. Separates Reactive `SystemContract` (`REACT` warnings for automated `react()`, strict blocking only with `--require-reactive-reserves`) from Unichain `CallbackProxy` (`ETH`, hard blocker for destination delivery) and marks effective forwarded destination gas `< callbackGasLimit` as unverified statically.
- **Deterministic State Classification (7 States):**
  - `DISPATCH_REQUIRED`: Valid event stored on Reactive as `PENDING_DISPATCH` due to incomplete destination config during `react()`; eligible for `dispatchPendingCallback()` (`retryCount == 0` preserved) after matching config & Callback Proxy funding checks pass.
  - `RETRY_ELIGIBLE`: `REQUESTED` delivery confirmed failed (`error` bytes present with nonzero `destinationTxHash`), destination nonce unadvanced, retry budget available ($< 3$), 3-way callback addresses match, modern `CallbackRequest` `V_1_0` ABI verified, Callback Proxy debts clear, and proxy reserves cover `estimated_fee * safety_multiplier`.
  - `RETRY_ALREADY_SUCCEEDED`: Destination already processed nonce cleanly without drift or contradictions.
  - `RETRY_PENDING`: Callback requested on Reactive Lasna but pending relayer execution (`destinationTxHash == 0` with empty error, or empty callback array).
  - `RETRY_SUPERSEDED`: Origin `positionNonce`, Reactive `latestOriginNonce`, or stored callback nonce has exceeded `expectedNonce`.
  - `RETRY_BLOCKED`: Callback recipient drift (`expected != current` / `historical != current`), Callback Proxy debt/low reserves, zero/insufficient `_maxChargeGas` settlement allowance, unconfigured destination, `callbackGasLimit < 100_000`, 3-retry limit exhausted, or `--require-reactive-reserves` policy block.
  - `RETRY_UNKNOWN`: Missing mandatory inputs, malformed/truncated EVM address, RPC/ABI failure, unparseable fee telemetry, uint256 overflow, unsupported `CallbackVersion` / legacy `CallbackRequestedV1`, ambiguous callback records, or cross-chain contradictions.
- **Safety Guarantee:** Tool is strictly read-only, keeps `suggested_command = None` (never emits copy-paste `cast send` commands), and prints `Execution: NOT PERFORMED (read-only preflight diagnostic)`.

### 3. Incident Response & Recovery Runbooks

- **Operations Runbook (`docs/operations/CROSSGUARD-OPERATIONS-RUNBOOK.md`):** Multi-chain failure scenarios, RPC outages, debt settlement, and telemetry diagnosis.
- **Recovery Runbook (`docs/operations/CROSSGUARD-RECOVERY-RUNBOOK.md`):** 6-phase SOP for fail-closed preflight, **Path A** deferred dispatch recovery (`dispatchPendingCallback()`), and **Path B** controlled retry (`retryFailedCallback()`).

#### Controlled Recovery Lifecycle (M006 & M006.1):
- **Path A (Deferred Initial Dispatch):** If `react()` stored an event as `PENDING_DISPATCH`, `dispatchPendingCallback(positionId, expectedNonce)` submits the initial callback without consuming retry quota (`retryCount == 0`).
- **Path B (Same-Nonce Failure Retry):** Once submitted (`REQUESTED`), if destination execution fails, `retryFailedCallback(positionId, expectedNonce, reasonCode)` re-dispatches the exact stored payload and nonce (rate-limited to `MAX_RETRIES = 3`; new origin transitions reset the budget).
- Destination EVM reverts leave `lastProcessedNonce` unadvanced; both recovery paths safely rely on destination monotonic nonce gating (`require(nonce > lastProcessedNonce)`).

---

## ⚠️ Protocol Scope, Limitations & Non-Production Notice

This project is an MVP prototype built for the Reactive Network Omni Architecture demonstration:

1. **Non-Production MVP:** The smart contracts have not undergone a third-party commercial security audit. They are intended for demonstration and testnet exploration.
2. **Mock Pricing Oracle:** `TestValuationSource` uses owner-controlled price updates for demonstration. A production implementation would integrate decentralized oracle infrastructure (such as Chainlink Data Feeds or Pyth Network) with staleness thresholds, heartbeat checks, and circuit breakers.
3. **Single Collateral Asset Per Position:** For MVP simplicity, each position in `CollateralVault` supports one collateral token and one debt token. Multi-asset basket collateralization is not supported in this version.
4. **Evaluation Trigger Model:** Risk assessments in `CollateralVault` are triggered on demand via `evaluatePositionRisk()` or `recordBorrow()`. Price updates in the oracle do not automatically execute on-chain state changes on Base Sepolia without a transaction being submitted.
5. **No Funds at Risk:** No mainnet deployment has taken place, and no real capital is secured by these contracts.

---

## 📜 License

SPDX-License-Identifier: MIT

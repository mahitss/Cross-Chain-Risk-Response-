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

---

## 📁 Repository Structure

```text
├── .github/
│   └── workflows/
│       └── test.yml                    # CI workflow (formatting, build, test)
├── docs/
│   ├── operations/
│   │   └── CROSSGUARD-OPERATIONS-RUNBOOK.md # Multi-chain operational incident runbook & diagnostic guide
│   ├── reports/                        # Milestone verification and audit reports
│   └── security/
│       └── M004-THREAT-MODEL.md        # Comprehensive multi-chain threat model & adversarial matrix
├── script/
│   ├── ops/
│   │   └── crossguard_healthcheck.py   # Read-only multi-chain operational health check CLI
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
│       └── CrossGuardReactive.sol      # Autonomous reactive event listener & callback dispatcher
├── test/
│   ├── integration/
│   │   └── CrossGuardE2E.t.sol         # Full cross-chain reactive lifecycle simulation (in-memory)
│   ├── mocks/
│   │   └── MockOmniSystemContract.sol  # In-memory mock of Reactive Omni System Contract
│   ├── ops/
│   │   └── test_crossguard_healthcheck.py # Offline unit tests for operational health check (20 scenarios)
│   └── unit/
│       ├── BorrowingController.t.sol   # Unit tests for destination lending & nonce mechanics
│       ├── CollateralVault.t.sol       # Unit tests for collateral vault & borrow safety
│       ├── ConfigurationConsistency.t.sol # Cross-chain configuration & topology consistency tests
│       ├── CrossGuardCallback.t.sol    # Unit tests for callback proxy & sender authentication
│       ├── CrossGuardReactive.t.sol    # Unit tests for reactive event filtering & validation
│       ├── M004AdversarialSecurity.t.sol # Adversarial security, out-of-order delivery & invariant fuzzing
│       ├── RiskController.t.sol        # Unit tests for fixed-point LTV math & event emission
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

# 4. Execute all 136 unit, invariant, and integration tests with detailed traces
forge test -vvv

# 5. Execute 20 operational health-check unit tests (mocked RPC)
python -m unittest discover -s test/ops -p "test_*.py"

# 6. Generate local coverage report
forge coverage --ir-minimum
```

### Verified Test Results

```text
Ran 10 Foundry test suites:
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

Total Foundry Tests: 136 passed, 0 failed, 0 skipped (100% pass rate)

Ran Operational Health Check Test Suite:
- test/ops/test_crossguard_healthcheck.py: 20 passed, 0 failed, 0 errors (100% pass rate)
```

### Verified Contract Bytecode Sizes

| Contract | Runtime Size (Bytes) | Max Limit (24,576 Bytes) | Safety Margin |
| :--- | :--- | :--- | :--- |
| `BorrowingController` | 2,829 B | 24,576 B | 21,747 B (88.5% margin) |
| `CollateralVault` | 3,499 B | 24,576 B | 21,077 B (85.8% margin) |
| `CrossGuardCallback` | 2,314 B | 24,576 B | 22,262 B (90.6% margin) |
| `CrossGuardReactive` | 3,684 B | 24,576 B | 20,892 B (85.0% margin) |
| `RiskController` | 1,826 B | 24,576 B | 22,750 B (92.6% margin) |
| `TestValuationSource` | 695 B | 24,576 B | 23,881 B (97.2% margin) |

### Local Code Coverage (`forge coverage --ir-minimum`)

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

A standalone Python utility using Foundry's `cast` binary under strict execution constraints:
- **Strict Read-Only Command Whitelist:** Only permits `cast chain-id`, `cast code`, `cast call`, and `cast balance`. Automatically rejects mutating or state-modifying subcommands (`send`, `publish`, `mktx`, `--broadcast`, `--private-key`).
- **Zero Third-Party Python Dependencies:** Built strictly using Python's standard library (`subprocess`, `json`, `argparse`, `sys`).
- **Exhaustive Multi-Chain Inspection:**
  1. Network connectivity and chain ID validation (Base Sepolia `84532`, Reactive Lasna `5318007`, Unichain Sepolia `1301`).
  2. Contract bytecode verification at all configured addresses.
  3. Cross-chain contract configuration wiring (matching controller addresses and callback recipient).
  4. Reactive reserve and debt accounting for both the Reactive System Contract (`0x8888...8888`) and the Unichain Callback Proxy (`0x9299...7FC4`).
  5. Callback gas limit verification (enforcing $\ge 100,000$ gas).
  6. Operational advisory for `CrossGuardReactive.pay()` (`"Not implemented"` warning).
  7. Historical callback status checks via optional `--callback-id` or `--position-id`.

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
  --risk-controller 0x... \
  --vault 0x... \
  --reactive-contract 0x... \
  --callback-adapter 0x... \
  --borrowing-controller 0x...

# Execute the 20-scenario offline unit test suite (100% mocked RPC)
python -m unittest discover -s test/ops -p "test_*.py"
```

### 2. Operational Runbook (`docs/operations/CROSSGUARD-OPERATIONS-RUNBOOK.md`)

A comprehensive operational manual covering **16 multi-chain failure scenarios** following a standardized 5-step diagnostic process:
1. **Detection:** CLI symptom, log signature, or metric alert.
2. **Evidence Collection:** Specific read-only CLI commands and RPC calls.
3. **Root-Cause Isolation:** Deterministic diagnosis logic.
4. **Authorized Remediation:** Exact manual or administrative steps required.
5. **Post-Remediation Verification:** CLI checks to confirm healthy restoration.

#### Covered Scenarios:
- **Origin (Base Sepolia):** RPC outage, paused oracle, invalid/stale price feed, zero-ID registration rejection.
- **Reactive Engine (Lasna):** RPC outage, reactive contract debt / exhausted reserve, insufficient callback gas limit, unconfigured destination callback adapter, `pay()` non-implementation.
- **Relayer & Delivery:** Omni relayer latency, callback proxy debt / insufficient execution reserves, callback proxy revert.
- **Destination (Unichain Sepolia):** Callback authentication failure, duplicate/stale nonce revert, administrative pause state conflict, unmapped position ID.

#### Callback Retry & Recovery Boundary:
- The protocol **does not support automatic destination retries**; duplicate nonces are strictly rejected on Unichain Sepolia to prevent replay attacks.
- Recovery from a failed callback occurs when market conditions change or an operator triggers origin re-evaluation (`evaluatePositionRisk()`), advancing the origin nonce and generating a fresh, higher-nonce callback.

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

# CrossGuard: Autonomous Cross-Chain Risk-Response Protocol

CrossGuard is an autonomous cross-chain risk mitigation protocol powered by the **Reactive Network Omni Architecture**.

When collateral risk conditions (such as market crashes or loan-to-value health deterioration) originate on **Base Sepolia (Chain ID: 84532)**, the protocol's Reactive Smart Contract on **Reactive Lasna (Chain ID: 5318007)** autonomously intercepts the event log, verifies policy conditions, and dispatches an authenticated cross-chain callback to **Unichain Sepolia (Chain ID: 1301)**. On Unichain Sepolia, an authorized callback adapter immediately pauses further borrowing for the affected position.

---

## 🏗️ Architecture Overview

```text
       ORIGIN CHAIN: BASE SEPOLIA (84532)
  +--------------------------------------------------+
  |              TestValuationSource                 |
  |  - Mock price oracle for WETH / USDC assets      |
  +------------------------+-------------------------+
                           |
                           v
  +--------------------------------------------------+
  |                CollateralVault                   |
  |  - Tracks collateral and borrow debt             |
  |  - Calls evaluatePositionRisk(positionId)        |
  +------------------------+-------------------------+
                           |
                           v
  +--------------------------------------------------+
  |                 RiskController                   |
  |  - Configurable LTV threshold (e.g. 8000 bps)    |
  |  - Emits: RiskBreach(positionId, user, ltv, ...) |
  +------------------------+-------------------------+
                           |
                           | Event Emitted on Base Sepolia
                           v
        REACTIVE NETWORK: LASNA TESTNET (5318007)
  +--------------------------------------------------+
  |               CrossGuardReactive                 |
  |  - Subscribed to RiskController events           |
  |  - Validates origin chainId == 84532 & emitter   |
  |  - Dispatches cross-chain Callback to Unichain   |
  +------------------------+-------------------------+
                           |
                           | Relayer via Callback Proxy (0x9299472A...)
                           v
     DESTINATION CHAIN: UNICHAIN SEPOLIA (1301)
  +--------------------------------------------------+
  |               CrossGuardCallback                 |
  |  - Inherits AbstractCallback                     |
  |  - Enforces authorizedSenderOnly (Proxy check)   |
  |  - Authenticates injected ReactVM ID             |
  +------------------------+-------------------------+
                           |
                           v
  +--------------------------------------------------+
  |              BorrowingController                 |
  |  - Lending facility tracking position borrowing  |
  |  - Sets isBorrowingPaused[positionId] = true     |
  |  - Reverts future borrow() attempts              |
  |  - Emergency recovery / unpause circuit breaker  |
  +--------------------------------------------------+
```

---

## 🔒 Security & Authorization Highlights

1. **Dual-Layer Callback Authentication:**
   - **Layer 1 (Proxy Validation):** Destination callback enforces `authorizedSenderOnly` to guarantee `msg.sender == UNICHAIN_CALLBACK_PROXY` (`0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`).
   - **Layer 2 (ReactVM ID Injection):** The Reactive relayer replaces the first 160 bits with the deployer RVM ID. `CrossGuardCallback` asserts `rvmSender == authorizedReactiveSender`.
2. **Origin Validation:**
   - `CrossGuardReactive.react()` strictly checks `log.chain_id == 84532` and `log._contract == originRiskController`. Malicious or spoofed events on other chains or contracts are silently discarded.
3. **Idempotency & Replay Resistance:**
   - Position pausing is idempotent. Duplicate callback delivery safely updates the state without reverting or bricking the contract.
   - Rejects stale callbacks (`timestamp < lastRiskBreachTimestamp[positionId]`).
4. **Administrative Recovery:**
   - Lending facility owners can call `resumeBorrowing(positionId)` to unpause positions once collateral is replenished or debt remediated.

---

## 📁 Repository Structure

```text
├── src/
│   ├── interfaces/
│   │   ├── ITestValuationSource.sol
│   │   ├── IRiskController.sol
│   │   ├── ICollateralVault.sol
│   │   ├── IBorrowingController.sol
│   │   └── ICrossGuardCallback.sol
│   ├── origin/
│   │   ├── TestValuationSource.sol
│   │   ├── RiskController.sol
│   │   └── CollateralVault.sol
│   ├── destination/
│   │   ├── BorrowingController.sol
│   │   └── CrossGuardCallback.sol
│   └── reactive/
│       └── CrossGuardReactive.sol
├── test/
│   ├── unit/
│   │   ├── TestValuationSource.t.sol
│   │   ├── RiskController.t.sol
│   │   ├── CollateralVault.t.sol
│   │   ├── BorrowingController.t.sol
│   │   ├── CrossGuardCallback.t.sol
│   │   └── CrossGuardReactive.t.sol
│   └── integration/
│       └── CrossGuardE2E.t.sol
├── script/
│   ├── DeployOrigin.s.sol
│   ├── DeployDestination.s.sol
│   └── DeployReactive.s.sol
├── foundry.toml
├── remappings.txt
└── .env.example
```

---

## 🧪 Testing & Simulation

The test suite leverages Foundry and **`reactive-test-lib`** to simulate the complete cross-chain reactive lifecycle in memory without spending live testnet gas:

```bash
# Run all unit and integration tests
forge test -vvv

# Run test coverage report
forge coverage
```

### Test Results
- **Total Tests:** 46 passed, 0 failed, 0 skipped.
- **Unit Test Suites:** 6 suites covering math, state transitions, access controls, edge cases, and reverts.
- **End-to-End Simulation:** Full Base Sepolia -> Reactive Lasna -> Unichain Sepolia reactive lifecycle test.
- **Coverage:** Core smart contracts have $> 94\%$ line coverage and $100\%$ function coverage.

---

## 🚀 Multi-Chain Deployment Guide

### Prerequisites
1. Copy `.env.example` to `.env` and provide your testnet `DEPLOYER_PRIVATE_KEY`:
   ```bash
   cp .env.example .env
   ```
2. Fund deployer wallet with:
   - Base Sepolia ETH (from Base / Superchain faucets)
   - Unichain Sepolia ETH (from Unichain faucet)
   - Reactive Lasna `lREACT` (by sending Base Sepolia ETH to faucet swap contract `0x2afaFD298b23b62760711756088F75B7409f5967`)

### Step 1: Deploy Destination Layer (Unichain Sepolia)
```bash
forge script script/DeployDestination.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --broadcast
```

### Step 2: Deploy Origin Layer (Base Sepolia)
```bash
forge script script/DeployOrigin.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC \
  --broadcast
```

### Step 3: Deploy Reactive Engine (Reactive Lasna)
Update `BASE_RISK_CONTROLLER` and `UNICHAIN_CALLBACK_ADAPTER` in `.env`, then:
```bash
forge script script/DeployReactive.s.sol \
  --rpc-url $REACTIVE_LASNA_RPC \
  --broadcast
```

### Step 4: Authorize Reactive Contract on Destination
On Unichain Sepolia, call:
```bash
cast send $UNICHAIN_CALLBACK_ADAPTER \
  "setAuthorizedReactiveSender(address)" $REACTIVE_CROSSGUARD \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --private-key $DEPLOYER_PRIVATE_KEY
```

---

## 📜 License
MIT License. Built for the Reactive Network Omni Ecosystem.

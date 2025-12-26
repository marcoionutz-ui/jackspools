# JACKs Pools – Autonomous Reward Distribution Protocol on Base

JACKs Pools is an autonomous onchain reward distribution system designed for Base.
The protocol features **permanent, ever-growing liquidity**, a **buyer reward cycle** with a
4,096-entry circular buffer system, an **LP reward cycle** for top contributors, and a regenerative
economic model where every interaction (buy, sell, LP add) strengthens the protocol.

The system is fully non-custodial and non-ruggable:
- Liquidity is permanent and can only increase  
- No owner functions remain after initialization  
- All rewards are claim-based (pull payments)  
- All logic is deterministic, self-contained, and onchain  

---

## Architecture Overview

### 1. `JACKsPools.sol` – ERC20 Core

- Buy/sell incentives routed into:
  - Buyer Reward Vault (ETH rewards for buyers)
  - LP Reward Vault (ETH rewards for liquidity providers)
  - Burn address (supply reduction)
- Auto-liquidity engine on Base
- Dynamic stages based on total LP value:
  - min buy
  - max wallet (removed at high LP)
  - reward thresholds
- Cooldown between buys, sell lock and slippage constraints

### 2. `JACKsVault.sol` – Buyer Reward Vault

- 8 × 512 circular entry buffers (4,096 total entries)
- Round-based reward cycles:
  - entries added only if buy size & token balance meet stage requirements
  - one active entry per address per round
- Snapshot + delayed reveal for entropy separation
- Time-based entry expiry
- Pull-payment reward claiming with safety limits

### 3. `JACKsLPVault.sol` – LP Reward Vault

- Lifetime LP contribution tracking
- Max 400 active participants per reward cycle (buffer capacity)
- Eviction algorithm:
  - when buffer is full, the lowest contributor can be replaced by a bigger contributor
- Top-60 contributors receive proportional ETH rewards per cycle:
  - Top 10 share 60% of the pool
  - Ranks 11–60 share 40% of the pool
- Gas optimization: full sorting replaced with a bounded Top-K selection approach, preserving payout correctness while reducing gas
- Snapshot → finalization → claim lifecycle
- Claim deadline + accounting for unclaimed rewards

### 4. `JACKsLPManager.sol`

- Helper contract for adding LP via the router
- Registers LP contributions into the LP Reward Vault
- Keeps LP flow standardized and onchain

---

## Security assumptions

- All reward finalization functions are permissionless and can be called by anyone.
- Time-gated mechanisms are enforced onchain (round durations, finalize delays).
- ETH rewards are distributed using pull-payment patterns only.
- No external contracts are trusted for reward calculation.
- No privileged owner functions exist after initialization.
- Reward selection logic is deterministic given onchain state.
- Liquidity is permanent and can only increase over time.

## Integration Simulations (Foundry Scripts)

Instead of classical unit tests, the repo uses full integration simulations running on a Base mainnet fork.

## Validation Artifacts

Fork, invariant, and static analysis outputs are included under `/docs/tests`:
- End-to-end fork simulations
- High-load LP scenarios (400 participants, eviction)
- Invariant testing (accounting, lifecycle, idempotency)
- Slither static analysis report is included under `/docs/tests/SlitherReport.txt`.
  Some findings are expected for this design (best-effort randomness, timestamp-gated rounds, ETH payouts via pull-payments).
  See `/docs/tests/README.md` for a short explanation.

### `script/TestBaseCompleteFork.s.sol`

16-phase end-to-end simulation:

- Deployment and wiring of all contracts
- Initial liquidity
- Multiple buyer reward cycles
- Multiple LP contribution cycles
- Stage transitions based on LP value
- Buy cooldown / sell lock behavior
- Reward snapshots, finalization and claims
- Safety and cleanup paths

### `script/TestBaseAdvanced.s.sol`

High-LP environment simulation:

- 25 ETH initial LP (Stage 5)
- Multiple consecutive buyer reward cycles
- LP buffer saturation and eviction
- Full LP reward distribution cycle
- Stress-testing permanent LP growth logic

### How to run the simulations

```bash
forge install
forge build

forge script script/TestBaseCompleteFork.s.sol:TestBaseCompleteFork \
  --fork-url $BASE_RPC_MAINNET -vvv

forge script script/TestBaseAdvanced.s.sol:TestBaseAdvanced \
  --fork-url $BASE_RPC_MAINNET -vvv
```

## Environment

The following environment variables are required to run fork-based simulations and deployment scripts:

BASE_RPC_MAINNET – Base mainnet RPC endpoint (used for fork simulations)
BASE_RPC_SEPOLIA – Base Sepolia RPC endpoint (used for testnet deployments)
PRIVATE_KEY – Deployer private key (testnet only)

An example configuration is provided in ".env.example".
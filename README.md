# JACKs Pools – Autonomous Reward Distribution Protocol on Base

## Documentation
 **Whitepaper:** [whitepaper/WHITEPAPER.md](whitepaper/WHITEPAPER.md)  
 **Architecture:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

JACKs Pools is an autonomous on-chain reward protocol designed for Base that turns
trading and liquidity activity into recurring reward rounds for participants.
The protocol combines a buyer reward engine with a competitive liquidity leaderboard,
creating two autonomous engagement loops for traders and liquidity providers.
It features permanent, ever-growing liquidity, a buyer reward cycle using a rotating 
buffer system (512 active entries per round), an LP reward cycle for top contributors,
and a regenerative economic model where every interaction (buy, sell, LP add)
strengthens the protocol.

JACKs Pools is designed as a consumer-facing economic game where trading
and liquidity participation continuously fund protocol reward rounds.

The system is fully non-custodial and non-ruggable:
- Liquidity is permanent and can only increase  
- No owner functions remain after initialization  
- All rewards are claim-based (pull payments)  
- All logic is deterministic, self-contained, and on-chain  

---

## Mainnet Candidate Status

JACKs Pools has completed:

- Full end-to-end on-chain validation on Base Sepolia
- Full lifecycle simulation on Base mainnet fork (16/16 phases)
- Invariant validation (accounting, lifecycle, idempotency, permissionlessness)

All core flows have been executed using real transactions, multiple wallets,
and without privileged access.

The current repository state represents the final immutable mainnet candidate,
pending deployment.

### Latest Patch

The Buyer Reward Vault claim system was upgraded to a per-round claim model.

- Rewards are claimed by round ID instead of aggregate balances
- Multiple rounds can be claimed in a single transaction
- Expired unclaimed rewards are recycled back into the active pool via cleanup

This improves long-term accounting correctness and removes historical state inconsistencies,
without changing reward logic or eligibility rules.

The updated system has been fully validated on Base Sepolia.

## Final Design Decisions (Post-Validation)

Following full on-chain validation on Base Sepolia, several final protocol
decisions were made based on real gas usage, user behavior, and griefing analysis:

- Auto tax processing was removed to avoid forcing additional gas costs on users.
  Tax processing is now manual, permissionless, and incentivized with a caller reward.

- True burn was implemented.
  Burned tokens are permanently removed from total supply and are not routed
  to any externally owned or contract address.

- The snapshot reveal delay was increased to strengthen separation between 
  snapshot state and randomness revelation.

- Additional anti-griefing protections were added:
  reward distribution paths are hardened to safely handle contract wallets
  without a payable `receive()` function, preventing reward blocking or denial-of-service.

---

## Architecture Overview

### 1. `JACKsPools.sol` – ERC20 Core

- Buy/sell incentives routed into:
  - Buyer Reward Vault (ETH rewards for buyers)
  - LP Reward Vault (ETH rewards for liquidity providers)
  - True burn (permanent supply reduction)
- Auto-liquidity engine on Base
- Dynamic stages based on total LP value:
  - min buy
  - max wallet (removed at high LP)
  - reward thresholds
- Cooldown between buys, sell lock and slippage constraints

### 2. `JACKsVault.sol` – Buyer Reward Vault

- 8 rotating buffers with 512 slots each
- Maximum active tickets per single round: 512
- Buffer rotation is used for snapshot/finalization continuity, not concurrent capacity
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
- Keeps LP flow standardized and on-chain

---

## Security assumptions

- All reward finalization functions are permissionless and can be called by anyone.
- Time-gated mechanisms are enforced on-chain (round durations, finalize delays).
- ETH rewards are distributed using pull-payment patterns only.
- No external contracts are trusted for reward calculation.
- No privileged owner functions exist after initialization.
- Reward selection logic is deterministic given on-chain state.
- Liquidity is permanent and can only increase over time.

## Protocol Properties

- Fully autonomous operation after initialization
- No privileged paths after owner renounce
- Rewards funded entirely through protocol activity
- Permanent liquidity growth mechanism
- Competitive liquidity leaderboard for LP contributors
- Deterministic reward logic based on on-chain state (with entropy derived from block data and user participation)

## Integration Simulations (Foundry Scripts)

The repository uses both fork-based full integration simulations and invariant testing. 

## Validation Artifacts

Fork, invariant, and static analysis outputs are included under `/docs/tests`:
- End-to-end fork simulations
- High-load LP scenarios (400 participants, eviction)
- Invariant testing (accounting, lifecycle, idempotency)
- Slither static analysis report is included under `/docs/tests/SLITHER_REPORT.txt`.
  Some findings are expected for this design (best-effort randomness, timestamp-gated rounds, ETH payouts via pull-payments).
  See `/docs/tests/README.md` for a short explanation.
  
## Base Sepolia Deployment

A new deployment has been completed with the final autonomous design.

**Contracts:**

- JACKsPools (ERC20): https://sepolia.basescan.org/address/0x483968eeDaAD1A6A801d6E02599bc514549198ea  
- JACKsVault (Buyer Rewards): https://sepolia.basescan.org/address/0x3A1478aaE9ecEa73abFf589048B6f321d215Da30  
- JACKsLPVault (LP Rewards): https://sepolia.basescan.org/address/0xD90866ab0D616634efb1530C894Bd356acd3c4d5  
- JACKsLPManager: https://sepolia.basescan.org/address/0x8158cfc37Dc6856cDdA4C15F6027C34F7aC0C86e  
- Pair: https://sepolia.basescan.org/address/0xe3518e6AE4cCb99616183a5B04037107aEd487AE  

## On-chain Validation Transactions (Base Sepolia)

The following transactions demonstrate the full protocol lifecycle executed on Base Sepolia.

### Core Flow (Buyer Rewards)

- Process protocol taxes  
  https://sepolia.basescan.org/tx/0x32dda62ecb9a5a968176967b1ddadae054e43ec27207f8ab4497f5849b9a01fb

- Buyer reward finalize  
  https://sepolia.basescan.org/tx/0x0196ad9c3cea2eaca17cc349bff2d31ad605533be864542aa5b1dee0a256cdfa

- Buyer reward claim  
  https://sepolia.basescan.org/tx/0x6348cbce9342eacb59e402f638391c7e1cf4c6b61217c95367e807c89c8d5a2a

- Cleanup expired claims (funds recycled into pool)  
  https://sepolia.basescan.org/tx/0xcde9b52cf35d30c14e0545d3d31f4e68d95e899bc65c0923e405bda379761b9e

- Max wallet enforcement (Stage 1 revert)  
  https://sepolia.basescan.org/tx/0xf3aa65157b9f574e9cc457370265e280fd78664d3571eb87ff2ed4faee893248

### Edge Case Handling

- Snapshot timeout → auto-reset (round safely restarted after inactivity)  
  Demonstrates protocol recovery when a round is not finalized in time
  https://sepolia.basescan.org/tx/0xd7ba074dbfc20acbf2f8f8f01493f991567b2a145447f19073f42af517e9b6db

### LP Competition & Reward Cycle (Fully Validated)

The following transactions demonstrate the complete LP lifecycle, including buffer saturation, eviction mechanics, reward distribution, claims, and cleanup.

#### Buffer Mechanics

- Buffer full → low contribution rejected (not eligible for ranking)  
  https://sepolia.basescan.org/tx/0xc215f57456552df5f3a994e104a214b27fba63adf6d9413a2825e40d40ae3992

- Buffer full → lowest contributor replaced by higher contributor  
  Demonstrates deterministic eviction and capped leaderboard (max 400 participants)  
  https://sepolia.basescan.org/tx/0x6301f347d6e52015466249ddcfbf1b932323570bf042ea3772ba5091cc9d998a

#### Round Lifecycle

- LP round snapshot → contributors frozen for reward calculation  
  Snapshot is automatically triggered when pool threshold is reached

- LP round finalized by a participating wallet  
  Demonstrates permissionless finalization (no admin required)  
  https://sepolia.basescan.org/tx/0x0b993c4a866eccc2f4ed0f1a10afbc383264fb062e4379d0b41b791ab3b6df7b

#### Reward Claims

- Rewards claimed by multiple LP participants  
  https://sepolia.basescan.org/tx/0xbde5535b437a28619a337c0286650ff2a284977f7d735200250588097fcf2622  
  https://sepolia.basescan.org/tx/0x758cf44ba984e0c5246f70e9c067b88abad7f69f1944ee870ea40cd6bda47938  

#### Cleanup (Full Lifecycle Completion)

- Expired LP rewards cleaned and recycled back into pool  
  Demonstrates long-term solvency and non-blocking reward system  
  https://sepolia.basescan.org/tx/0x9c9fa773b035b8692203edabbfc2f259adfcd854fdc861d0ea041dc20a15d698

#### What this demonstrates

- Bounded LP participation (max 400 contributors per round)
- Deterministic eviction based on contribution size
- Fully permissionless round finalization
- Proportional reward distribution across tiers
- Claim-based payouts with no push transfers
- Complete lifecycle closure via cleanup of expired rewards

All mechanisms are executed and verifiable on-chain.

---

## Status

Mainnet candidate. Full on-chain lifecycle validation completed on Base Sepolia.

## Frontend (Base Sepolia)

A full frontend is available for interacting with the protocol on Base Sepolia:

https://jackspoolswebsite.vercel.app/

 **Note on testnet configuration**

> The Base Sepolia deployment uses **reduced thresholds and shorter timings**
> compared to the intended mainnet configuration.
>
> This is done strictly to allow faster iteration, multiple full reward cycles,
> and easier on-chain validation under testnet conditions.
>
> Core logic, security assumptions, and lifecycle behavior are identical
> between testnet and the mainnet candidate.

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

- High initial LP setup
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

---

This repository represents the final mainnet candidate state of the JACKs Pools protocol.

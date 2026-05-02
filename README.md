# JACKs Pools – Autonomous Reward Distribution Protocol on Base

## LIVE ON BASE MAINNET

JACKs Pools is now live and running autonomously on Base mainnet.

- Verified contracts  
- Trading enabled  
- Initial liquidity added and permanently burned (LP tokens burned) 
- Ownership fully renounced  
- Buyer and LP reward systems active  
- No upgradeability, no admin control  

**Mainnet Contracts:**

- Token: https://basescan.org/address/0xdd763679EE46C3e0B28ce2f288C5f67ad0d75f67  
- Buyer Vault: https://basescan.org/address/0xb538BB228c72C6c0b19C889a219A5cC3888F90ba  
- LP Vault: https://basescan.org/address/0x85480427d187E56F314Fdb43961017f61902Aa12  
- LP Manager: https://basescan.org/address/0x70176BE3766537239A72aC680B29Ed18D825bCbA  
- Pair: https://basescan.org/address/0x4f54a47Eb7565cb36067e66D3cE3E105e8Cd1F96  

## On-Chain Proof (Base Mainnet)

The following transactions demonstrate the deployed protocol running on Base mainnet.

### Deployment & Initialization

- Initial liquidity added  
  https://basescan.org/tx/0x69fe7fa8b79afdf78c6aabce593168bf4ce67659e3e43fa3b4e11596f5213648

- Trading enabled  
  https://basescan.org/tx/0x7d7118a45dff861ebf03f9c5bebbdfb6b7e68d569c4a1ba7f6f18c4a1fb7df05

### Ownership Renounced

- Token ownership renounced  
  https://basescan.org/tx/0x3e8ffd4cb3740ebe5ef4193fa432c86a59078dbc49fcd51bbac82eb0104d3c7d

- Buyer Vault ownership renounced  
  https://basescan.org/tx/0xfe901c6201274f2131221ad0de0c06651660ec10fe517fc06d9bbf6f2aa5cdc0

### Bootstrap Proof

- Buy executed  
  https://basescan.org/tx/0x3f5e0bac7e7e337252f0e5e2154b01c45fab248d00f7725e07c89502b4b737ad

- Buyer added to reward system  
  https://basescan.org/tx/0xae4faaf512304afc5c27a8f6fdf6d64635bdb741b496eea1727eb0dbb6bf18fb

- Tax processing + Buyer Vault funding  
  https://basescan.org/tx/0x0ebc1bc2d76b95b47eb3d217ade9524df934b23d3d5e4f0a6f3790d7fded8f00

- LP add + contribution tracking  
  https://basescan.org/tx/0x4f6787772059b2230e5a03e8a592b35cb97861efa2fc7d76f5e9444d88cc26da

- LP eligibility + buffer entry  
  https://basescan.org/tx/0x8126246e64885c6a453f2f3b6be80f09f2fd143192a55dc5c8021375d724773f

- Sell after lock  
  https://basescan.org/tx/0x5f0c0432565a6854994f95e29a750775abc7b3403af6902c07aa3709df0f688c

- Tax processing + LP Vault funding  
  https://basescan.org/tx/0x2bea9da9d7184ef4a3645d0e157608313058b2403017efc20ea6cacc6ff56be9

Note: Full reward cycles (snapshot → finalize → claim → cleanup) will complete organically as protocol activity accumulates.

## Documentation
 **Whitepaper:** [whitepaper/WHITEPAPER.md](whitepaper/WHITEPAPER.md)  
 **Architecture:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

JACKs Pools is an autonomous on-chain reward protocol live on Base that turns
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

**In simple terms:**

- Buy → enter a reward round  
- Provide liquidity → compete for LP rewards  
- Sell → funds LP rewards  
- Rewards are distributed automatically on-chain  

No admin. No custody. No intervention.

---

## Mainnet Status

JACKs Pools has completed:

- Full end-to-end on-chain validation on Base Sepolia
- Full lifecycle simulation on Base mainnet fork (16/16 phases)
- Invariant validation (accounting, lifecycle, idempotency, permissionlessness)

All core flows have been executed using real transactions, multiple wallets,
and without privileged access.

The current repository state represents the deployed immutable Base mainnet version.

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

## Testnet Validation (Base Sepolia)

Full validation transactions and lifecycle proofs are available here:

[docs/SEPOLIA_VALIDATION.md](docs/SEPOLIA_VALIDATION.md)

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

Live on Base mainnet. Ownership renounced. Core protocol flows are live on-chain; full reward cycles will complete as activity accumulates.

## Frontend

A full frontend is available:

https://jackspools.lol

The interface supports both Base mainnet and Base Sepolia.

Users can switch between networks directly from their wallet.

Mainnet is live and permissionless.  
Testnet remains available for exploration and validation.

 **Note on testnet configuration**

> The Base Sepolia deployment uses **reduced thresholds and shorter timings**
> compared to the intended mainnet configuration.
>
> This is done strictly to allow faster iteration, multiple full reward cycles,
> and easier on-chain validation under testnet conditions.
>
> Core logic, security assumptions, and lifecycle behavior are identical
> between testnet and the deployed mainnet version.

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

This repository represents the live, immutable Base mainnet deployment of the JACKs Pools protocol.

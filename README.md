# JACKs Pools – Autonomous Reward Distribution Protocol on Base

## Documentation
 **Whitepaper:** [WHITEPAPER.md](./WHITEPAPER.md)

JACKs Pools is an autonomous on-chain reward protocol designed for Base that turns
trading and liquidity activity into recurring reward rounds for participants.
The protocol features **permanent, ever-growing liquidity**, a **buyer reward cycle** with a
4,096-entry circular buffer system, an **LP reward cycle** for top contributors, and a regenerative
economic model where every interaction (buy, sell, LP add) strengthens the protocol.

JACKs Pools is designed as a consumer-facing economic game where trading
and liquidity participation continuously fund protocol reward rounds.

The system is fully non-custodial and non-ruggable:
- Liquidity is permanent and can only increase  
- No owner functions remain after initialization  
- All rewards are claim-based (pull payments)  
- All logic is deterministic, self-contained, and on-chain  

---

## Mainnet Candidate Status

JACKs Pools has completed full end-to-end on-chain validation on Base Sepolia
and is currently considered a mainnet candidate.

All critical flows have been executed on-chain using real transactions,
multiple wallets, and no privileged access.

### Latest Patch

A minor patch was applied to the reward claim path to correctly mark
rounds as claimed within the internal accounting structures.

This change ensures accurate UI/state reflection and does not alter
reward logic, eligibility, or payout mechanics.

The patch has been validated on Base Sepolia.

## Final Design Decisions (Post-Validation)

Following full on-chain validation on Base Sepolia, several final protocol
decisions were made based on real gas usage, user behavior, and griefing analysis:

- Auto tax processing was removed to avoid forcing additional gas costs on users.
  Tax processing is now manual, permissionless, and incentivized with a caller reward.

- True burn was implemented.
  Burned tokens are permanently removed from total supply and are not routed
  to any externally owned or contract address.

- The snapshot reveal delay was increased to +25 blocks to further separate
  snapshot state from randomness revelation.

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
- Deterministic reward logic based on on-chain state

## Integration Simulations (Foundry Scripts)

Instead of classical unit tests, the repo uses full integration simulations running on a Base mainnet fork.

## Validation Artifacts

Fork, invariant, and static analysis outputs are included under `/docs/tests`:
- End-to-end fork simulations
- High-load LP scenarios (400 participants, eviction)
- Invariant testing (accounting, lifecycle, idempotency)
- Slither static analysis report is included under `/docs/tests/SLITHER_REPORT.txt`.
  Some findings are expected for this design (best-effort randomness, timestamp-gated rounds, ETH payouts via pull-payments).
  See `/docs/tests/README.md` for a short explanation.
  
## Base Sepolia Deployments

The protocol has been deployed and fully exercised on Base Sepolia:

- JACKsPools (ERC20): `0xe7De2E9f12e9BE6230f5d836D4525EEB5A2625f2`
- JACKsVault (Buyer Rewards): `0x441e76329ec37d81d99B06342B97368460F31810`
- JACKsLPVault (LP Rewards): `0x7766145e659AD21C28c36E720FAC8E33C6260Be2`
- JACKsLPManager: `0xFa712A34a8415c46c25D5E09046f0a15FFF3acAB`

### Verification
- [LP Buffer Stress Test (Base Sepolia)](docs/verification/LP_BUFFER_STRESS_TEST.md)

## Mini Dapp (Testnet)

A minimal frontend is available for interacting with the protocol on Base Sepolia:

https://jack-spools-website.vercel.app/

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

---

This repository represents the final mainnet candidate state of the JACKs Pools protocol.

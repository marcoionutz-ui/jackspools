# JACK Whitepaper

## Abstract

JACK is an autonomous on‑chain reward protocol built on Base that redistributes value generated from market activity directly back to its participants through transparent, rule‑based smart contracts. The system combines permanent liquidity, dynamic market protections, and two independent reward mechanisms — Buyer Rewards and Liquidity Provider (LP) Rewards — without relying on administrators, oracles, or discretionary control.

JACK is not a promise of yield, profit, or appreciation. It is a deterministic system where outcomes emerge solely from on‑chain activity and immutable rules.

---

## 1. What is JACK?

JACK is a self‑contained protocol composed of multiple smart contracts that together form an automated reward economy.

At its core, JACK is:

* A fixed‑supply ERC‑20 token deployed on Base
* A permanent‑liquidity market with burned LP tokens
* A buyer participation system that periodically redistributes collected value to eligible buyers
* A liquidity provider reward system that distributes rewards proportionally to contributors

All mechanisms operate without post‑deployment control. Once ownership is renounced, JACK continues to function solely according to its encoded logic.

---

## 2. System Architecture Overview

JACK is composed of five primary components:

1. **JACKsPools (Token Core)**

   * Implements ERC‑20 logic
   * Applies buy/sell taxes
   * Enforces protocol-level limits (buy cooldowns, sell locks, and a dynamic max wallet)
   * Routes value to reward vaults and liquidity

2. **Buyer Reward Vault (JACKsVault)**

   * Collects ETH derived from buy‑side taxes
   * Tracks eligible buyers using a rotating buffer system
   * Periodically selects a single recipient per round

3. **LP Reward Vault (JACKsLPVault)**

   * Collects ETH derived from sell‑side taxes
   * Tracks liquidity contributions across rounds
   * Distributes rewards to top contributors proportionally

4. **LP Manager (JACKsLPManager)**

   * Acts as the gateway for adding liquidity
   * Enforces exact‑ratio LP additions
   * Burns LP tokens permanently

5. **Uniswap V2 Pair (Base)**

   * Provides the open market
   * Serves as the sole liquidity venue

### High‑Level Flow

```
Market Activity
   ↓
Token Tax Logic
   ↓
 ┌───────────────┐
 │ Buyer Vault   │  ← Buyer Rewards
 └───────────────┘
 ┌───────────────┐
 │ LP Vault      │  ← LP Rewards
 └───────────────┘
   ↓
Auto Liquidity (LP Burned)
```

Each component is isolated, failure‑tolerant, and interacts only through well‑defined interfaces.

---

*The following sections describe each mechanism in detail, including eligibility rules, distribution logic, and security considerations.*

---

## 3. Token Mechanics & Tokenomics

### Token Overview

* **Name:** JACKs Pools
* **Symbol:** JACK
* **Decimals:** 18
* **Network:** Base (L2)
* **Total Supply:** 1,100,000,000 JACK (fixed)

At deployment:

* **100,000,000 JACK** are allocated to the deployer (builder allocation)
* **1,000,000,000 JACK** are allocated to the protocol for liquidity provisioning

No minting functions exist. Total supply can only decrease via on-chain burns.

---

### Liquidity Model (Permanent by Design)

All liquidity added through the protocol is sent to the burn address. LP tokens are never recoverable.

This enforces:

* Permanent market liquidity
* No rug-pull vectors
* No liquidity governance or custody

The protocol only recognizes **one official Uniswap V2 pair**. Any attempt to interact with unauthorized liquidity pools is reverted at the token level.

---

### Tax Structure

JACK applies deterministic taxes on market activity. All tax parameters are immutable.

#### Buy Tax (10% total)

* **7.75%** → Buyer Reward Vault
* **2.00%** → Liquidity (auto-LP)
* **0.25%** → Burn (permanent supply reduction)

#### Sell Tax (10% total)

* **5.00%** → LP Reward Vault
* **5.00%** → Auto-Liquidity

Taxes are accumulated in-token and converted to ETH only during explicit processing calls.

---

### Tax Processing & Incentives

Tax processing is **not automatic**.

Any address may call `processTaxes()` when sufficient tokens are accumulated. The caller receives **0.3% of the generated ETH** as an incentive.

This design:

* Removes hidden auto-swaps
* Prevents forced gas spikes on buys/sells
* Encourages decentralized maintenance via open incentives

Failed tax processing does not corrupt state. All operations are failure-tolerant and retryable.

---

### Market Protections

JACK includes protocol-level protections enforced at the token layer:

* **Buy cooldown:** Fixed delay between buys per address (**30 seconds**)
* **Sell lock:** Fixed sell restriction applied after each buy (**2 hours**)
* **Dynamic max wallet:** Scales by LP stage and becomes **unlimited once LP ≥ 20 ETH (Stage 5)**
* **Slippage bounds:** Fixed maximum slippage enforced during protocol swaps (**10% max slippage**)

Only the **max wallet** rule changes with liquidity depth. Buy cooldowns, sell locks, and slippage bounds are constant parameters.

---

## 4. Buyer Reward Protocol

The Buyer Reward system redistributes value generated from buy-side activity to eligible market participants through a **best-effort random winner selection** (non-VRF).

### Funding Source

Buyer Rewards are funded exclusively from buy taxes converted to ETH.

No external funding, manual deposits, or admin intervention exist.

---

### Stage-Based Pot Thresholds (Buyer Vault)

The Buyer Vault takes a snapshot when the **available pot** reaches the current stage threshold.

* **Available pot = vault ETH balance − total pending (unclaimed) rewards**

| Liquidity Stage | Total LP Value | Buyer Pot Threshold (ETH) |
| --------------- | -------------- | ------------------------- |
| Stage 1         | < 2 ETH        | 0.014 ETH                 |
| Stage 2         | 2 – 5 ETH      | 0.057 ETH                 |
| Stage 3         | 5 – 10 ETH     | 0.143 ETH                 |
| Stage 4         | 10 – 20 ETH    | 0.286 ETH                 |
| Stage 5         | ≥ 20 ETH       | 0.714 ETH                 |

These values are enforced by `getCurrentThreshold()` in the Buyer Vault.

---

### Eligibility Rules (Buyer Rewards)

A wallet becomes eligible to receive a Buyer Reward ticket **at the time of purchase** only if all conditions below are met:

* Buy amount (ETH value) ≥ **stage-based minimum buy**
* Wallet balance ≥ **stage-based minimum JACK balance**
* Wallet has not already received a ticket in the current round (**1 ticket per wallet per round**)

Important behavior:

* If a buy is below the minimum, the vault **silently skips** the entry (no revert).
* If the wallet does not meet the token-balance requirement, the vault **silently skips** the entry (no revert).

Eligibility thresholds are stage-based and derived from total LP value.

---

### Buffer-Based Participation Model

Eligible buyers are tracked using a rotating buffer system:

* **8 buffers × 512 entries**
* **4,096 total address capacity**
* Circular overwrite with timestamp validation

Each eligible buyer may receive **one ticket per round**.

Entries (tickets) expire after **2 hours** (`ENTRY_EXPIRY`). At finalize time, the vault filters out expired entries and will reset the snapshot if no valid entries remain.

---

### Snapshot & Round Creation

A Buyer Reward round is driven by the vault’s **available pot**:

* **Pot = vault ETH balance − total pending (unclaimed) rewards**

When the pot reaches the current stage threshold and a snapshot is not already taken, the vault automatically:

* Takes a snapshot of the current active buffer
* Freezes that buffer for selection
* Rotates to the next buffer and immediately starts collecting entries for the next round
* Schedules a **reveal block** at **snapshotBlock + 25 blocks** (`REVEAL_DELAY_BLOCKS`)

Safety behavior:

* If a snapshot remains unfinalized for **7 days**, it is reset upon the next eligible buyer entry.
* If the snapshot becomes too old for `blockhash` (older than **256 blocks**), `finalizeRound()` resets the snapshot and exits without distributing.

---

### Randomness Model

The Buyer Reward winner is selected using a **best-effort random** process (non-VRF). The goal is to make the outcome unpredictable without relying on external oracles.

Winner selection uses best-effort, multi-source entropy:

* Past block hashes around snapshot time
* A future block hash at the reveal block (**snapshot + 25 blocks**)
* Current block data (`prevrandao`, timestamp, block number)
* Round data (snapshot round, snapshot timestamp, pot)
* Community entropy mixed from buyer activity (`roundEntropy`)
* Transaction context (caller, gas price)

This model is not VRF-based by design. JACK prioritizes autonomy and censorship resistance over oracle dependency.

---

### Reward Distribution

* `finalizeRound()` is permissionless (any address may call it)
* The vault requires the reveal block to be reached before finalization
* The vault filters out expired snapshot entries and exits safely if none remain
* The winner must still satisfy the **minimum token balance** for the current stage at finalize time (balance is re-checked)
* The round assigns **100% of the available pot** to a single winner (pull-based claim)

---

### Claims & Cleanup (Buyer Vault)

Buyer Rewards use a pull-based claim model:

* When a round is finalized, the winner receives a **claimable allocation** recorded in vault state.
* Claiming is initiated by the winner (or their configured payout address) and transfers the allocated ETH.
* Unclaimed allocations remain counted as **pending rewards** and reduce the vault’s **available pot** until claimed or cleared.

**Claim window:** Unclaimed Buyer Rewards can be cleared after **30 days** (`MAX_CLAIM_DELAY`).

Cleanup behavior:

* Cleanup is permissionless and exists to prevent permanent vault lockup.
* Clearing an expired allocation releases it back into the vault’s **available pot** for future rounds.
* Cleanup does not alter past round history; it only removes expired, unclaimed allocations.

Unclaimed Buyer Rewards can be reclaimed after **30 days** (`MAX_CLAIM_DELAY`) via safety cleanup logic.

---

## 5. LP Reward Protocol

The LP Reward system incentivizes sustained liquidity contribution through competitive, round-based distributions.

### Funding Source

LP Rewards are funded exclusively from sell-side taxes converted to ETH and sent to the LP vault.

---

### Lifetime Eligibility (One-Time Unlock)

A wallet becomes LP-eligible only after its **lifetime** LP contributions reach the stage-based minimum (`getMinLpRequired()`).

* Lifetime contributions are tracked permanently (`lifetimeContributions`).
* Once the threshold is reached, eligibility is **permanent**.

---

### Per-Round Participation (Competitive)

Even if lifetime-eligible, a wallet must add LP during the active round to compete.

The vault maintains an active participant buffer with a hard cap:

* **MAX_PARTICIPANTS = 400** per round
* If full, a new contributor may **evict the lowest contributor** only if their contribution is higher

The LP vault uses **two alternating buffers** (0/1). When a snapshot is taken, the vault switches to the other buffer and immediately starts tracking the next round.

---

### Snapshot & Finalization

LP rounds are driven by the vault’s **available pot**:

* **Available pot = vault ETH balance − total pending (unclaimed) rewards**

When the available pot reaches the stage threshold (`getPotThreshold()`) and the active buffer contains participants, the vault takes a snapshot.

Finalization rules:

* Participants can finalize immediately.
* Any address may finalize after **7 days** (anti-griefing / post-renounce safety).

---

### Reward Distribution Model

At finalization, the vault selects the **top contributors** in the snapshot buffer and assigns rewards:

* **60%** of the pot → ranks **1–10** (proportional)
* **40%** of the pot → ranks **11–60** (proportional)

Rewards are stored per round and claimed via pull-based withdrawals.

---

### Claims & Cleanup (LP Vault)

LP Rewards are also pull-based:

* At finalization, each eligible address receives a per-round reward allocation recorded in vault state.
* Each address claims independently, transferring its allocated ETH.
* Unclaimed LP allocations remain counted as **pending rewards** and reduce the vault’s **available pot** until claimed or cleared.

**Claim window:** Unclaimed LP Rewards can be cleared after **30 days** (`CLAIM_DEADLINE`).

Cleanup behavior:

* Cleanup is permissionless and exists to prevent stale rounds from permanently reducing the available pot.
* Clearing expired allocations releases them back into the vault’s **available pot** for future rounds.

Unclaimed rewards expire after **30 days** (`CLAIM_DEADLINE`) and can be cleared safely.

---

### Stage-Based Pot Thresholds (LP Vault)

The LP Vault takes a snapshot when the **available pot** reaches the current stage threshold.

* **Available pot = vault ETH balance − total pending (unclaimed) rewards**

| Liquidity Stage | Total LP Value | LP Pot Threshold (ETH) |
| --------------- | -------------- | ---------------------- |
| Stage 1         | < 2 ETH        | 0.086 ETH              |
| Stage 2         | 2 – 5 ETH      | 0.257 ETH              |
| Stage 3         | 5 – 10 ETH     | 0.514 ETH              |
| Stage 4         | 10 – 20 ETH    | 1.03 ETH               |
| Stage 5         | ≥ 20 ETH       | 1.71 ETH               |

These values are enforced by `getPotThreshold()` in the LP Vault.

---

## 6. Trading Cooldowns & Lock Mechanics

JACK enforces explicit, protocol-level cooldowns and locks to prevent spam, short-term extraction, and manipulation during low-liquidity phases.

These rules are **always on**, deterministic, and enforced at the token level.

---

### Buy Cooldown

After a successful buy, a wallet must wait before buying again.

| Rule         | Value                           | Notes                |
| ------------ | ------------------------------- | -------------------- |
| Buy Cooldown | **30 seconds**                  | Enforced per wallet  |
| Applies To   | Buys only                       | Transfers unaffected |
| Purpose      | Prevents buy-spam & bot looping |                      |

A wallet attempting to buy again before the cooldown expires will revert.

---

### Sell Lock (Post-Buy)

Each buy applies a **sell lock** to the buyer’s wallet.

| Rule               | Value                                    | Notes                           |
| ------------------ | ---------------------------------------- | ------------------------------- |
| Sell Lock Duration | **2 hours**                              | Resets on every new buy         |
| Applies To         | Sells only                               | Liquidity additions are allowed |
| Purpose            | Prevents immediate buy → sell extraction |                                 |

During the sell lock:

* Selling JACK to the liquidity pool is blocked
* Transfers propagate the remaining lock duration
* **Adding liquidity via the LP Manager is allowed**

Once the lock expires, selling is unrestricted.

---

### Summary Timeline (Buyer Perspective)

```
Buy JACK
  ↓
30s cooldown before next buy
  ↓
2h sell lock active
  ↓
Sell enabled
```

---

## 7. Dynamic Stages & Scaling Logic

JACK adapts a defined subset of parameters dynamically based on total liquidity depth. This ensures a fair launch environment while progressively relaxing restrictions as the market matures.

### Stage Determination

Stages are derived exclusively from total LP value (ETH):

* **Stage 1:** LP < 2 ETH
* **Stage 2:** LP 2–5 ETH
* **Stage 3:** LP 5–10 ETH
* **Stage 4:** LP 10–20 ETH
* **Stage 5:** LP ≥ 20 ETH

No manual configuration or governance input exists.

---

### Parameters Affected by Stages

Depending on the current stage, the following parameters scale automatically:

* Minimum buy size
* Buyer reward eligibility thresholds
* LP reward eligibility thresholds
* Maximum wallet limits
* Reward pool thresholds

At Stage 5, maximum wallet limits are fully disabled.

---

## 8. Liquidity & Market Design

### Permanent Liquidity

All liquidity added via the protocol is sent to the burn address. LP tokens are unrecoverable.

This guarantees:

* Continuous market availability
* No liquidity withdrawal vectors
* Equal footing for all participants

---

### Single-Pool Enforcement

JACK recognizes only one official Uniswap V2 liquidity pool.

Any interaction with unauthorized pools is reverted at the token level. This prevents fragmented liquidity, price manipulation via shadow pools, and liquidity siphoning.

---

## 9. Security Model & Failure Modes

JACK prioritizes safety through architectural constraints rather than governance controls.

### Key Security Properties

* No upgradeability or proxy patterns
* No post-deployment parameter changes
* Ownership renouncement enforced
* Reentrancy protection on all sensitive functions
* Pull-based reward claiming
* Strict separation between accounting and transfers

---

### Failure-Tolerant Design

All external calls are isolated using `try/catch` patterns where appropriate.

In case of:

* Swap failures
* Liquidity provisioning issues
* Reward routing errors

The protocol preserves internal accounting state and allows retries without manual intervention.

---

### Edge Cases & Deterministic Behaviors

This section documents non-obvious behaviors that are enforced by the contracts and are important for integrators and users.

#### Token Core (JACKsPools)

* **Unauthorized pools are rejected:** the token enforces a single official Uniswap V2 pair. Transfers involving unauthorized pairs are reverted.
* **Buy cooldown enforcement:** a second buy from the same wallet before **30 seconds** will revert.
* **Sell lock enforcement:** selling to the official pair before the **2-hour** lock expires will revert.
* **Sell lock propagation:** transferring tokens propagates the remaining sell-lock duration.
* **Adding LP during sell lock:** the sell lock blocks selling but **does not prevent adding liquidity via the LP Manager**.

#### Buyer Vault (JACKsVault)

* **Silent skip on non-eligible buys:** if a buy does not meet minimum buy size or minimum token balance conditions, the vault does not revert; it simply does not record a ticket.
* **Ticket expiry:** buyer entries expire after **2 hours** (`ENTRY_EXPIRY`) and are filtered out at finalization.
* **Snapshot stall reset (7 days):** if a snapshot remains unfinalized for **7 days**, it is reset on the next eligible buyer entry.
* **Blockhash expiry (256 blocks):** if a snapshot becomes older than the `blockhash` window, `finalizeRound()` resets the snapshot and exits without distributing.
* **Winner balance re-check:** at finalization, the winner must still satisfy the current-stage minimum token balance.
* **Finalize cooldown:** consecutive buyer finalizations are rate-limited by a **3-minute** cooldown (`FINALIZE_COOLDOWN`).

#### LP Vault (JACKsLPVault)

* **Snapshot requires participants:** LP snapshots only occur when there are active round participants.
* **Buffer cap and eviction:** the participant set is capped at **400** (`MAX_PARTICIPANTS`). If full, a new contributor only enters by evicting the lowest contributor with a higher contribution.
* **Two-buffer rotation:** the vault alternates between two buffers; snapshotting one buffer switches tracking immediately to the other.
* **Anti-grief finalization:** participants can finalize immediately; after **7 days**, any address can finalize to prevent stuck rounds.

#### Tax Processing

* **Permissionless processing:** any address may call `processTaxes()` when thresholds are met.
* **Failure isolation:** if tax processing fails (e.g., swap/liquidity step fails), the call reverts and state is not corrupted; processing remains retryable.
* **Caller incentive:** successful processing pays **0.3%** of generated ETH to the caller.

---

## 10. What JACK Is / Is Not

### JACK Is

* An autonomous on-chain reward protocol
* A permanent-liquidity market
* A rule-based redistribution system
* A permissionless experiment in incentive design

### JACK Is Not

* A promise of profit or yield
* A managed investment product
* An admin-controlled system
* A governance token
* A guaranteed rewards mechanism

Participation is voluntary and outcomes are emergent.

---

## 11. Developer’s Note

JACK was built without venture backing, privileged allocations, or hidden controls.

Every mechanism exists to remove trust assumptions and replace them with transparent, deterministic rules.

The builder allocation represents proof of work — the result of sustained development, testing, and iteration — not a premine or preferential extraction.

---

## 12. Eligibility Summary Tables

The following tables summarize the eligibility conditions for both reward mechanisms. They are provided for clarity and do not replace the full protocol logic described above.

---

### Buyer Reward Eligibility (Per Round)

The Buyer Reward mechanism is **strictly rules-based**. Eligibility is evaluated **at the time of each buy** and depends on the current liquidity stage.

Below are the **explicit on-chain thresholds** used by the protocol.

#### Stage-Based Eligibility Thresholds

| Liquidity Stage | Total LP Value | Minimum Buy (ETH) | Minimum JACK Balance |
| --------------- | -------------- | ----------------- | -------------------- |
| Stage 1         | < 2 ETH        | 0.00043 ETH       | 500,000 JACK         |
| Stage 2         | 2 – 5 ETH      | 0.00057 ETH       | 250,000 JACK         |
| Stage 3         | 5 – 10 ETH     | 0.00071 ETH       | 100,000 JACK         |
| Stage 4         | 10 – 20 ETH    | 0.00086 ETH       | 50,000 JACK          |
| Stage 5         | ≥ 20 ETH       | 0.001 ETH         | 1 JACK               |

**All conditions below must be met:**

* Buy amount ≥ minimum buy for the current stage
* Wallet balance ≥ minimum JACK balance for the current stage
* Wallet has not already received a ticket in the current round

Each eligible wallet can receive **one ticket per round**, regardless of buy size beyond the minimum.

---

### LP Reward Eligibility

#### Lifetime Eligibility (One-Time Unlock)

To ever participate in LP Reward rounds, a wallet must reach a **minimum lifetime ETH contribution to liquidity**, based on the current stage.

#### Stage-Based Lifetime LP Requirements

| Liquidity Stage | Total LP Value | Minimum Lifetime LP (ETH) |
| --------------- | -------------- | ------------------------- |
| Stage 1         | < 2 ETH        | 0.0086 ETH                |
| Stage 2         | 2 – 5 ETH      | 0.01 ETH                  |
| Stage 3         | 5 – 10 ETH     | 0.011 ETH                 |
| Stage 4         | 10 – 20 ETH    | 0.013 ETH                 |
| Stage 5         | ≥ 20 ETH       | 0.014 ETH                 |

Once this threshold is reached:

* Eligibility is **permanent**
* The wallet can never lose eligibility

#### Per-Round Participation

| Condition          | Requirement         | Notes                               |
| ------------------ | ------------------- | ----------------------------------- |
| Active LP Addition | Required each round | Historical LP alone is insufficient |
| Buffer Capacity    | Limited             | Competitive entry                   |
| Eviction Logic     | Enabled             | Lowest contributor may be replaced  |
| Reward Scope       | Top 60 LPs          | Split 60% / 40%                     |

---

## 13. Example User Journeys

The following scenarios illustrate how the protocol behaves in practice. All values reflect on-chain rules.

---

### Scenario 1: Buyer Participation (Early Stage)

**Context:**

* Liquidity Stage: **Stage 1** (LP ≈ 1 ETH)
* Minimum Buy: **0.00043 ETH**
* Minimum Balance: **500,000 JACK**

**Action:**
Alice buys **0.001 ETH** worth of JACK.

**Outcome:**

* The buy meets the minimum threshold
* Alice holds more than the required JACK balance
* Alice receives **one Buyer Reward ticket** for the current round
* Alice must wait **30 seconds** before buying again
* Alice cannot sell for **2 hours**
* **Note:** During the sell lock, Alice may still add liquidity via the **LP Manager**, as adding LP does not involve selling tokens

If the Buyer Reward pot reaches the current threshold, the protocol takes a snapshot and freezes the current buyer buffer for that round. Alice will be included in the selection **only if her ticket is still valid at snapshot time** (i.e., not expired and not overwritten by buffer rotation).

---

### Scenario 2: Buyer Attempts Multiple Buys

**Context:** Same round, same stage.

Bob performs two buys:

1. First buy: **0.001 ETH** → eligible → ticket granted
2. Second buy (same round): **0.002 ETH** →  no additional ticket

**Result:**

* Only **one ticket per wallet per round** is allowed
* Additional buys do not increase winning probability

---

### Scenario 3: Liquidity Provider (LP Rewards)

**Context:**

* Liquidity Stage: **Stage 3** (LP ≈ 7 ETH)
* Lifetime LP threshold: **0.011 ETH**

**Action:**
Bob adds **0.015 ETH** worth of liquidity through the LP Manager.

**Outcome:**

* Lifetime eligibility unlocked (permanent)
* Bob may now compete in LP Reward rounds
* Bob must add LP **each round** to participate

If Bob remains among the top contributors when the snapshot occurs, he receives a proportional reward.

---

## 14. Getting Started

### Step 1: Prepare Your Wallet

* Install a Base-compatible wallet (e.g., MetaMask)
* Switch to the Base network
* Fund your wallet with ETH for gas and participation

### Step 2: Buy JACK (Buyer Rewards)

* Visit the official dApp
* Connect your wallet
* Check the current stage and minimum buy
* Buy JACK using ETH

If your buy meets the current thresholds, you are automatically entered into the Buyer Reward round.

### Step 3 (Optional): Add Liquidity (LP Rewards)

* Use the LP section of the dApp (LP Manager)
* Approve tokens if prompted
* Add LP using the auto-calculated ratio

**Note:** The 2-hour sell lock blocks selling, but **adding liquidity via the LP Manager is allowed**.

To unlock permanent eligibility for LP Rewards, you must reach the lifetime LP threshold for the current stage.

---

## 15. Frequently Asked Questions (FAQ)

**Q: How do I know if I am eligible right now?**
A: The dApp displays your current stage, thresholds, buyer ticket status, and LP eligibility.

**Q: What if nobody finalizes a round?**
A: Rounds do not distribute automatically. Any address may call the finalize function when conditions are met.

* **Buyer Rewards:** `finalizeRound()` is permissionless and can be called by anyone once a snapshot exists and the pot meets the threshold (**3-minute finalize cooldown**).
* **LP Rewards:** participants may finalize immediately; after a timeout, anyone can finalize to prevent deadlock.

**Q: Can I lose my LP eligibility?**
A: No. Once unlocked, lifetime eligibility is permanent.

**Q: How long do I have to claim rewards?**
A: Rewards must be claimed within **30 days**.

**Q: What if my wallet is a smart contract?**
A: You may set a custom payout address using `setPayoutAddress()`.

---

## 16. Specific Risks

Participation in JACK involves explicit risks:

* **Smart Contract Risk:** The system may be unaudited; bugs could cause loss of funds or lockups.
* **Market Risk:** Token price can fall to zero; liquidity may be permanent, but volume is not guaranteed.
* **MEV Risk:** Transactions may be front-run or sandwiched; permissionless functions may be contested.
* **Reward Risk:** Eligibility does not guarantee rewards; rewards depend on activity and round state.
* **Randomness Risk:** Buyer selection uses best-effort entropy and is not VRF-grade.
* **Regulatory Risk:** Legal status varies by jurisdiction; users are responsible for compliance.

---

## 17. Disclaimer

JACK is experimental software provided "as is".

Participation involves risk. Users are responsible for understanding the protocol, reviewing the smart contracts, and complying with applicable laws and regulations.

Nothing in this document constitutes financial advice, investment solicitation, or a guarantee of outcomes.

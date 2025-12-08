# Architecture Overview

## Buyer Reward Cycle
- Users enter reward cycle by meeting stage-based buy requirements.
- 4,096-entry circular buffer across 8 segments.
- Snapshot block → reveal block separation.
- Finalization produces exactly one reward recipient.
- Rewards are pull-claimed.

## LP Reward Cycle
- Lifetime LP tracking.
- Up to 400 participants per cycle.
- When full: lowest LP contributor can be evicted.
- Top 100 LP addresses receive proportional ETH distributions.
- All rewards are claimed via pull-payments.

## System Properties
- Liquidity is permanent and only increases.
- No admin functions after initialization.
- All state transitions are deterministic and onchain.

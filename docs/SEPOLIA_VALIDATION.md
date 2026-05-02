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
  
  
  This document contains full validation traces for the protocol before mainnet deployment.
# Notes on Slither Findings (Non-Audit)

Slither flags several patterns as "high" or "critical" by default.
In the context of JACKs Pools, these findings represent intentional design
trade-offs rather than security vulnerabilities.

## Expected Findings

- **Weak randomness / PRNG**
  Buyer reward selection uses best-effort onchain entropy combined with
  snapshot + delayed reveal. This is not Chainlink VRF-grade randomness by design
  and is documented as such.

- **Timestamp / block dependence**
  Reward rounds, cooldowns, reveal windows, and claim deadlines are explicitly
  time-gated and enforced onchain as part of the protocol lifecycle.

- **ETH transfers**
  Rewards are distributed exclusively via pull-payments (users explicitly claim).
  Slither flags ETH transfers generically, even when not performed in loops or
  under admin control.

## Post-Validation Design Decisions

Following full on-chain validation on Base Sepolia, several changes were made
that are not security issues but affect static analysis output:

- **Auto tax processing was removed**
  Tax processing is now manual, permissionless, and incentivized to avoid
  forcing additional gas costs on users and to reduce revert risk on edge paths.

- **True burn semantics**
  Burned tokens are permanently removed from total supply using internal burn
  logic. Tokens are not transferred to a dead address or external sink.

- **Extended snapshot reveal delay**
  The snapshot reveal delay was increased (+25 blocks) to further separate
  snapshot state from randomness revelation.

- **Anti-griefing hardening**
  Reward distribution paths are hardened to safely handle contract wallets
  without a payable `receive()` function. Failed ETH transfers cannot block
  rounds, claims, or reward finalization.

## Summary

None of the reported findings indicate:
- admin backdoors
- custody risk
- privileged control over funds
- ability to block or steal rewards

The protocol is fully permissionless after initialization and relies on
deterministic onchain state transitions.

Full static analysis report: `SlitherReport.txt`.

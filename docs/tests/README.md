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

- **Reentrancy in emergencyClaim**
  The 2-pass implementation is intentional design: transfer executes before
  state updates to prevent fund locks on failed transfers. Protected by
  `require(claimable >= expiredAmount)` guard and the `nonReentrant` modifier
  is not applicable here by design.

## Summary

None of the reported findings indicate:
- admin backdoors
- custody risk
- privileged control over funds
- ability to block or steal rewards

The protocol is fully permissionless after initialization and relies on
deterministic onchain state transitions.

Full static analysis report: `SLITHER_REPORT.txt`.

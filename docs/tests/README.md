# Notes on Slither Findings (Non-Audit)

Slither flags some patterns as "high/critical" by default. In this protocol these are expected trade-offs:

- **Weak randomness / PRNG**: Buyer selection uses best-effort onchain entropy and delayed reveal. It is not Chainlink VRF-grade randomness by design.
- **Timestamp dependence**: Rounds, cooldowns, and claim windows are time-based and enforced onchain. This is intentional lifecycle control.
- **ETH transfers**: Rewards are distributed via **pull-payments** (users claim), which is safer than pushing ETH in loops. Slither still flags ETH transfers as "risky" generically.

These findings do not indicate admin backdoors or custody risk. Full report: `SlitherReport.txt`.

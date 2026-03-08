# LP Buffer Stress Test – Base Sepolia

This document contains on-chain proofs from stress testing the LP rewards buffer
at full capacity on Base Sepolia.

The goal was to validate:
- full buffer behavior
- non-evicting inserts
- eviction logic
- ranking updates under load

---

## Test Parameters

- Network: Base Sepolia
- LP Buffer Capacity: MAX (400 contributors)
- Entry Method: addLiquidityAndRegister
- Test Type: real EOAs, real LP, real router interactions

---

## Proofs

### 1. Buffer Full – Small Contribution (No Eviction)

**Transaction:**  
https://sepolia.basescan.org/tx/0xfd8b5e4630f4f9847dd04ef195e3ef3e3c358cf13bbf082cdf236c97d70ce1dd

**Observed behavior:**
- LP buffer already full
- Contribution below lowest buffer entry
- Contributor is tracked but does NOT replace anyone in the buffer

✔ Expected behavior confirmed.

---

### 2. Buffer Eviction – Larger Contribution

**Transaction:**  
https://sepolia.basescan.org/tx/0xd020e4f4547a9d51e0f3d20c748ad38582479d7efeb230f43c6bf29feeab9376

**Observed behavior:**
- New LP contribution exceeds lowest buffer entry
- Lowest contributor is evicted
- `LPContributorEvicted` event emitted

✔ Eviction logic confirmed on-chain.

---

### 3. New Top Contributor (Rank #1)

**Transaction:**  
https://sepolia.basescan.org/tx/0x7f33e507f04cf659430bdc3aacd77df50ad487296694e5685686ed08fa548595

**Observed behavior:**
- Contribution exceeds all existing buffer entries
- New contributor moves to top position
- Ranking order updates correctly

✔ Ranking logic confirmed.

---

## Summary

The LP buffer behaves as designed under full capacity:

- No unintended evictions
- Deterministic replacement rules
- Stable ordering and ranking
- Explicit eviction events emitted on-chain

This confirms that the LP reward system behaves deterministically even
when the contributor buffer reaches maximum capacity.

These tests were performed using real EOAs and real liquidity interactions.

# Static Analysis — Slither Triage

Per the handoff's audit gate ("Slither / Mythril static analysis clean, or every finding
explicitly triaged in writing").

| | |
|---|---|
| Tool | Slither (slither-analyzer via pip, 74 detectors) |
| Date | 2026-07-26 |
| Scope | `src/` (GFTW, GFTWVesting, MigrationRegistry, MigrationClaim, GFTWStaking) — lib/test/script filtered |
| Command | `slither . --filter-paths "lib/\|test/\|script/" --exclude-informational --exclude-optimization` |
| Result | **0 critical, 0 high, 0 medium. 11 low** — all one detector class, triaged below. |

## Finding: `block-timestamp` (Low severity / Medium confidence) × 11

**What Slither flags:** comparisons involving `block.timestamp` in
`GFTWStaking.cumulativeEmitted/_update/sweepUndistributed/earned/currentRatePerSecond`,
`MigrationClaim.constructor/claim/sweepUnclaimed`, and
`MigrationRegistry.constructor/_register`.

**Triage: ACCEPTED — not a vulnerability in this design.**

The concern behind this detector is validator manipulation of block timestamps. On BSC,
a validator can skew a block's timestamp by at most a few seconds. Every timestamp
comparison in these contracts gates windows or schedules measured in **days to months**:

- registration window and claim window: weeks-long, inclusive boundaries;
- vesting cliff/duration: 12–36 months (OpenZeppelin `VestingWallet` semantics);
- staking emission phases: 360-day years; the piecewise integration means a skewed
  timestamp can shift at most a few seconds' worth of emission (~3 GFTW/s in year 1)
  between two accrual snapshots — value that still only flows to stakers pro rata.

Worst-case impact of maximal skew: a claim/registration lands a few seconds before or
after a boundary, or reward accrual shifts by a few seconds of emission. No path exists
by which timestamp skew mints supply, redirects funds, bypasses a Merkle proof, or
escapes the fixed windows by more than the skew itself. The remaining `> 0` comparisons
flagged in the same functions are ordinary guard clauses with no timestamp dependence.

**Forge lint (supplementary):** `forge build` reports the same `block.timestamp` class
plus `erc20-unchecked-transfer` hits located **only in test files** (asserting on our own
GFTW token, which reverts on failure); production code uses `SafeERC20` throughout.

## Re-run instructions

```bash
python3 -m pip install --user slither-analyzer
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
slither . --filter-paths "lib/|test/|script/" --exclude-informational --exclude-optimization
```

Mythril was not run (symbolic execution adds little over this codebase's size and the
fuzz suite); the independent audit (gate step 5) supersedes it either way.

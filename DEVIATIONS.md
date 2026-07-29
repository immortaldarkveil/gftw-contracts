# Deviations & follow-ups vs. SMART_CONTRACT_HANDOFF.md

Required by handoff §7.8 ("written summary of any deviation from this document and why").
Decisions referenced were given by the project owner on 2026-07-25.

## 1. Whitepaper changes now required (consequence of decisions, not engineering drift)

Choosing **§4.1 Option C** (fee is platform-level only) and **dropping the §4.2 launch lock**
means the published whitepaper is now wrong in three places and must be revised *before* TGE:

- **§7.3** — claims the anti-dump fee "can't be bypassed" because GFTW "is not externally
  transferable until listing." Neither is true anymore: there is no token-level lock and the
  fee only applies to in-platform sales. Language must be honestly scoped.
- **§9.5** — fee split (~50% LP / ~50% stakers) still exists but only over platform-collected
  fees, which will be a smaller pool than a token-level fee would collect.
- **§9.6** — "after Year 3 staking rewards continue solely from anti-dump fees" now depends
  on platform fee revenue, not protocol-guaranteed flow. The post-Year-3 staking story needs
  rewriting (the handoff itself flagged this dependency).

The handoff's own rule applies: *"Anything you build must match it, or the whitepaper has to
change first."* The contracts as built are the honest version; the whitepaper owes the edit.

## 2. Deliberate engineering choices within the handoff's latitude

- **Vesting uses OZ `VestingWallet` semantics**: linear from TGE with the cliff gating
  release. At a 12-month cliff on a 36-month duration, 12/36 unlocks at the cliff, then
  linear to month 36. This matches "12-month cliff → linear over 24 months" under the
  standard reading (cliff amount unlocks at cliff) and satisfies the published "team not
  fully unlocked until month 36." If the intended reading was "zero at cliff, then linear
  from zero over 24 months," say so — it's a two-line parameter change (start = TGE+12mo,
  duration = 24mo, cliff = 0), decide before funding the wallets.
- **Vesting wallets are non-revocable.** If a team member leaves, their tokens still vest.
  This is the maximally trust-signaling choice; a revocable variant would require an admin
  role. Flagging explicitly because it's an HR/legal tradeoff, not just engineering.
- **A "month" is 30 days** in deploy scripts (36 months = 1080 days). Calendar months are
  not EVM-native; 30-day months is the convention. The published schedule reads the same.
- **`MigrationClaim.claim()` is callable by anyone** (tokens only ever go to the snapshot
  address). This enables the platform to relay claims for users without holding any
  privilege. Standard airdrop pattern (Uniswap MerkleDistributor).
- **Claim window is inclusive** of both endpoints; sweep is possible from `claimEnd + 1`.
- **Dust entries** (< 5 GFT-wei, i.e. amounts that floor to zero GFTW) are dropped from the
  tree by the generator rather than creating unclaimable zero leaves.
- **Non-GFTW tokens accidentally sent to `MigrationClaim` are unrecoverable.** A rescue
  function would need an owner; minimalism won. Documented tradeoff.

## 3. Staking (P1) — built, with design notes

`GFTWStaking.sol` implements the §9.6 curve with the same zero-trust posture as P0:
schedule hardcoded, no owner, principal never locked, rewards pre-funded (180M).
Choices worth reviewing:

- **Post-Year-3 rewards are NOT implemented.** §9.6 says they continue "solely from the
  staker share of anti-dump fees" — under decision §4.1-C that revenue is platform-side,
  so any such top-up would be an off-chain payout or a future, separate contract. The
  on-chain curve simply ends at month 36 (this is also what "temporary by design" implies).
- **Zero-staker emissions are undistributable by design.** If emissions elapse while no
  one is staked, that tranche can never be earned; after the curve ends, anyone can sweep
  it to the immutable treasury. No private party can ever receive it.
- **A schedule "year" is 360 days** (12 × 30-day months), consistent with vesting.
- **Same-token staking**: principal and reward are both GFTW; accounting strictly
  segregates `totalStaked` from reward balances, and the sweep math errs on the side of
  leaving dust in the contract rather than ever touching user funds.

## 3a. Migration is registration-gated (owner decision, 2026-07-26)

Per the project owner: GFTW is **not** distributed to raw snapshot addresses. Snapshot
holders must actively designate a receipt wallet during a registration window, proving
control of the holding wallet (`MigrationRegistry`: direct call or relayed EIP-712
signature, ERC-1271 supported). The claim tree is built over receipt wallets;
unregistered holders' value ends with the treasury. Reviewed manual additions handle
custody edge cases (e.g. exchange-held balances) and are published for audit.

Whitepaper impact (adds to §1 list): §7.2 currently describes claiming as available to
snapshotted holders with no registration precondition — the registration window, its
deadline, and the unregistered-value policy must be added before migration launch.

## 3b. Scope not built

- **Creator Reserve distribution (P2)** — deferred per handoff; "adoption-gated" has no
  spec yet.
- **Governance** — "light governance" still has no concrete definition (handoff §4.4).
  Nothing built here requires it: with Option C the fee split lives entirely off-chain /
  in-platform, so no on-chain governance surface was created.

## 3c. Audit sequencing (owner decision, 2026-07-26)

The owner has decided deployment proceeds **before** the external audit, with the audit
following post-deployment and the whitepaper edited accordingly. This deviates from the
original handoff's gate ordering (§8 steps 5–8 before mainnet). Agreed mitigations:
pools stay unfunded and registration/claim windows stay unopened until the audit's
critical/high findings are cleared; the deployed commit is tagged and the auditor
verifies on-chain bytecode against it.

The reasoning is worth stating plainly, since it is a deviation: these contracts are
immutable and ownerless, so there is no patch path — if the audit finds a problem
requiring a code change, the remedy is to redeploy, not to fix in place. Deploying first
is therefore only safe because deployment alone is made harmless: an unfunded contract
with no open windows holds nothing and can do nothing. **Funding is the real point of no
return, and it does not happen until the audit clears.** The benefit is that the auditor
reviews the exact bytecode that is live rather than a candidate version.

## 4. Open items blocking testnet/mainnet (not blocking code review)

1. **Snapshot dataset** — the project does **not** hold the snapshot the whitepaper §7.2
   claims was "already taken" (handoff §11 Q7). Two workarounds, both viable:
   - **Defer migration:** MigrationClaim takes its Merkle root at its own deployment, so
     TGE can proceed without it; the 130M pool stays on the multisig until resolved.
   - **Rebuild from chain — DONE (2026-07-26):** `snapshot/rebuild.mjs` replayed all
     103,225 GFT Transfer events (BSC GFT `0x72fF5742319eF07061836F5C924aC6D72c919080`,
     creation block 24,170,133 → cutoff block **44,384,350**, the block before the first
     Nov 27 2024 mint tx `0xf2aa17d4…28ed74`; 8 mint events, 1.2B GFT total). Result in
     `snapshot/out/`: **4,908 holders, 1,039,997,051 GFT**, supply integrity check passed
     exactly (minted 1.04B − burned 2,948 = sum of balances).
     **⚠️ Key finding at the v1.2 ratio (5:1, 130M pool): exclusions are mandatory and
     headroom is thin.** Full inclusion is 1.04B GFT ÷ 5 = **208M GFTW**, far beyond the
     130M allocation. Excluding the two prior-operator wallets (408M GFT, 39% of supply —
     including the address that received the initial deployment mint) brings eligible
     supply to 632.0M GFT = **126.4M GFTW, which fits 130M with only ~3.6M (2.8%)
     headroom in the theoretical worst case** (every eligible holder registers). Verified
     by building the real tree: root `0xa83eb6bc…3bb797`, 4,806 entries, 126,407,250 GFTW.

     In practice the constraint is looser, and usefully self-balancing: **~419M GFT (≈84M
     GFTW) sits on apparent exchange hot wallets** (likely Binance/MEXC/Gate) which cannot
     call `register()` — custodians will not. That capacity frees up for **manual
     additions crediting the individual users whose GFT sat on those exchanges**, which is
     exactly the intended mechanism. Net: registered self-custody claims ≈42.6M GFTW,
     leaving ≈87M of pool for reviewed exchange-user additions.

     Two hard consequences remain: reversing an operator exclusion overflows the pool
     outright, and (registered claims + manual additions) must still clear the 130M cap —
     the generator enforces it and refuses to build an over-budget tree, so an
     over-generous manual-additions round fails loudly rather than silently.
     Decisions the project lead owes before the tree is generated:
       a. confirm the cutoff block (block before first mint vs. an earlier date);
       b. the custodial-exclusion list — balances on exchange/bridge/LP addresses are
          custodial and would send users' GFTW to the custodian; `report.json` flags
          top holders that are contracts, but exchange hot wallets are EOAs and need
          manual review;
       c. scope: the rebuilt snapshot covers **BSC GFT only**. Holders of the old
          Ethereum GTO (5 decimals) who never migrated to BSC GFT are not in it —
          confirm whether "legacy holders" means BSC GFT only;
       d. whitepaper §7.2's "snapshot already taken" language needs reconciling either
          way — a chain-rebuilt snapshot is *more* verifiable (anyone can reproduce it
          from public logs), which strengthens §7.4, but the claim as published is not
          currently true.
2. **Legal entity** (GIFT FOUNDATION vs Giftworld Digital LLC) — blocks key generation and
   multisig setup (handoff §11 Q8).
3. **Multisig threshold/signers** — must be published per whitepaper §13 before launch.
4. **Audit firm + budget** — long lead time, on the critical path (handoff §8).
5. **TGE timestamp and claim window dates** — needed as deploy-time parameters.

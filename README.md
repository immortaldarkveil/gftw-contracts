# GFTW Contracts

Smart contracts for **Giftworld (GFTW)** — the GiftoV3 relaunch token on BNB Smart Chain.
Canonical spec is the published whitepaper at <https://giftov3.com/wallet/whitepaper/>.

> ## ⚠️ Status: in testing — nothing is deployed
>
> **No contract in this repository has been deployed to BNB Smart Chain, mainnet or testnet.**
> There is no GFTW token address yet, no migration is open, and there is nothing to claim,
> buy, or stake. Any address, airdrop, sale, or claim link presenting itself as GFTW today
> is a scam.
>
> | | |
> |---|---|
> | Deployed | **No** — testnet run pending, then mainnet |
> | Audited | **No** — independent audit is scheduled (whitepaper §11) |
> | Addresses | Published here and in whitepaper §15 **only after** deployment + BscScan verification |
> | Parameters | Windows and dates are not final; they are set at deployment |
>
> This code is published early and deliberately, so that the community and reviewers can
> read it *before* it goes live rather than after. It is a work in progress and will change.
> Findings are welcome — open an issue.

## Design principle

This token is deployed to a community that watched the previous operators mint 1.2B GFT into a
delisting. Every contract here is therefore **ownerless, immutable, and minimal**:

| Contract | Privileged roles | Upgradeable | Notes |
|---|---|---|---|
| `GFTW.sol` | **None** | No | 1B fixed supply minted once in the constructor. No mint, no burn, no pause, no blacklist, no fees, no owner. ~15 lines over OpenZeppelin ERC20. |
| `GFTWVesting.sol` | None (beneficiary only receives) | No | Cliff + linear, non-revocable. Thin concrete wrapper over OZ `VestingWalletCliff`. One instance per beneficiary. |
| `MigrationRegistry.sol` | **None** | No | Snapshot holders designate their GFTW **receipt wallet** during a fixed window, by calling `register()` from the holding wallet or via a relayed EIP-712 signature (gasless for the holder; ERC-1271 supported). No admin can add, edit, or censor an entry. Only registered holders enter the claim tree. |
| `MigrationClaim.sol` | **None** | No | Merkle claim, 5 GFT → 1 GFTW. Root, window, and treasury fixed at deployment. Leaves are (receipt wallet, amount) from the registration join. Anyone can trigger claims (to the leaf address only) and the post-window sweep (to the immutable treasury only). |
| `GFTWStaking.sol` | **None** | No | Stake GFTW, earn from the pre-funded 180M community bucket. The §9.6 decay curve (7.5M/4.5M/3.0M per month) is **hardcoded** — no one can change rates, pause, or extend. No lock on principal. Emissions elapsing with zero stakers become sweepable to the treasury after the curve ends. |

There is deliberately **no** deployer key that retains any power after deployment. The only
trusted party in the system is the distribution/treasury multisig, which holds pre-minted pools.

## Decisions of record (handoff §4, answered 2026-07-25)

| Question | Decision |
|---|---|
| §4.1 Anti-dump fee | **Option C — platform-level only.** No fee logic in any contract. The fee applies to in-platform sales and is bypassable by self-custody withdrawal; whitepaper §7.3/§9.5 language must be softened accordingly (see DEVIATIONS.md). |
| §4.2 Launch lock | **Dropped.** No transfer restriction exists in the token. Distribution timing is controlled by when pools actually release tokens, not by a lock on holders. Whitepaper §7.3 "not externally transferable until listing" must be revised. |
| §4.3 Upgradeability | **Immutable.** No proxies anywhere. |
| §4.4 Decimals | **18** (BEP-20 convention). |
| §4.4 Burn | **No burn function.** Supply is constant at exactly 1,000,000,000. |

## Layout

```
src/GFTW.sol             token (P0)
src/GFTWVesting.sol      vesting wallet: team / investors / treasury (P0)
src/MigrationRegistry.sol receipt-wallet registration window (P0)
src/MigrationClaim.sol   snapshot Merkle claim (P0)
src/GFTWStaking.sol      staking with hardcoded 180M decay curve (P1)
script/Deploy.s.sol      DeployToken / DeployVesting / DeployRegistry / DeployMigration / DeployStaking
merkle/generate.mjs      claims CSV -> Merkle root + proofs (OZ StandardMerkleTree)
snapshot/rebuild.mjs     chain replay -> holder balances at the pre-mint cutoff
snapshot/export-registrations.mjs  registry events -> registrations.csv
snapshot/build-claims.mjs balances ⋈ registrations (+ reviewed manual additions) -> claims.csv
test/                    unit + fuzz suite
```

## Migration pipeline (registration-gated)

GFTW is **not** sent to raw snapshot addresses. The flow, each step reproducible by anyone:

1. `snapshot/rebuild.mjs --to 44384350` — rebuild all 4,908 holder balances at the
   pre-mint cutoff block (Nov 27 2024 mint excluded by construction; integrity-checked).
2. Deploy `MigrationRegistry`; during the window, holders designate a receipt wallet
   *from the holding wallet* (or by signed message the platform relays). Covers moved
   funds, compromised wallets, and cold-storage holders.
3. `snapshot/export-registrations.mjs` — dump registrations from chain events.
4. `snapshot/build-claims.mjs` — join balances ⋈ registrations, apply the published
   exclusion list (`snapshot/exclusions.csv`: operator/scheme wallets), append reviewed
   manual additions (e.g. exchange-custody cases proven off-chain).
5. `merkle/generate.mjs` — build the tree over (receipt wallet, GFTW amount); enforces
   the 130M pool cap.
6. Deploy `MigrationClaim` with the root; fund with the pool; unregistered/unclaimed
   value ends up with the treasury after the claim window.

## Build & test

```bash
forge build
forge test               # unit + fuzz (1024 runs each)
forge coverage           # 100% lines/branches/funcs on GFTW + MigrationClaim
```

## Migration Merkle tree

```bash
cd merkle && npm install        # single zero-dep package: @noble/hashes (keccak)
node generate.mjs snapshot.csv --gft-decimals 18
# -> out/summary.json (root), out/proofs.json (claim UI), out/merkle-tree.json (OZ dump),
#    out/parity.json (consumed by test/MerkleParity.t.sol)
```

Input CSV: `address,gft_balance` in GFT smallest units. Conversion is 5:1 with floor
rounding; duplicate addresses are summed; entries rounding to zero are dropped. The script
aborts if the total exceeds the 130M GFTW pool and self-verifies every proof before writing.
The tree reproduces OZ `StandardMerkleTree` (`standard-v1`, `["address","uint256"]`)
exactly — `out/merkle-tree.json` loads with the unmodified OZ JS library, and
`test/MerkleParity.t.sol` deploys `MigrationClaim` with the generated root and executes
real claims against it (rerun it with the real snapshot as the E2E rehearsal).
**Publish `out/merkle-tree.json` + the snapshot CSV so anyone can independently reproduce
the root (whitepaper §7.4 transparency commitment).**

## Full rehearsal — no GUI, no funds, no network

```bash
./script/rehearsal.sh
```

Walks the entire runbook on a local anvil chain with the canonical Safe v1.4.1 bytecode
injected at its canonical addresses (vendored in `script/safe-bytecode/`): creates a Safe
from the CLI, deploys all four contracts via the forge scripts, funds the pools with real
Safe `execTransaction` calls (approved-hash signatures — no Safe web app involved), then
exercises a migration claim, a month of staking, the 12-month cliff release, and the
post-window sweep, asserting exact balances at each step.

The same command sequence works against real BSC testnet/mainnet: point `--rpc-url` at the
chain (Safe's contracts are already at those addresses) and replace the anvil key with
`--ledger`. The Safe web app is never required — signers can use `cast`/safe-cli — though
signers may still prefer it for reviewing queued transactions.

## Deployment runbook (testnet first — always)

Deployment is irreversible. Do not proceed past any step that fails.

0. **Pre-flight:** treasury/distribution **Safe multisig deployed and verified** on the target
   chain (threshold + signers per whitepaper §13); deployer is a hardware wallet generated
   air-gapped; snapshot root generated and independently reproduced by a second person.
1. **Dry-run every script** (no `--broadcast`):
   `DISTRIBUTOR=<safe> forge script script/Deploy.s.sol:DeployToken --rpc-url bsc_testnet`
2. **Deploy token** (adds `--broadcast --verify --ledger`). The scripts refuse to run if
   `DISTRIBUTOR`/`TREASURY` are not contracts, so supply cannot land on an EOA.
3. **Verify on BscScan before anything else.** Do not announce an unverified address.
4. **Deploy vesting wallets** (`DeployVesting`, one per beneficiary):
   team `CLIFF_MONTHS=12 DURATION_MONTHS=36`; investors/advisors `6/24`; treasury `0/36`.
5. **Deploy registry** (`DeployRegistry` with the registration window) and **staking**
   (`DeployStaking` with `TGE_TIMESTAMP` as the emission start). Announce registration.
6. **After the registration window closes:** `export-registrations.mjs` →
   `build-claims.mjs` → `generate.mjs` → publish the tree → **deploy migration**
   (`DeployMigration` with the resulting `MERKLE_ROOT` and claim window).
7. **Fund from the multisig:** ≤130M GFTW → MigrationClaim (fund the tree total);
   180M GFTW → GFTWStaking; allocations → each vesting wallet. Confirm balances
   on-chain before announcing.
8. **Liquidity:** seed LP at listing, lock LP tokens with a reputable locker, publish the lock.
9. **Publish addresses** to whitepaper §15 only after every step above is confirmed.

There are no ownership-transfer steps because no contract has an owner to transfer
(vesting wallets are "owned" by their beneficiaries by OZ construction).

## Audit gate (do not reorder)

tests green → second-engineer line review → testnet E2E with real snapshot →
Slither/Mythril triaged in writing → independent audit → criticals fixed →
report published → mainnet.

Known static-analysis notes (pre-triaged): `block.timestamp` comparisons in
`MigrationClaim` are inherent to a claim window measured in weeks — validator drift of
seconds is immaterial. Forge lint `erc20-unchecked-transfer` findings are in test files
only; production code uses `SafeERC20`.

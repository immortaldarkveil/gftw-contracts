# GFT → GFTW Migration Snapshot — Transparency Report

Generated: 2026-07-26 06:32 UTC

## What this is

The complete, independently reproducible record of who held legacy GFT at the
migration snapshot block, how the snapshot was taken, and which addresses are
excluded and why. Every number below can be verified against public BSC chain
data by anyone — no trust in the GiftoV3 team is required.

## Snapshot definition

| Parameter | Value |
|---|---|
| Token | GFT (BEP-20) `0x72fF5742319eF07061836F5C924aC6D72c919080` |
| Cutoff block | **44,384,350** |
| Why this block | The last block before the first of eight unauthorized mint events on Nov 27 2024 (first mint tx `0xf2aa17d4050f5980dea52221309a86641cc3c4996f7377661a929786d128ed74`, block 44,384,351, 18:57:09 UTC; 1.2B GFT minted total). Cutting here structurally excludes the minted supply and everyone who acquired it. |
| Method | Replay of all 103225 Transfer events from contract creation (block 24,170,133) to the cutoff |
| Holders at cutoff | **4908** |
| Supply at cutoff | **1,039,997,051 GFT** |
| Integrity check | Sum of all balances equals minted − burned exactly (see report.json: supplyCheckPassed) |

## Exclusions

See `exclusions.csv`. Excluded addresses and the published reason for each.
The prior operators' wallets — including the address that received the initial
deployment mint and later executed the Nov 2024 mints — receive nothing.

## Registration requirement

GFTW is not sent automatically to snapshot addresses. During the announced
registration window, each holder designates a receipt wallet by proving
control of the holding wallet (on-chain call or signed message) via the
MigrationRegistry contract. Custodial edge cases (e.g. exchange-held GFT) go
through a documented review process; any manually added entry is published in
this bundle. Unregistered balances are never distributed — after the claim
window they return to the community treasury.

## Verify it yourself

```bash
# 1. Rebuild the snapshot from public chain data (any BSC RPC with log history)
node snapshot/rebuild.mjs --to 44384350
diff <(sha256sum out/balances.csv) <(sha256sum transparency/balances.csv)

# 2. Check any single address's balance at the cutoff block appears in balances.csv

# 3. After the Merkle tree is published: recompute the root
node merkle/generate.mjs snapshot/out/claims.csv
# and compare with merkleRoot() on the MigrationClaim contract on BscScan
```

## File checksums

See `SHA256SUMS`. Verify with: `shasum -a 256 -c SHA256SUMS`

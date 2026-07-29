#!/usr/bin/env bash
# Builds the public transparency bundle for the GFT -> GFTW migration snapshot.
# Stage 1 (now): snapshot + exclusions + methodology, published at announcement.
# Stage 2 (after registration closes): rerun — registrations, claims, and the
# final Merkle tree are added automatically when their files exist.
set -euo pipefail
cd "$(dirname "$0")"

OUT=transparency
mkdir -p "$OUT"

cp out/balances.csv "$OUT"/
cp out/report.json "$OUT"/
cp exclusions.csv "$OUT"/
# stage-2 artifacts, included when present
for f in out/registrations.csv out/claims.csv out/claims-summary.json ../merkle/out/merkle-tree.json ../merkle/out/summary.json; do
  [ -f "$f" ] && cp "$f" "$OUT"/ || true
done

REPORT_JSON=$(cat out/report.json)
HOLDERS=$(node -pe 'JSON.parse(process.argv[1]).holders' "$REPORT_JSON")
SUPPLY=$(node -pe '(BigInt(JSON.parse(process.argv[1]).supplyAtCutoff)/10n**18n).toLocaleString("en-US")' "$REPORT_JSON")
TRANSFERS=$(node -pe 'JSON.parse(process.argv[1]).transfersReplayed' "$REPORT_JSON")

cat > "$OUT/TRANSPARENCY.md" << EOF
# GFT → GFTW Migration Snapshot — Transparency Report

Generated: $(date -u +"%Y-%m-%d %H:%M UTC")

## What this is

The complete, independently reproducible record of who held legacy GFT at the
migration snapshot block, how the snapshot was taken, and which addresses are
excluded and why. Every number below can be verified against public BSC chain
data by anyone — no trust in the GiftoV3 team is required.

## Snapshot definition

| Parameter | Value |
|---|---|
| Token | GFT (BEP-20) \`0x72fF5742319eF07061836F5C924aC6D72c919080\` |
| Cutoff block | **44,384,350** |
| Why this block | The last block before the first of eight unauthorized mint events on Nov 27 2024 (first mint tx \`0xf2aa17d4050f5980dea52221309a86641cc3c4996f7377661a929786d128ed74\`, block 44,384,351, 18:57:09 UTC; 1.2B GFT minted total). Cutting here structurally excludes the minted supply and everyone who acquired it. |
| Method | Replay of all $TRANSFERS Transfer events from contract creation (block 24,170,133) to the cutoff |
| Holders at cutoff | **$HOLDERS** |
| Supply at cutoff | **$SUPPLY GFT** |
| Integrity check | Sum of all balances equals minted − burned exactly (see report.json: supplyCheckPassed) |

## Exclusions

See \`exclusions.csv\`. Excluded addresses and the published reason for each.
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

\`\`\`bash
# 1. Rebuild the snapshot from public chain data (any BSC RPC with log history)
node snapshot/rebuild.mjs --to 44384350
diff <(sha256sum out/balances.csv) <(sha256sum transparency/balances.csv)

# 2. Check any single address's balance at the cutoff block appears in balances.csv

# 3. After the Merkle tree is published: recompute the root
node merkle/generate.mjs snapshot/out/claims.csv
# and compare with merkleRoot() on the MigrationClaim contract on BscScan
\`\`\`

## File checksums

See \`SHA256SUMS\`. Verify with: \`shasum -a 256 -c SHA256SUMS\`
EOF

cd "$OUT"
shasum -a 256 $(ls | grep -v SHA256SUMS) > SHA256SUMS
echo "bundle ready in snapshot/$OUT/:"
ls -la

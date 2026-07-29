#!/usr/bin/env node
/**
 * Builds the final claims CSV for the Merkle generator by joining:
 *   1. the rebuilt snapshot balances   (balances.csv: holder,gft_balance)
 *   2. the registration list           (registrations.csv: holder,recipient)
 *   3. optional reviewed additions     (manual-additions.csv: recipient,gft_balance,label)
 * minus the exclusion list             (exclusions.csv: holder,label)
 *
 * Only snapshot holders who registered a receipt wallet are included — GFTW
 * is not sent to unregistered addresses. Manual additions cover reviewed
 * special cases (e.g. exchange-custodied balances proven off-chain) and are
 * reported separately so the published data stays auditable.
 *
 * Output: out/claims.csv (recipient,gft_balance) — feed to merkle/generate.mjs
 * (run generate WITHOUT --exclude: exclusions are applied here, on holders).
 * Multiple holders may name the same recipient; the generator sums them.
 *
 * Usage:
 *   node build-claims.mjs --balances out/balances.csv --registrations out/registrations.csv \
 *     [--manual manual-additions.csv] [--exclude exclusions.csv] [--out out/claims.csv]
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const argOf = (name, dflt) => {
  const i = args.indexOf(name);
  return i === -1 ? dflt : args[i + 1];
};
const here = dirname(fileURLToPath(import.meta.url));
const balancesPath = argOf("--balances", join(here, "out", "balances.csv"));
const registrationsPath = argOf("--registrations", join(here, "out", "registrations.csv"));
const manualPath = argOf("--manual", null);
const excludePath = argOf("--exclude", join(here, "exclusions.csv"));
const outPath = argOf("--out", join(here, "out", "claims.csv"));

const isAddr = (s) => /^0x[0-9a-fA-F]{40}$/.test(s);

function rows(path) {
  return readFileSync(path, "utf8")
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith("#") && !l.toLowerCase().startsWith("address") && !l.toLowerCase().startsWith("holder") && !l.toLowerCase().startsWith("recipient"))
    .map((l) => l.split(",").map((s) => s.trim()));
}

const excluded = new Set();
if (excludePath) {
  try {
    for (const [addr] of rows(excludePath)) {
      if (!isAddr(addr)) throw new Error(`bad exclusion address: ${addr}`);
      excluded.add(addr.toLowerCase());
    }
  } catch (e) {
    if (e.code !== "ENOENT") throw e;
  }
}

const registrations = new Map();
for (const [holder, recipient] of rows(registrationsPath)) {
  if (!isAddr(holder) || !isAddr(recipient)) throw new Error(`bad registration row: ${holder},${recipient}`);
  registrations.set(holder.toLowerCase(), recipient.toLowerCase());
}

let included = 0n;
let unregistered = 0n;
let excludedGft = 0n;
let holdersIncluded = 0;
let holdersUnregistered = 0;
let holdersExcluded = 0;
const out = [];
for (const [holder, bal] of rows(balancesPath)) {
  if (!isAddr(holder)) throw new Error(`bad balances row: ${holder}`);
  const b = BigInt(bal);
  const h = holder.toLowerCase();
  if (excluded.has(h)) {
    holdersExcluded++;
    excludedGft += b;
    continue;
  }
  const recipient = registrations.get(h);
  if (!recipient) {
    holdersUnregistered++;
    unregistered += b;
    continue;
  }
  out.push([recipient, b]);
  included += b;
  holdersIncluded++;
}

let manual = 0n;
let manualCount = 0;
if (manualPath) {
  for (const [recipient, bal] of rows(manualPath)) {
    if (!isAddr(recipient)) throw new Error(`bad manual row: ${recipient}`);
    out.push([recipient.toLowerCase(), BigInt(bal)]);
    manual += BigInt(bal);
    manualCount++;
  }
}

mkdirSync(dirname(outPath), { recursive: true });
let csv = "address,gft_balance\n";
for (const [r, b] of out) csv += `${r},${b}\n`;
writeFileSync(outPath, csv);

// Mirror generate.mjs exactly: merge duplicate recipients first, then floor
// each recipient's GFTW at 5:1 — so this figure matches the tree's
// totalGftwWei to the wei (assumes 18-decimal GFT, as the rebuilt snapshot is).
const byRecipient = new Map();
for (const [r, b] of out) byRecipient.set(r, (byRecipient.get(r) ?? 0n) + b);
let claimableWei = 0n;
for (const b of byRecipient.values()) claimableWei += b / 5n;

const gft = (v) => (v / 10n ** 18n).toLocaleString();
const summary = {
  holdersIncluded,
  holdersUnregistered,
  holdersExcluded,
  manualAdditions: manualCount,
  includedGft: gft(included),
  unregisteredGft: gft(unregistered),
  excludedGft: gft(excludedGft),
  manualGft: gft(manual),
  claimableGftwAt5to1: gft(claimableWei),
  claimableGftwWei: claimableWei.toString(),
  out: outPath,
};
writeFileSync(join(dirname(outPath), "claims-summary.json"), JSON.stringify(summary, null, 2));
console.log(JSON.stringify(summary, null, 2));

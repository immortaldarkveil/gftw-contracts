#!/usr/bin/env node
/**
 * GFT snapshot rebuild — reconstructs every holder's GFT balance at a cutoff
 * block by replaying all Transfer events from contract creation, using only
 * public JSON-RPC (no BscScan account, no GUI).
 *
 * Output (snapshot/out/):
 *   balances.csv   — `address,gft_balance` (raw 18-dec wei), sorted by balance
 *                    desc. Direct input for merkle/generate.mjs.
 *   report.json    — holders, supply cross-check (minted - burned == sum),
 *                    top holders with contract/EOA flag, parameters used.
 *
 * Usage:
 *   node rebuild.mjs --to <cutoffBlock> [--from 24170133] [--rpc url] [--step 10000]
 *
 * The scan checkpoints to out/checkpoint.json after every chunk and resumes
 * automatically, so rate-limit interruptions or ^C are safe.
 *
 * GFT (BSC): 0x72fF5742319eF07061836F5C924aC6D72c919080, created at block
 * 24,170,133 (2022-12-25). Recommended cutoff: block 44,384,350 — the block
 * before the first of the eight Nov 27 2024 mint events (1.2B GFT total,
 * first mint tx 0xf2aa17d4050f5980dea52221309a86641cc3c4996f7377661a929786d1
 * 28ed74 at block 44,384,351, 18:57:09 UTC). Cutting there excludes the
 * minted supply and everyone who bought it.
 *
 * NOTE (business, not code): balances held by exchanges, bridges, and LP
 * contracts are custodial — crediting them 1:1 sends users' GFTW to the
 * custodian. report.json flags top holders that are contracts; the project
 * lead must decide the exclusion list before the Merkle tree is generated.
 */
import { execFileSync, execFile } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, existsSync, renameSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

const GFT = "0x72ff5742319ef07061836f5c924ac6d72c919080";
const TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const ZERO = "0x0000000000000000000000000000000000000000";
const DEAD = "0x000000000000000000000000000000000000dead";
const CREATION_BLOCK = 24170133;

const args = process.argv.slice(2);
const argOf = (name, dflt) => {
  const i = args.indexOf(name);
  return i === -1 ? dflt : args[i + 1];
};
const cutoff = parseInt(argOf("--to", ""), 10);
const fromBlock = parseInt(argOf("--from", String(CREATION_BLOCK)), 10);
// NodeReal public gateway retains full historical logs; range cap 50k blocks
const RPC = argOf("--rpc", "https://bsc-mainnet.nodereal.io/v1/64a9df0874fb4a93b9d0a3849de012d3");
const STEP = parseInt(argOf("--step", "50000"), 10);
if (!cutoff) {
  console.error("usage: node rebuild.mjs --to <cutoffBlock> [--from N] [--rpc url] [--step N]");
  process.exit(1);
}

const outDir = join(dirname(fileURLToPath(import.meta.url)), "out");
mkdirSync(outDir, { recursive: true });
const ckptPath = join(outDir, "checkpoint.json");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// curl -4 transport: this environment blocks IPv6, which breaks node fetch
async function rpcRaw(method, params) {
  const body = JSON.stringify({ jsonrpc: "2.0", id: 1, method, params });
  const { stdout } = await execFileP(
    "curl",
    ["-4", "-s", "--max-time", "90", "-X", "POST", RPC, "-H", "Content-Type: application/json", "-d", body],
    { encoding: "utf8", maxBuffer: 1 << 28 }
  );
  return JSON.parse(stdout);
}

class RangeTooLarge extends Error {}

async function rpc(method, params) {
  for (let attempt = 0; ; attempt++) {
    try {
      const j = await rpcRaw(method, params);
      if (j.error) {
        const msg = String(j.error.message ?? "").toLowerCase();
        // order matters: throughput/usage errors also contain the word "limit"
        if (msg.includes("rate") || msg.includes("usage") || msg.includes("throughput") || msg.includes("capacity")) {
          console.log(`rate limited, cooling down 30s`);
          await sleep(30000);
          continue;
        }
        if (msg.includes("exceed maximum block range") || msg.includes("too many") || msg.includes("response size") || msg.includes("more than")) {
          throw new RangeTooLarge(msg);
        }
        throw new Error(JSON.stringify(j.error));
      }
      return j.result;
    } catch (e) {
      if (e instanceof RangeTooLarge) throw e;
      if (attempt >= 8) throw e;
      await sleep(5000 * (attempt + 1));
    }
  }
}

/** getLogs with recursive bisection when the provider rejects a dense range. */
async function getLogsRange(from, to) {
  try {
    return await rpc("eth_getLogs", [
      { address: GFT, fromBlock: "0x" + from.toString(16), toBlock: "0x" + to.toString(16), topics: [TRANSFER] },
    ]);
  } catch (e) {
    if (!(e instanceof RangeTooLarge) || from === to) throw e;
    const mid = Math.floor((from + to) / 2);
    console.log(`dense range ${from}..${to}, bisecting`);
    return [...(await getLogsRange(from, mid)), ...(await getLogsRange(mid + 1, to))];
  }
}

// ------------------------------------------------------------------- resume

let balances = new Map(); // address (lowercase) -> bigint
let minted = 0n;
let burned = 0n;
let transfers = 0;
let start = fromBlock;

if (existsSync(ckptPath)) {
  const c = JSON.parse(readFileSync(ckptPath, "utf8"));
  if (c.cutoff === cutoff && c.gft === GFT) {
    start = c.nextBlock;
    minted = BigInt(c.minted);
    burned = BigInt(c.burned);
    transfers = c.transfers;
    balances = new Map(Object.entries(c.balances).map(([a, v]) => [a, BigInt(v)]));
    console.log(`resuming at block ${start} (${balances.size} holders so far)`);
  }
}

function saveCheckpoint(nextBlock) {
  const tmp = ckptPath + ".tmp";
  writeFileSync(
    tmp,
    JSON.stringify({
      gft: GFT,
      cutoff,
      nextBlock,
      minted: minted.toString(),
      burned: burned.toString(),
      transfers,
      balances: Object.fromEntries([...balances].map(([a, v]) => [a, v.toString()])),
    })
  );
  renameSync(tmp, ckptPath);
}

// --------------------------------------------------------------------- scan

// Prefetch pool: several chunks download concurrently, but results are
// applied strictly in block order so the checkpoint always represents a
// contiguous prefix (safe to resume from).
const CONCURRENCY = 2;
const inflight = new Map(); // chunk start -> promise of logs
function prefetch(from) {
  if (from > cutoff || inflight.has(from)) return;
  inflight.set(from, getLogsRange(from, Math.min(from + STEP - 1, cutoff)));
}

const t0 = Date.now();
for (let i = 0; i < CONCURRENCY; i++) prefetch(start + i * STEP);
for (let from = start; from <= cutoff; from += STEP) {
  const to = Math.min(from + STEP - 1, cutoff);
  prefetch(from + CONCURRENCY * STEP);
  const logs = await inflight.get(from);
  inflight.delete(from);
  for (const e of logs) {
    const src = ("0x" + e.topics[1].slice(26)).toLowerCase();
    const dst = ("0x" + e.topics[2].slice(26)).toLowerCase();
    const val = BigInt(e.data === "0x" ? 0 : e.data);
    transfers++;
    if (src === ZERO) minted += val;
    else {
      const nb = (balances.get(src) ?? 0n) - val;
      if (nb < 0n) throw new Error(`negative balance for ${src} at block ${parseInt(e.blockNumber, 16)}`);
      if (nb === 0n) balances.delete(src);
      else balances.set(src, nb);
    }
    if (dst === ZERO || dst === DEAD) burned += val;
    else if (val > 0n) balances.set(dst, (balances.get(dst) ?? 0n) + val);
  }
  saveCheckpoint(to + 1);
  const pct = (((to - fromBlock) / (cutoff - fromBlock)) * 100).toFixed(1);
  const rate = (to - start) / ((Date.now() - t0) / 1000 / 60); // blocks per minute
  const etaMin = rate > 0 ? Math.round((cutoff - to) / rate) : "?";
  console.log(`blocks ${from}..${to} (${pct}%) | ${logs.length} logs | holders ${balances.size} | ~${etaMin}min left`);
  await sleep(300);
}

// ------------------------------------------------------------------ outputs

const sorted = [...balances.entries()].sort((a, b) => (b[1] > a[1] ? 1 : b[1] < a[1] ? -1 : 0));
const sum = sorted.reduce((s, [, v]) => s + v, 0n);
const expected = minted - burned;

let csv = "address,gft_balance\n";
for (const [addr, bal] of sorted) csv += `${addr},${bal}\n`;
writeFileSync(join(outDir, "balances.csv"), csv);

// flag top holders that are contracts (custodial risk) — latest-state getCode
const top = [];
for (const [addr, bal] of sorted.slice(0, 100)) {
  const code = await rpc("eth_getCode", [addr, "latest"]);
  top.push({ address: addr, balance: bal.toString(), pctOfSupply: Number((bal * 10000n) / sum) / 100, isContract: code !== "0x" });
  await sleep(300);
}

const report = {
  token: GFT,
  cutoffBlock: cutoff,
  scannedFromBlock: fromBlock,
  transfersReplayed: transfers,
  holders: sorted.length,
  supplyAtCutoff: expected.toString(),
  sumOfBalances: sum.toString(),
  supplyCheckPassed: sum === expected,
  minted: minted.toString(),
  burned: burned.toString(),
  topHolders: top,
  generated: new Date().toISOString(),
};
writeFileSync(join(outDir, "report.json"), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ ...report, topHolders: top.slice(0, 10) }, null, 2));
console.log(sum === expected ? "SUPPLY CHECK PASSED" : "SUPPLY CHECK FAILED — do not use this snapshot");

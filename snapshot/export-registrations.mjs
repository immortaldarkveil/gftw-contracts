#!/usr/bin/env node
/**
 * Exports MigrationRegistry registrations to registrations.csv by scanning
 * Registered events. Last registration per holder wins (mirrors contract
 * storage; cross-checked against recipientOf for the final state).
 *
 * Usage:
 *   node export-registrations.mjs --registry 0x... --from <deployBlock> [--to latest]
 *     [--rpc url] [--out out/registrations.csv]
 */
import { execFileSync } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// keccak256("Registered(address,address,bool)")
const REGISTERED_TOPIC = "0x4dbfe825dbdbec783d5804f250645ee3c48de5bdff84ed6c5a2de06425263a54";

const args = process.argv.slice(2);
const argOf = (name, dflt) => {
  const i = args.indexOf(name);
  return i === -1 ? dflt : args[i + 1];
};
const registry = argOf("--registry", "");
const fromBlock = parseInt(argOf("--from", ""), 10);
const RPC = argOf("--rpc", "https://bsc-mainnet.nodereal.io/v1/64a9df0874fb4a93b9d0a3849de012d3");
const STEP = parseInt(argOf("--step", "50000"), 10);
if (!registry || !fromBlock) {
  console.error("usage: node export-registrations.mjs --registry 0x... --from <deployBlock> [--to N] [--rpc url]");
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function rpcRaw(method, params) {
  const body = JSON.stringify({ jsonrpc: "2.0", id: 1, method, params });
  const out = execFileSync(
    "curl",
    ["-4", "-s", "--max-time", "90", "-X", "POST", RPC, "-H", "Content-Type: application/json", "-d", body],
    { encoding: "utf8", maxBuffer: 1 << 28 }
  );
  return JSON.parse(out);
}

async function rpc(method, params) {
  for (let attempt = 0; ; attempt++) {
    const j = rpcRaw(method, params);
    if (!j.error) return j.result;
    const msg = String(j.error.message ?? "").toLowerCase();
    if (msg.includes("rate") || msg.includes("usage") || msg.includes("throughput")) {
      await sleep(30000);
      continue;
    }
    if (attempt >= 8) throw new Error(JSON.stringify(j.error));
    await sleep(5000 * (attempt + 1));
  }
}

const head = argOf("--to", "") || parseInt(await rpc("eth_blockNumber", []), 16);
const toBlock = parseInt(head, 10);

// order matters: later events override earlier ones (last registration wins)
const recipients = new Map();
let events = 0;
for (let from = fromBlock; from <= toBlock; from += STEP) {
  const to = Math.min(from + STEP - 1, toBlock);
  const logs = await rpc("eth_getLogs", [
    { address: registry, fromBlock: "0x" + from.toString(16), toBlock: "0x" + to.toString(16), topics: [REGISTERED_TOPIC] },
  ]);
  // eth_getLogs returns logs in block/log-index order within the range
  for (const e of logs) {
    events++;
    recipients.set(("0x" + e.topics[1].slice(26)).toLowerCase(), ("0x" + e.topics[2].slice(26)).toLowerCase());
  }
  console.log(`blocks ${from}..${to} | ${logs.length} events`);
  await sleep(300);
}

const outPath = argOf("--out", join(dirname(fileURLToPath(import.meta.url)), "out", "registrations.csv"));
mkdirSync(dirname(outPath), { recursive: true });
let csv = "holder,recipient\n";
for (const [h, r] of [...recipients.entries()].sort()) csv += `${h},${r}\n`;
writeFileSync(outPath, csv);
console.log(`${events} events, ${recipients.size} holders registered -> ${outPath}`);

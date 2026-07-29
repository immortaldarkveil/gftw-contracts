#!/usr/bin/env node
/**
 * GFTW migration Merkle tree generator.
 *
 * Input:  CSV of snapshot balances: `address,gft_balance` where gft_balance is
 *         in the GFT token's smallest units (see --gft-decimals).
 * Output: out/merkle-tree.json  — OpenZeppelin StandardMerkleTree "standard-v1"
 *                                 dump, loadable with StandardMerkleTree.load()
 *         out/proofs.json       — { address: { amount, proof[] } } for the claim UI
 *         out/summary.json      — root, entry count, total GFTW distributed
 *
 * Conversion: 5 GFT -> 1 GFTW, floor division, result in 18-decimal GFTW wei:
 *   gftw = gft_balance * 10^(18 - gftDecimals) / 20   (integer floor)
 *
 * Tree construction reproduces @openzeppelin/merkle-tree's StandardMerkleTree
 * for leaf encoding ["address", "uint256"] exactly (double-keccak leaves,
 * descending leaf sort, commutative pair hashing), so third parties can verify
 * the published dump with the unmodified OZ library. The leaf is:
 *   keccak256(bytes.concat(keccak256(abi.encode(address account, uint256 amount))))
 * which is exactly what MigrationClaim.sol verifies. Only dependency is the
 * zero-dep @noble/hashes keccak (vendored via `npm install` or curl).
 *
 * Usage:
 *   node generate.mjs snapshot.csv --gft-decimals 18 [--exclude exclusions.csv]
 *
 * --exclude: CSV whose first column is an address to omit from the tree
 * (comments with #, other columns ignored). Used for the operator/scheme
 * wallets and any custodial addresses per the published exclusion policy.
 * Excluded totals are reported so the policy is auditable.
 */
import { keccak_256 } from "@noble/hashes/sha3";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";

const MIGRATION_POOL = 130_000_000n * 10n ** 18n; // 130M GFTW hard budget (13% of supply)
const RATIO = 5n;

// ---------------------------------------------------------------- primitives

const toHex = (b) => "0x" + Buffer.from(b).toString("hex");
const fromHex = (h) => Uint8Array.from(Buffer.from(h.replace(/^0x/, ""), "hex"));
const keccak = (b) => keccak_256(b);
const concat = (a, b) => {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
};
const compareBytes = (a, b) => {
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i] - b[i];
  return 0;
};

/** EIP-55 checksum address; throws on malformed input. */
function checksumAddress(raw) {
  if (!/^0x[0-9a-fA-F]{40}$/.test(raw)) throw new Error(`invalid address "${raw}"`);
  const lower = raw.slice(2).toLowerCase();
  const hash = Buffer.from(keccak(Buffer.from(lower, "ascii"))).toString("hex");
  let out = "0x";
  for (let i = 0; i < 40; i++) {
    out += parseInt(hash[i], 16) >= 8 ? lower[i].toUpperCase() : lower[i];
  }
  return out;
}

/** abi.encode(address, uint256) — two left-padded 32-byte words. */
function abiEncodeLeaf(address, amount) {
  const out = new Uint8Array(64);
  out.set(fromHex(address), 12);
  let v = amount;
  for (let i = 63; i >= 32 && v > 0n; i--) {
    out[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return out;
}

const leafHash = (address, amount) => keccak(concat(new Uint8Array(0), keccak(abiEncodeLeaf(address, amount))));
const hashPair = (a, b) => keccak(compareBytes(a, b) <= 0 ? concat(a, b) : concat(b, a));

// --------------------------------------------------------------- parse input

const args = process.argv.slice(2);
const csvPath = args.find((a) => !a.startsWith("--"));
const decIdx = args.indexOf("--gft-decimals");
const gftDecimals = decIdx === -1 ? 18n : BigInt(args[decIdx + 1]);
const exclIdx = args.indexOf("--exclude");
const excludePath = exclIdx === -1 ? null : args[exclIdx + 1];

if (!csvPath) {
  console.error("usage: node generate.mjs <snapshot.csv> [--gft-decimals N]");
  process.exit(1);
}
if (gftDecimals > 18n) throw new Error("gft-decimals > 18 unsupported");

const scale = 10n ** (18n - gftDecimals);

const excluded = new Set();
if (excludePath) {
  for (const raw of readFileSync(excludePath, "utf8").split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#") || line.toLowerCase().startsWith("address")) continue;
    excluded.add(checksumAddress(line.split(",")[0].trim()));
  }
}

const seen = new Map();

for (const [i, raw] of readFileSync(csvPath, "utf8").split("\n").entries()) {
  const line = raw.trim();
  if (!line || line.toLowerCase().startsWith("address")) continue; // header/blank
  const [addrRaw, balRaw] = line.split(",").map((s) => s.trim());
  const addr = checksumAddress(addrRaw); // throws with context below
  const bal = BigInt(balRaw);
  if (bal < 0n) throw new Error(`line ${i + 1}: negative balance`);
  // Duplicate addresses in the snapshot are merged (summed) — the claim
  // contract allows exactly one claim per address.
  seen.set(addr, (seen.get(addr) ?? 0n) + bal);
}

let total = 0n;
let dustDropped = 0;
let excludedCount = 0;
let excludedGft = 0n;
const values = []; // [address, amountString] in deterministic (sorted) order
for (const [addr, gft] of [...seen.entries()].sort()) {
  if (excluded.has(addr)) {
    excludedCount++;
    excludedGft += gft;
    continue; // policy exclusion (operator/scheme/custodial wallets)
  }
  const gftw = (gft * scale) / RATIO; // floor
  if (gftw === 0n) {
    dustDropped++;
    continue; // < 5 GFT-wei rounds to zero; cannot be a claimable leaf
  }
  values.push([addr, gftw.toString()]);
  total += gftw;
}

if (values.length === 0) throw new Error("no non-zero entries");
if (total > MIGRATION_POOL) {
  throw new Error(`total ${total} exceeds 130M GFTW migration pool — check ratio/decimals`);
}

// ---------------------------------------------------- build OZ-standard tree

const hashed = values.map((v, valueIndex) => ({
  valueIndex,
  hash: leafHash(v[0], BigInt(v[1])),
}));
// OZ StandardMerkleTree sorts hashed leaves in descending order.
hashed.sort((a, b) => compareBytes(b.hash, a.hash));

const n = hashed.length;
const tree = new Array(2 * n - 1);
const treeIndexOfValue = new Array(n);
hashed.forEach((h, leafPos) => {
  const treeIndex = tree.length - 1 - leafPos;
  tree[treeIndex] = h.hash;
  treeIndexOfValue[h.valueIndex] = treeIndex;
});
for (let i = tree.length - 1 - n; i >= 0; i--) {
  tree[i] = hashPair(tree[2 * i + 1], tree[2 * i + 2]);
}
const root = toHex(tree[0]);

function getProof(treeIndex) {
  const proof = [];
  let i = treeIndex;
  while (i > 0) {
    proof.push(toHex(tree[i % 2 === 0 ? i - 1 : i + 1]));
    i = Math.floor((i - 1) / 2);
  }
  return proof;
}

// Self-check: every proof must fold back to the root before we publish it.
const proofs = {};
for (const [valueIndex, [addr, amount]] of values.entries()) {
  const proof = getProof(treeIndexOfValue[valueIndex]);
  let acc = leafHash(addr, BigInt(amount));
  for (const p of proof) acc = hashPair(acc, fromHex(p));
  if (toHex(acc) !== root) throw new Error(`proof self-check failed for ${addr}`);
  proofs[addr] = { amount, proof };
}

// ------------------------------------------------------------------- outputs

mkdirSync("out", { recursive: true });
writeFileSync(
  "out/merkle-tree.json",
  JSON.stringify(
    {
      format: "standard-v1",
      leafEncoding: ["address", "uint256"],
      tree: tree.map(toHex),
      values: values.map((value, i) => ({ value, treeIndex: treeIndexOfValue[i] })),
    },
    null,
    2
  )
);
writeFileSync("out/proofs.json", JSON.stringify(proofs, null, 2));
// Fixed-shape file consumed by test/MerkleParity.t.sol to prove the JS tree
// verifies against the on-chain MerkleProof implementation.
writeFileSync(
  "out/parity.json",
  JSON.stringify(
    {
      root,
      count: values.length,
      claims: values.map(([account, amount], i) => ({
        account,
        amount,
        proof: getProof(treeIndexOfValue[i]),
      })),
    },
    null,
    2
  )
);
const summary = {
  root,
  entries: values.length,
  uniqueAddresses: seen.size,
  dustEntriesDropped: dustDropped,
  excludedAddresses: excludedCount,
  excludedGftWei: excludedGft.toString(),
  totalGftwWei: total.toString(),
  poolGftwWei: MIGRATION_POOL.toString(),
  generated: new Date().toISOString(),
};
writeFileSync("out/summary.json", JSON.stringify(summary, null, 2));
console.log(JSON.stringify(summary, null, 2));

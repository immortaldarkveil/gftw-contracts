#!/usr/bin/env bash
# GFTW full deployment rehearsal — zero GUI, zero real funds, fully offline.
#
# Runs a local anvil chain with the canonical Safe v1.4.1 bytecode injected at
# its canonical addresses (vendored in script/safe-bytecode/, fetched from BSC
# testnet), then walks the entire runbook:
#   1. deploy a real Safe (v1.4.1 canonical factory) from the CLI
#   2. deploy GFTW / vesting / migration / staking via the forge scripts
#   3. fund the pools from the Safe via execTransaction (approved-hash flow)
#   4. exercise: migration claim -> stake -> earn -> vest release -> sweep
#
# Usage:  ./script/rehearsal.sh
# Requires: foundry, node. Run from the repo root.
#
# The same commands run against real BSC testnet by pointing RPC at the chain
# (the Safe contracts are already at these addresses there) and signing with
# --ledger instead of the anvil key. Avoid `anvil --fork-url` against free
# public BSC RPCs: they prune state and long time-warps crash the fork.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

RPC=http://127.0.0.1:8546

# Safe v1.4.1 canonical addresses (present on BSC testnet + mainnet)
SAFE_FACTORY=0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67
SAFE_SINGLETON_L2=0x29fcB43b46531BcA003ddC8FCB67FFE91900C762
SAFE_FALLBACK=0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99

# anvil dev accounts (public test keys, never real funds)
DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
CLAIMANT=0x70997970C51812dc3A010C7d01b50e0d17dc79C8   # snapshot holder (merkle/sample.csv)
CLAIMANT_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
RECEIPT=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc    # receipt wallet the holder registers
RECEIPT_PK=0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba
BENEFICIARY=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65  # vesting beneficiary

DAY=86400
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
dec()  { echo "$1" | awk '{print $1}'; }
warp() { cast rpc evm_setNextBlockTimestamp "$1" --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null; }
bal()  { dec "$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$1" --rpc-url $RPC)"; }

step "starting local anvil with canonical Safe v1.4.1 bytecode injected"
anvil --port 8546 --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
for i in $(seq 1 60); do cast chain-id --rpc-url $RPC >/dev/null 2>&1 && break; sleep 1; done
cast rpc anvil_setCode $SAFE_FACTORY      "$(cat script/safe-bytecode/factory.hex)"      --rpc-url $RPC >/dev/null
cast rpc anvil_setCode $SAFE_SINGLETON_L2 "$(cat script/safe-bytecode/singleton-l2.hex)" --rpc-url $RPC >/dev/null
cast rpc anvil_setCode $SAFE_FALLBACK     "$(cat script/safe-bytecode/fallback.hex)"     --rpc-url $RPC >/dev/null
NOW=$(cast block latest -f timestamp --rpc-url $RPC)
echo "anvil ready, chain-id $(cast chain-id --rpc-url $RPC), t=$NOW"

step "1. create Safe multisig from CLI (1-of-1 for rehearsal)"
INIT=$(cast calldata "setup(address[],uint256,address,bytes,address,address,uint256,address)" \
  "[$DEPLOYER]" 1 0x0000000000000000000000000000000000000000 0x \
  $SAFE_FALLBACK 0x0000000000000000000000000000000000000000 0 0x0000000000000000000000000000000000000000)
TX=$(cast send $SAFE_FACTORY "createProxyWithNonce(address,bytes,uint256)" \
  $SAFE_SINGLETON_L2 "$INIT" 20260726 \
  --private-key $DEPLOYER_PK --rpc-url $RPC --json | node -pe 'JSON.parse(require("fs").readFileSync(0)).transactionHash')
SAFE=$(cast receipt "$TX" --rpc-url $RPC --json | node -pe '
  const r=JSON.parse(require("fs").readFileSync(0));
  const l=r.logs.find(l=>l.address.toLowerCase()=="'$SAFE_FACTORY'".toLowerCase());
  "0x"+l.topics[1].slice(26)')
echo "Safe deployed: $SAFE  (owners=[deployer], threshold=1)"

# Safe helper: execTransaction via approved-hash (no GUI, no EIP-712 tooling)
safe_exec() { # $1 = target, $2 = calldata
  local NONCE HASH SIG
  NONCE=$(dec "$(cast call "$SAFE" "nonce()(uint256)" --rpc-url $RPC)")
  HASH=$(cast call "$SAFE" \
    "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
    "$1" 0 "$2" 0 0 0 0 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 "$NONCE" --rpc-url $RPC)
  cast send "$SAFE" "approveHash(bytes32)" "$HASH" --private-key $DEPLOYER_PK --rpc-url $RPC >/dev/null
  SIG=0x000000000000000000000000${DEPLOYER#0x}000000000000000000000000000000000000000000000000000000000000000001
  cast send "$SAFE" \
    "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)" \
    "$1" 0 "$2" 0 0 0 0 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 "$SIG" \
    --private-key $DEPLOYER_PK --rpc-url $RPC >/dev/null
}

step "2. deploy contracts via forge scripts (Safe is distributor/treasury)"
TGE=$((NOW + 300))
REG_START=$((NOW + 60))
REG_END=$((NOW + 30 * DAY))
CLAIM_START=$((REG_END + 60))
CLAIM_END=$((CLAIM_START + 90 * DAY))

run_script() { # $1 = contract name
  forge script script/Deploy.s.sol:"$1" --rpc-url $RPC --broadcast --private-key $DEPLOYER_PK 2>&1 |
    grep -Eo '0x[a-fA-F0-9]{40}' | head -1
}
TOKEN=$(DISTRIBUTOR=$SAFE run_script DeployToken)
echo "GFTW:           $TOKEN"
VESTING=$(BENEFICIARY=$BENEFICIARY TGE_TIMESTAMP=$TGE DURATION_MONTHS=36 CLIFF_MONTHS=12 run_script DeployVesting)
echo "Team vesting:   $VESTING"
REGISTRY=$(REGISTRATION_START=$REG_START REGISTRATION_END=$REG_END run_script DeployRegistry)
echo "Registry:       $REGISTRY"
STAKING=$(GFTW_ADDRESS=$TOKEN TREASURY=$SAFE TGE_TIMESTAMP=$TGE run_script DeployStaking)
echo "Staking:        $STAKING"
[ "$(bal "$SAFE")" = "1000000000000000000000000000" ] || { echo "FAIL: supply not on Safe"; exit 1; }
echo "1B GFTW confirmed on the Safe"

step "3. fund vesting + staking from the Safe (execTransaction, approved-hash sigs)"
safe_exec "$TOKEN" "$(cast calldata 'transfer(address,uint256)' "$STAKING"   180000000000000000000000000)"
safe_exec "$TOKEN" "$(cast calldata 'transfer(address,uint256)' "$VESTING"   30000000000000000000000000)"
echo "staking=$(bal "$STAKING") vesting=$(bal "$VESTING")"

step "4. registration window: holder designates receipt wallet FROM the holding wallet"
warp $((REG_START + 10))
cast send "$REGISTRY" "register(address)" "$RECEIPT" --private-key $CLAIMANT_PK --rpc-url $RPC >/dev/null
[ "$(cast call "$REGISTRY" 'recipientOf(address)(address)' "$CLAIMANT" --rpc-url $RPC)" = "$RECEIPT" ] \
  || { echo "FAIL: registration"; exit 1; }
echo "holder $CLAIMANT registered receipt wallet $RECEIPT (other sample holders stay unregistered)"

step "5. window closed -> export registrations -> join with snapshot -> Merkle tree"
warp $((REG_END + 10))
node snapshot/export-registrations.mjs --registry "$REGISTRY" --from 1 --rpc $RPC \
  --out snapshot/out/registrations.csv | tail -1
node snapshot/build-claims.mjs --balances merkle/sample.csv \
  --registrations snapshot/out/registrations.csv --out snapshot/out/claims.csv | node -pe '
  const s=JSON.parse(require("fs").readFileSync(0));
  `included=${s.holdersIncluded} unregistered=${s.holdersUnregistered} -> claimable ${s.claimableGftwAt5to1} GFTW`'
(cd merkle && node generate.mjs ../snapshot/out/claims.csv --gft-decimals 18 >/dev/null)
ROOT=$(node -pe 'JSON.parse(require("fs").readFileSync("merkle/out/summary.json")).root')
echo "claims tree root: $ROOT"

step "6. deploy + fund migration claim with the pipeline root"
MIGRATION=$(GFTW_ADDRESS=$TOKEN MERKLE_ROOT=$ROOT TREASURY=$SAFE CLAIM_START=$CLAIM_START CLAIM_END=$CLAIM_END run_script DeployMigration)
echo "MigrationClaim: $MIGRATION"
safe_exec "$TOKEN" "$(cast calldata 'transfer(address,uint256)' "$MIGRATION" 50000000000000000000000000)"

step "7. claim pays the RECEIPT wallet, not the holding wallet"
warp $((CLAIM_START + 10))
AMT=$(node -pe 'JSON.parse(require("fs").readFileSync("merkle/out/proofs.json"))["'$RECEIPT'"].amount')
PROOF=$(node -pe 'JSON.stringify(JSON.parse(require("fs").readFileSync("merkle/out/proofs.json"))["'$RECEIPT'"].proof).replaceAll("\"","")')
cast send "$MIGRATION" "claim(address,uint256,bytes32[])" "$RECEIPT" "$AMT" "$PROOF" \
  --private-key $DEPLOYER_PK --rpc-url $RPC >/dev/null   # anyone can relay
[ "$(bal "$RECEIPT")" = "$AMT" ] || { echo "FAIL: claim balance"; exit 1; }
[ "$(bal "$CLAIMANT")" = "0" ] || { echo "FAIL: holding wallet should get nothing"; exit 1; }
echo "claimed $AMT GFTW-wei to receipt wallet (holding wallet untouched)"

step "8. stake claimed tokens, earn one month of emissions"
STAKE_T=$((CLAIM_START + 20))
cast send "$TOKEN" "approve(address,uint256)" "$STAKING" "$AMT" --private-key $RECEIPT_PK --rpc-url $RPC >/dev/null
warp $STAKE_T
cast send "$STAKING" "stake(uint256)" "$AMT" --private-key $RECEIPT_PK --rpc-url $RPC >/dev/null
warp $((STAKE_T + 30 * DAY))
EARNED=$(dec "$(cast call "$STAKING" "earned(address)(uint256)" "$RECEIPT" --rpc-url $RPC)")
node -e 'const e=BigInt(process.argv[1]); if (e < 7400000n*10n**18n || e > 7500001n*10n**18n) { console.error("FAIL: earned out of range", e); process.exit(1);} console.log("earned ~7.5M GFTW after 1 month solo staking:", e)' "$EARNED"
cast send "$STAKING" "claimReward()" --private-key $RECEIPT_PK --rpc-url $RPC >/dev/null
cast send "$STAKING" "exit()" --private-key $RECEIPT_PK --rpc-url $RPC >/dev/null
echo "rewards claimed + principal withdrawn, receipt wallet balance: $(bal "$RECEIPT")"

step "9. vesting release at the 12-month cliff"
warp $((TGE + 360 * DAY))
cast send "$VESTING" "release(address)" "$TOKEN" --private-key $DEPLOYER_PK --rpc-url $RPC >/dev/null  # anyone can trigger
[ "$(bal "$BENEFICIARY")" = "10000000000000000000000000" ] || { echo "FAIL: cliff release"; exit 1; }
echo "beneficiary received exactly 10M GFTW (30M x 12/36) at cliff"

step "10. sweep unclaimed migration to treasury after window"
BEFORE=$(bal "$SAFE")
cast send "$MIGRATION" "sweepUnclaimed()" --private-key $DEPLOYER_PK --rpc-url $RPC >/dev/null
AFTER=$(bal "$SAFE")
node -e 'const [b,a,amt]=process.argv.slice(1).map(BigInt); const got=a-b;
  if (got !== 50000000n*10n**18n - amt) { console.error("FAIL: sweep amount", got); process.exit(1); }
  console.log("swept", got.toString(), "GFTW-wei back to the Safe treasury")' "$BEFORE" "$AFTER" "$AMT"

printf '\n\033[1;32mREHEARSAL PASSED\033[0m — full runbook exercised with zero GUI:\n'
echo "  Safe:      $SAFE"
echo "  GFTW:      $TOKEN"
echo "  Vesting:   $VESTING"
echo "  Registry:  $REGISTRY"
echo "  Migration: $MIGRATION"
echo "  Staking:   $STAKING"

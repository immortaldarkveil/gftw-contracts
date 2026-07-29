#!/usr/bin/env bash
# Predicts the address of a Safe (v1.4.1, canonical factory) BEFORE deployment.
#
# The Safe proxy is deployed via CREATE2:
#   address = keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:]
#   salt    = keccak256(keccak256(initializer) ++ saltNonce)
#   initCode = proxyCreationCode ++ abi.encode(singleton)
#
# The INITIAL owners/threshold/saltNonce fix the address. Owners added or
# removed later (via the Safe itself) do NOT change the address.
#
# Usage:
#   OWNERS=0xabc...,0xdef...,0x123... THRESHOLD=2 SALT_NONCE=20260727 \
#     ./script/compute-safe-address.sh [rpc-url]
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

RPC=${1:-https://bsc-dataseed.binance.org}
SAFE_FACTORY=0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67
SAFE_SINGLETON_L2=0x29fcB43b46531BcA003ddC8FCB67FFE91900C762
SAFE_FALLBACK=0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99

: "${OWNERS:?comma-separated owner addresses}" "${THRESHOLD:?signature threshold}" "${SALT_NONCE:?numeric salt nonce}"

INIT=$(cast calldata "setup(address[],uint256,address,bytes,address,address,uint256,address)" \
  "[$OWNERS]" "$THRESHOLD" 0x0000000000000000000000000000000000000000 0x \
  $SAFE_FALLBACK 0x0000000000000000000000000000000000000000 0 0x0000000000000000000000000000000000000000)

PROXY_CODE=$(cast call $SAFE_FACTORY "proxyCreationCode()(bytes)" --rpc-url "$RPC")
INIT_CODE_HASH=$(cast keccak "$(cast concat-hex "$PROXY_CODE" "$(cast abi-encode 'f(address)' $SAFE_SINGLETON_L2)")")
SALT=$(cast keccak "$(cast concat-hex "$(cast keccak "$INIT")" "$(cast abi-encode 'f(uint256)' "$SALT_NONCE")")")

PREDICTED=$(cast create2 --deployer $SAFE_FACTORY --salt "$SALT" --init-code-hash "$INIT_CODE_HASH" | grep -Eo '0x[a-fA-F0-9]{40}' | head -1)

echo "Predicted Safe address: $PREDICTED"
echo "  owners:    $OWNERS"
echo "  threshold: $THRESHOLD"
echo "  saltNonce: $SALT_NONCE"
echo
echo "Deploy later (exact same inputs) with:"
echo "  cast send $SAFE_FACTORY 'createProxyWithNonce(address,bytes,uint256)' \\"
echo "    $SAFE_SINGLETON_L2 <initializer> $SALT_NONCE --rpc-url <rpc> --ledger"
echo "initializer: $INIT"

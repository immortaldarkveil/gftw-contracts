// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GFTW} from "../src/GFTW.sol";
import {MigrationClaim} from "../src/MigrationClaim.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Proves the JS Merkle generator (merkle/generate.mjs) and the
///         on-chain verifier agree: deploys MigrationClaim with the generated
///         root and executes real claims using the generated proofs.
/// @dev Skips silently when merkle/out/parity.json has not been generated.
///      Run `cd merkle && node generate.mjs <snapshot.csv>` first. With the
///      real snapshot this doubles as the end-to-end claim rehearsal; claim
///      count sampled is capped to keep runtime bounded.
contract MerkleParityTest is Test {
    uint256 internal constant MAX_SAMPLED = 50;

    string internal constant PARITY_PATH = "merkle/out/parity.json";

    function test_GeneratedProofsVerifyOnChain() public {
        if (!vm.isFile(PARITY_PATH)) {
            vm.skip(true);
        }
        string memory json = vm.readFile(PARITY_PATH);
        bytes32 root = vm.parseJsonBytes32(json, ".root");
        uint256 count = vm.parseJsonUint(json, ".count");
        assertGt(count, 0);

        GFTW token = new GFTW(address(this));
        uint64 claimStart = uint64(block.timestamp) + 1;
        uint64 claimEnd = claimStart + 90 days;
        MigrationClaim claimContract =
            new MigrationClaim(IERC20(address(token)), root, address(0xDEAD), claimStart, claimEnd);
        token.transfer(address(claimContract), 130_000_000e18);

        vm.warp(claimStart);
        uint256 sampled = count < MAX_SAMPLED ? count : MAX_SAMPLED;
        // Sample from both ends so the last leaf is always covered.
        for (uint256 i = 0; i < sampled; i++) {
            uint256 idx = i < sampled / 2 ? i : count - (sampled - i);
            string memory base = string.concat(".claims[", vm.toString(idx), "]");
            address account = vm.parseJsonAddress(json, string.concat(base, ".account"));
            uint256 amount = vm.parseJsonUint(json, string.concat(base, ".amount"));
            bytes32[] memory proof = vm.parseJsonBytes32Array(json, string.concat(base, ".proof"));

            uint256 before = token.balanceOf(account);
            claimContract.claim(account, amount, proof);
            assertEq(token.balanceOf(account), before + amount, "claimed amount mismatch");
        }
    }
}

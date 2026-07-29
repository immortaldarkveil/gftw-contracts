// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GFTW} from "../src/GFTW.sol";
import {GFTWVesting} from "../src/GFTWVesting.sol";
import {GFTWStaking} from "../src/GFTWStaking.sol";
import {MigrationRegistry} from "../src/MigrationRegistry.sol";
import {MigrationClaim} from "../src/MigrationClaim.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys the GFTW token. The entire 1B supply goes to DISTRIBUTOR
///         (the distribution multisig) — nothing else to configure, ever.
///
/// Dry run (no transaction sent):
///   DISTRIBUTOR=0x... forge script script/Deploy.s.sol:DeployToken --rpc-url bsc_testnet
/// Broadcast:
///   add --broadcast --verify (and a hardware-wallet signer: --ledger / --trezor)
contract DeployToken is Script {
    function run() external returns (GFTW token) {
        address distributor = vm.envAddress("DISTRIBUTOR");
        require(distributor.code.length > 0, "DISTRIBUTOR is not a contract - must be the multisig");
        // Optional SALT (uint) routes deployment through the canonical CREATE2
        // factory, making the token address knowable before deployment
        // (precompute with ComputeTokenAddress below). Same SALT + same
        // distributor => same address on any chain.
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));

        vm.startBroadcast();
        token = salt == bytes32(0) ? new GFTW(distributor) : new GFTW{salt: salt}(distributor);
        vm.stopBroadcast();

        console.log("GFTW deployed:", address(token));
        console.log("Supply minted to distributor:", distributor);
    }
}

/// @notice Computes the GFTW address for a given DISTRIBUTOR + SALT without
///         deploying anything — run as a pure dry-run (no --broadcast).
///         The address only holds if DeployToken is later run with the SAME
///         distributor and SALT, and the GFTW bytecode is unchanged.
///
/// Env: DISTRIBUTOR, SALT (uint)
contract ComputeTokenAddress is Script {
    function run() external view returns (address predicted) {
        address distributor = vm.envAddress("DISTRIBUTOR");
        bytes32 salt = bytes32(vm.envUint("SALT"));
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(GFTW).creationCode, abi.encode(distributor)));
        predicted = vm.computeCreate2Address(salt, initCodeHash);
        console.log("Predicted GFTW address:", predicted);
        console.log("  distributor:", distributor);
        console.log("  salt:", vm.toString(salt));
        console.log("  NOTE: changes to GFTW.sol or the distributor change this address.");
    }
}

/// @notice Deploys one vesting wallet. Fund it from the distributor multisig
///         after deployment; the schedule applies to whatever it holds.
///
/// Env: BENEFICIARY, TGE_TIMESTAMP (unix), DURATION_MONTHS, CLIFF_MONTHS
/// (months are 30-day months, matching the published schedule).
contract DeployVesting is Script {
    uint64 internal constant MONTH = 30 days;

    function run() external returns (GFTWVesting vesting) {
        address beneficiary = vm.envAddress("BENEFICIARY");
        uint64 start = uint64(vm.envUint("TGE_TIMESTAMP"));
        uint64 durationMonths = uint64(vm.envUint("DURATION_MONTHS"));
        uint64 cliffMonths = uint64(vm.envUint("CLIFF_MONTHS"));
        require(start > block.timestamp - 30 days, "TGE_TIMESTAMP looks stale");
        require(cliffMonths <= durationMonths, "cliff exceeds duration");

        vm.startBroadcast();
        vesting = new GFTWVesting(beneficiary, start, durationMonths * MONTH, cliffMonths * MONTH);
        vm.stopBroadcast();

        console.log("Vesting deployed:", address(vesting));
        console.log("  beneficiary:", beneficiary);
        console.log("  cliff ends:", vesting.cliff());
        console.log("  fully vested:", vesting.end());
    }
}

/// @notice Deploys the migration claim contract. Fund it with the claim-tree total (<=130M GFTW) from
///         the distributor multisig after deployment.
///
/// Env: GFTW_ADDRESS, MERKLE_ROOT (from merkle/out/summary.json),
///      TREASURY (multisig), CLAIM_START, CLAIM_END (unix seconds)
contract DeployMigration is Script {
    function run() external returns (MigrationClaim migration) {
        IERC20 token = IERC20(vm.envAddress("GFTW_ADDRESS"));
        bytes32 root = vm.envBytes32("MERKLE_ROOT");
        address treasury = vm.envAddress("TREASURY");
        uint64 claimStart = uint64(vm.envUint("CLAIM_START"));
        uint64 claimEnd = uint64(vm.envUint("CLAIM_END"));
        require(address(token).code.length > 0, "GFTW_ADDRESS is not a contract");
        require(treasury.code.length > 0, "TREASURY is not a contract - must be the multisig");

        vm.startBroadcast();
        migration = new MigrationClaim(token, root, treasury, claimStart, claimEnd);
        vm.stopBroadcast();

        console.log("MigrationClaim deployed:", address(migration));
        console.log("  root:");
        console.logBytes32(root);
        console.log("  window:", claimStart, "->", claimEnd);
        console.log(
            "  NEXT: transfer the claim-tree total (<=130,000,000 GFTW) from distributor to", address(migration)
        );
    }
}

/// @notice Deploys the staking contract. Fund it with 180M GFTW from the
///         distributor multisig after deployment (rewards are pre-funded,
///         never minted; the emission curve is hardcoded in the contract).
///
/// Env: GFTW_ADDRESS, TREASURY (multisig), TGE_TIMESTAMP (emission start)
contract DeployStaking is Script {
    function run() external returns (GFTWStaking staking) {
        IERC20 token = IERC20(vm.envAddress("GFTW_ADDRESS"));
        address treasury = vm.envAddress("TREASURY");
        uint64 start = uint64(vm.envUint("TGE_TIMESTAMP"));
        require(address(token).code.length > 0, "GFTW_ADDRESS is not a contract");
        require(treasury.code.length > 0, "TREASURY is not a contract - must be the multisig");
        require(start > block.timestamp - 30 days, "TGE_TIMESTAMP looks stale");

        vm.startBroadcast();
        staking = new GFTWStaking(token, treasury, start);
        vm.stopBroadcast();

        console.log("GFTWStaking deployed:", address(staking));
        console.log("  emissions:", staking.emissionsStart(), "->", staking.emissionsEnd());
        console.log("  NEXT: transfer 180,000,000 GFTW from distributor to", address(staking));
    }
}

/// @notice Deploys the migration registry, where snapshot holders designate
///         their receipt wallet (directly or via relayed EIP-712 signature)
///         during a fixed window. Deploy BEFORE MigrationClaim: the claim
///         contract's Merkle root is built from registrations + snapshot.
///
/// Env: REGISTRATION_START, REGISTRATION_END (unix seconds)
contract DeployRegistry is Script {
    function run() external returns (MigrationRegistry registry) {
        uint64 regStart = uint64(vm.envUint("REGISTRATION_START"));
        uint64 regEnd = uint64(vm.envUint("REGISTRATION_END"));

        vm.startBroadcast();
        registry = new MigrationRegistry(regStart, regEnd);
        vm.stopBroadcast();

        console.log("MigrationRegistry deployed:", address(registry));
        console.log("  window:", regStart, "->", regEnd);
        console.log(
            "  NEXT after window closes: export-registrations.mjs -> build-claims.mjs -> generate.mjs -> DeployMigration"
        );
    }
}

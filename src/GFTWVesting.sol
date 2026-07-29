// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletCliff} from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";

/// @title GFTWVesting
/// @notice Cliff + linear vesting wallet for GFTW allocations (team, investors,
///         advisors, treasury). One instance is deployed per beneficiary.
/// @dev Thin concrete wrapper over OpenZeppelin's audited {VestingWallet} +
///      {VestingWalletCliff}. All schedule parameters are immutable at
///      deployment and the contract is non-revocable: no address — deployer,
///      multisig, or otherwise — can claw back, pause, or reschedule tokens
///      once they are deposited. Vesting is linear from `start` to
///      `start + duration`, with nothing releasable before `start + cliff`.
///
///      Published schedules (start = TGE):
///        - Team:               cliff 12 months, duration 36 months
///        - Investors/advisors: cliff  6 months, duration 24 months
///        - Treasury:           cliff  0,        duration 36 months
///
///      `release(token)` is callable by anyone; proceeds always go to the
///      beneficiary (the wallet owner).
contract GFTWVesting is VestingWalletCliff {
    /// @param beneficiary Recipient of vested tokens (owner of this wallet).
    /// @param startTimestamp Vesting start (TGE), unix seconds.
    /// @param durationSeconds Total vesting duration from start, in seconds.
    /// @param cliffSeconds Cliff length from start, in seconds; nothing is
    ///        releasable before `startTimestamp + cliffSeconds`.
    constructor(address beneficiary, uint64 startTimestamp, uint64 durationSeconds, uint64 cliffSeconds)
        VestingWallet(beneficiary, startTimestamp, durationSeconds)
        VestingWalletCliff(cliffSeconds)
    {}
}

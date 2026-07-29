// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Giftworld (GFTW)
/// @notice Fixed-supply BEP-20 token for GiftoV3 on BNB Smart Chain.
/// @dev Deliberately minimal. The entire 1,000,000,000 supply is minted once in
///      the constructor and can never be increased:
///        - no mint function exists in the bytecode after deployment;
///        - no owner, admin, or privileged role of any kind;
///        - no pause, no blacklist, no fee-on-transfer, no hooks;
///        - not upgradeable — this contract is immutable once deployed.
///      All allocations (creator reserve, community, treasury, migration,
///      insiders, public sale, liquidity) are distributed from the pre-minted
///      supply via separate contracts that hold no authority over this one.
contract GFTW is ERC20 {
    /// @notice Fixed total supply: 1,000,000,000 GFTW with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @dev The distributor address is zero.
    error ZeroDistributor();

    /// @param distributor Address receiving the entire supply at deployment
    ///        (the distribution multisig, which then funds vesting, migration,
    ///        liquidity, and treasury contracts).
    constructor(address distributor) ERC20("Giftworld", "GFTW") {
        if (distributor == address(0)) revert ZeroDistributor();
        _mint(distributor, TOTAL_SUPPLY);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GFTW} from "../src/GFTW.sol";
import {GFTWVesting} from "../src/GFTWVesting.sol";
import {VestingWalletCliff} from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";

contract GFTWVestingTest is Test {
    uint64 internal constant MONTH = 30 days;
    uint64 internal constant TEAM_CLIFF = 12 * MONTH;
    uint64 internal constant TEAM_DURATION = 36 * MONTH;
    uint256 internal constant TEAM_ALLOCATION = 30_000_000e18; // ~3% of supply

    GFTW internal token;
    GFTWVesting internal vesting;
    address internal beneficiary = makeAddr("beneficiary");
    uint64 internal start;

    function setUp() public {
        start = uint64(block.timestamp) + 7 days; // TGE a week out
        token = new GFTW(address(this));
        vesting = new GFTWVesting(beneficiary, start, TEAM_DURATION, TEAM_CLIFF);
        token.transfer(address(vesting), TEAM_ALLOCATION);
    }

    // --------------------------------------------------------------- config

    function test_Parameters() public view {
        assertEq(vesting.owner(), beneficiary);
        assertEq(vesting.start(), start);
        assertEq(vesting.duration(), TEAM_DURATION);
        assertEq(vesting.end(), uint256(start) + TEAM_DURATION);
        assertEq(vesting.cliff(), uint256(start) + TEAM_CLIFF);
    }

    function test_RevertWhen_CliffLongerThanDuration() public {
        vm.expectRevert(
            abi.encodeWithSelector(VestingWalletCliff.InvalidCliffDuration.selector, TEAM_DURATION + 1, TEAM_DURATION)
        );
        new GFTWVesting(beneficiary, start, TEAM_DURATION, TEAM_DURATION + 1);
    }

    // ------------------------------------------------------------- schedule

    function testFuzz_NothingReleasableBeforeCliff(uint64 t) public {
        t = uint64(bound(t, 0, uint256(start) + TEAM_CLIFF - 1));
        vm.warp(t);
        assertEq(vesting.releasable(address(token)), 0);
    }

    function test_CliffUnlocksProportionalAmount() public {
        vm.warp(uint256(start) + TEAM_CLIFF);
        // 12 of 36 months elapsed -> exactly one third vested
        assertEq(vesting.releasable(address(token)), TEAM_ALLOCATION / 3);
    }

    function testFuzz_LinearBetweenCliffAndEnd(uint64 t) public {
        t = uint64(bound(t, uint256(start) + TEAM_CLIFF, uint256(start) + TEAM_DURATION));
        vm.warp(t);
        uint256 expected = (TEAM_ALLOCATION * (t - start)) / TEAM_DURATION;
        assertEq(vesting.releasable(address(token)), expected);
    }

    function testFuzz_FullyVestedAfterEnd(uint64 extra) public {
        extra = uint64(bound(extra, 0, 3650 days));
        vm.warp(uint256(start) + TEAM_DURATION + extra);
        assertEq(vesting.releasable(address(token)), TEAM_ALLOCATION);
    }

    // -------------------------------------------------------------- release

    function test_ReleaseTransfersToBeneficiary_CallableByAnyone() public {
        vm.warp(uint256(start) + TEAM_CLIFF);
        vm.prank(makeAddr("randomCaller"));
        vesting.release(address(token));

        assertEq(token.balanceOf(beneficiary), TEAM_ALLOCATION / 3);
        assertEq(vesting.released(address(token)), TEAM_ALLOCATION / 3);
    }

    function test_ReleaseIsIncremental() public {
        vm.warp(uint256(start) + TEAM_CLIFF);
        vesting.release(address(token));
        uint256 afterCliff = token.balanceOf(beneficiary);

        vm.warp(uint256(start) + TEAM_DURATION);
        vesting.release(address(token));

        assertEq(token.balanceOf(beneficiary), TEAM_ALLOCATION);
        assertGt(TEAM_ALLOCATION, afterCliff);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function testFuzz_ReleasedNeverExceedsAllocation(uint64 t1, uint64 t2) public {
        t1 = uint64(bound(t1, block.timestamp, uint256(start) + TEAM_DURATION + 365 days));
        t2 = uint64(bound(t2, t1, uint256(start) + TEAM_DURATION + 730 days));

        vm.warp(t1);
        vesting.release(address(token));
        vm.warp(t2);
        vesting.release(address(token));

        assertLe(token.balanceOf(beneficiary), TEAM_ALLOCATION);
        assertEq(token.balanceOf(beneficiary) + token.balanceOf(address(vesting)), TEAM_ALLOCATION);
    }

    // ------------------------------------------- investor schedule (6 + 24)

    function test_InvestorSchedule() public {
        uint64 cliff = 6 * MONTH;
        uint64 duration = 24 * MONTH;
        uint256 allocation = 20_000_000e18; // ~2% of supply
        GFTWVesting investor = new GFTWVesting(beneficiary, start, duration, cliff);
        token.transfer(address(investor), allocation);

        vm.warp(uint256(start) + cliff - 1);
        assertEq(investor.releasable(address(token)), 0);

        vm.warp(uint256(start) + cliff);
        assertEq(investor.releasable(address(token)), allocation / 4); // 6/24

        vm.warp(uint256(start) + duration);
        assertEq(investor.releasable(address(token)), allocation);
    }
}

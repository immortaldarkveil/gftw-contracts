// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GFTW} from "../src/GFTW.sol";
import {GFTWStaking} from "../src/GFTWStaking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GFTWStakingTest is Test {
    uint256 internal constant YEAR = 360 days;
    uint256 internal constant MONTH = 30 days;
    uint256 internal constant POOL = 180_000_000e18;

    GFTW internal token;
    GFTWStaking internal staking;
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint64 internal start;

    function setUp() public {
        start = uint64(block.timestamp) + 7 days;
        token = new GFTW(address(this));
        staking = new GFTWStaking(IERC20(address(token)), treasury, start);
        // pre-fund rewards; never minted
        token.transfer(address(staking), POOL);
        // give the stakers balances
        token.transfer(alice, 10_000_000e18);
        token.transfer(bob, 10_000_000e18);
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);
    }

    // ---------------------------------------------------------------- config

    function test_Parameters() public view {
        assertEq(address(staking.token()), address(token));
        assertEq(staking.treasury(), treasury);
        assertEq(staking.emissionsStart(), start);
        assertEq(staking.emissionsEnd(), start + 3 * YEAR);
    }

    function test_RevertWhen_ZeroParams() public {
        vm.expectRevert(GFTWStaking.ZeroParameter.selector);
        new GFTWStaking(IERC20(address(0)), treasury, start);
        vm.expectRevert(GFTWStaking.ZeroParameter.selector);
        new GFTWStaking(IERC20(address(token)), address(0), start);
        vm.expectRevert(GFTWStaking.ZeroParameter.selector);
        new GFTWStaking(IERC20(address(token)), treasury, 0);
    }

    // -------------------------------------------------------- emission curve

    function test_CurveHitsPublishedTotalsExactly() public view {
        assertEq(staking.cumulativeEmitted(start), 0);
        assertEq(staking.cumulativeEmitted(start + MONTH), 7_500_000e18);
        assertEq(staking.cumulativeEmitted(start + YEAR), 90_000_000e18);
        assertEq(staking.cumulativeEmitted(start + YEAR + MONTH), 94_500_000e18);
        assertEq(staking.cumulativeEmitted(start + 2 * YEAR), 144_000_000e18);
        assertEq(staking.cumulativeEmitted(start + 2 * YEAR + MONTH), 147_000_000e18);
        assertEq(staking.cumulativeEmitted(start + 3 * YEAR), 180_000_000e18);
        assertEq(staking.cumulativeEmitted(start + 10 * YEAR), 180_000_000e18);
        assertEq(staking.cumulativeEmitted(start - 1 days), 0);
    }

    function testFuzz_CurveIsMonotonic(uint64 t1, uint64 t2) public view {
        t1 = uint64(bound(t1, 0, start + 4 * YEAR));
        t2 = uint64(bound(t2, t1, start + 4 * YEAR));
        assertLe(staking.cumulativeEmitted(t1), staking.cumulativeEmitted(t2));
        assertLe(staking.cumulativeEmitted(t2), POOL);
    }

    function test_RatePerSecond() public {
        vm.warp(start - 1);
        assertEq(staking.currentRatePerSecond(), 0);
        vm.warp(start);
        assertEq(staking.currentRatePerSecond(), 90_000_000e18 / YEAR);
        vm.warp(start + YEAR);
        assertEq(staking.currentRatePerSecond(), 54_000_000e18 / YEAR);
        vm.warp(start + 2 * YEAR);
        assertEq(staking.currentRatePerSecond(), 36_000_000e18 / YEAR);
        vm.warp(start + 3 * YEAR);
        assertEq(staking.currentRatePerSecond(), 0);
    }

    // ------------------------------------------------------- earning & claims

    function test_SoloStakerEarnsAllEmissions() public {
        vm.prank(alice);
        staking.stake(1_000_000e18);

        vm.warp(start + 3 * YEAR);
        assertEq(staking.earned(alice), POOL);

        vm.prank(alice);
        staking.exit();
        assertEq(token.balanceOf(alice), 10_000_000e18 + POOL);
        assertEq(staking.totalStaked(), 0);
    }

    function test_EqualStakersSplitEqually() public {
        vm.warp(start);
        vm.prank(alice);
        staking.stake(500_000e18);
        vm.prank(bob);
        staking.stake(500_000e18);

        vm.warp(start + YEAR);
        // year-1 emissions split 50/50 (allow 1 wei accumulator dust)
        assertApproxEqAbs(staking.earned(alice), 45_000_000e18, 1e6);
        assertApproxEqAbs(staking.earned(bob), 45_000_000e18, 1e6);
    }

    function test_WeightedSplitAcrossJoin() public {
        // alice alone for month 1, then bob joins with 3x stake
        vm.warp(start);
        vm.prank(alice);
        staking.stake(100e18);

        vm.warp(start + MONTH);
        vm.prank(bob);
        staking.stake(300e18);

        vm.warp(start + 2 * MONTH);
        // month 1: alice 7.5M; month 2: alice 1/4, bob 3/4 of 7.5M
        assertApproxEqAbs(staking.earned(alice), 7_500_000e18 + 1_875_000e18, 1e6);
        assertApproxEqAbs(staking.earned(bob), 5_625_000e18, 1e6);
    }

    function test_ClaimPaysAndResets() public {
        vm.prank(alice);
        staking.stake(1e18);
        vm.warp(start + MONTH);

        vm.prank(alice);
        staking.claimReward();
        assertApproxEqAbs(token.balanceOf(alice), 10_000_000e18 - 1e18 + 7_500_000e18, 1);
        assertEq(staking.earned(alice), 0);

        // principal untouched
        assertEq(staking.staked(alice), 1e18);
    }

    function test_NoEmissionsBeforeStartOrAfterEnd() public {
        vm.prank(alice);
        staking.stake(1e18); // before start
        vm.warp(start - 1);
        assertEq(staking.earned(alice), 0);

        vm.warp(start + 3 * YEAR + 500 days);
        assertEq(staking.earned(alice), POOL);
    }

    function testFuzz_TotalPaidNeverExceedsEmitted(uint64 tA, uint64 tB, uint96 stakeA, uint96 stakeB) public {
        stakeA = uint96(bound(stakeA, 1, 10_000_000e18));
        stakeB = uint96(bound(stakeB, 1, 10_000_000e18));
        tA = uint64(bound(tA, start, start + 3 * YEAR));
        tB = uint64(bound(tB, tA, start + 4 * YEAR));

        vm.prank(alice);
        staking.stake(stakeA);

        vm.warp(tA);
        vm.prank(bob);
        staking.stake(stakeB);

        vm.warp(tB);
        vm.prank(alice);
        staking.exit();
        vm.prank(bob);
        staking.exit();

        uint256 paid = staking.rewardsPaid();
        assertLe(paid, staking.cumulativeEmitted(tB));
        assertLe(paid, POOL);
        // pool balance covers what's left
        assertGe(token.balanceOf(address(staking)), 0);
        assertEq(staking.totalStaked(), 0);
    }

    // -------------------------------------------------------------- withdraw

    function test_WithdrawPartial() public {
        vm.prank(alice);
        staking.stake(100e18);
        vm.prank(alice);
        staking.withdraw(40e18);
        assertEq(staking.staked(alice), 60e18);
        assertEq(staking.totalStaked(), 60e18);
    }

    function test_RevertWhen_WithdrawTooMuch() public {
        vm.prank(alice);
        staking.stake(100e18);
        vm.prank(alice);
        vm.expectRevert(GFTWStaking.InsufficientStake.selector);
        staking.withdraw(101e18);
    }

    function test_RevertWhen_ZeroAmounts() public {
        vm.expectRevert(GFTWStaking.ZeroAmount.selector);
        staking.stake(0);
        vm.expectRevert(GFTWStaking.ZeroAmount.selector);
        staking.withdraw(0);
    }

    // ----------------------------------------------------------------- sweep

    function test_ZeroStakerGapIsUndistributableAndSweepable() public {
        // nobody staked during year 1; alice stakes for years 2-3
        vm.warp(start + YEAR);
        vm.prank(alice);
        staking.stake(1e18);

        vm.warp(start + 3 * YEAR);
        assertEq(staking.earned(alice), 90_000_000e18); // years 2+3 only

        vm.warp(start + 3 * YEAR + 1);
        staking.sweepUndistributed();
        assertEq(token.balanceOf(treasury), 90_000_000e18); // year 1 leftovers

        // alice can still exit fully after the sweep
        vm.prank(alice);
        staking.exit();
        assertEq(token.balanceOf(alice), 10_000_000e18 + 90_000_000e18);
    }

    function test_RevertWhen_SweepBeforeEnd() public {
        vm.warp(start + 3 * YEAR);
        vm.expectRevert(GFTWStaking.EmissionsNotEnded.selector);
        staking.sweepUndistributed();
    }

    function test_SweepNeverTouchesPrincipalOrAccrued() public {
        vm.warp(start + 2 * YEAR); // year-1+2 emissions undistributable
        vm.prank(alice);
        staking.stake(5e18);

        vm.warp(start + 3 * YEAR + 1);
        staking.sweepUndistributed();

        // principal + alice's unclaimed year-3 rewards remain
        assertEq(token.balanceOf(address(staking)), 5e18 + 36_000_000e18);
        vm.prank(alice);
        staking.exit();
        assertEq(token.balanceOf(alice), 10_000_000e18 + 36_000_000e18);
        assertEq(token.balanceOf(address(staking)), 0);
    }

    function test_SweepTwiceIsNoop() public {
        vm.warp(start + 3 * YEAR + 1);
        staking.sweepUndistributed();
        uint256 t = token.balanceOf(treasury);
        staking.sweepUndistributed();
        assertEq(token.balanceOf(treasury), t);
    }
}

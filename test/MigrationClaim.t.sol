// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GFTW} from "../src/GFTW.sol";
import {MigrationClaim} from "../src/MigrationClaim.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MigrationClaimTest is Test {
    uint256 internal constant MIGRATION_POOL = 130_000_000e18;

    GFTW internal token;
    MigrationClaim internal claimContract;
    address internal treasury = makeAddr("treasury");

    // 4-leaf snapshot fixture (amounts already converted 5 GFT : 1 GFTW)
    address[4] internal accounts;
    uint256[4] internal amounts;
    bytes32[4] internal leaves;
    bytes32 internal n01;
    bytes32 internal n23;
    bytes32 internal root;

    uint64 internal claimStart;
    uint64 internal claimEnd;

    function setUp() public {
        token = new GFTW(address(this));

        accounts = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol"), makeAddr("dave")];
        amounts = [uint256(1_000_000e18), 250_000e18, 42e18, 1];

        for (uint256 i = 0; i < 4; i++) {
            leaves[i] = _leaf(accounts[i], amounts[i]);
        }
        n01 = _hashPair(leaves[0], leaves[1]);
        n23 = _hashPair(leaves[2], leaves[3]);
        root = _hashPair(n01, n23);

        claimStart = uint64(block.timestamp) + 1 days;
        claimEnd = claimStart + 90 days;

        claimContract = new MigrationClaim(IERC20(address(token)), root, treasury, claimStart, claimEnd);
        token.transfer(address(claimContract), MIGRATION_POOL);
    }

    // -------------------------------------------------------- merkle helpers

    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proofFor(uint256 i) internal view returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        if (i == 0) (proof[0], proof[1]) = (leaves[1], n23);
        else if (i == 1) (proof[0], proof[1]) = (leaves[0], n23);
        else if (i == 2) (proof[0], proof[1]) = (leaves[3], n01);
        else (proof[0], proof[1]) = (leaves[2], n01);
    }

    // ----------------------------------------------------------- constructor

    function test_Parameters() public view {
        assertEq(address(claimContract.token()), address(token));
        assertEq(claimContract.merkleRoot(), root);
        assertEq(claimContract.treasury(), treasury);
        assertEq(claimContract.claimStart(), claimStart);
        assertEq(claimContract.claimEnd(), claimEnd);
    }

    function test_RevertWhen_ZeroParameters() public {
        vm.expectRevert(MigrationClaim.ZeroParameter.selector);
        new MigrationClaim(IERC20(address(0)), root, treasury, claimStart, claimEnd);
        vm.expectRevert(MigrationClaim.ZeroParameter.selector);
        new MigrationClaim(IERC20(address(token)), bytes32(0), treasury, claimStart, claimEnd);
        vm.expectRevert(MigrationClaim.ZeroParameter.selector);
        new MigrationClaim(IERC20(address(token)), root, address(0), claimStart, claimEnd);
    }

    function test_RevertWhen_WindowInvalid() public {
        vm.expectRevert(MigrationClaim.InvalidWindow.selector);
        new MigrationClaim(IERC20(address(token)), root, treasury, claimEnd, claimStart);
        vm.warp(claimEnd + 1);
        vm.expectRevert(MigrationClaim.InvalidWindow.selector);
        new MigrationClaim(IERC20(address(token)), root, treasury, claimStart, claimEnd);
    }

    // ----------------------------------------------------------------- claim

    function test_ClaimWithinWindow() public {
        vm.warp(claimStart);
        vm.expectEmit(true, false, false, true);
        emit MigrationClaim.Claimed(accounts[0], amounts[0]);
        claimContract.claim(accounts[0], amounts[0], _proofFor(0));

        assertEq(token.balanceOf(accounts[0]), amounts[0]);
        assertTrue(claimContract.claimed(accounts[0]));
    }

    function test_AllFourClaimants() public {
        vm.warp(claimStart + 1 days);
        uint256 total;
        for (uint256 i = 0; i < 4; i++) {
            claimContract.claim(accounts[i], amounts[i], _proofFor(i));
            assertEq(token.balanceOf(accounts[i]), amounts[i]);
            total += amounts[i];
        }
        assertEq(token.balanceOf(address(claimContract)), MIGRATION_POOL - total);
    }

    /// @dev Tokens go to the snapshot account even when a third party calls.
    function test_ThirdPartyClaimSendsToSnapshotAccount() public {
        vm.warp(claimStart);
        vm.prank(makeAddr("relayer"));
        claimContract.claim(accounts[2], amounts[2], _proofFor(2));
        assertEq(token.balanceOf(accounts[2]), amounts[2]);
        assertEq(token.balanceOf(makeAddr("relayer")), 0);
    }

    function test_RevertWhen_ClaimBeforeWindow() public {
        vm.warp(claimStart - 1);
        vm.expectRevert(MigrationClaim.WindowClosed.selector);
        claimContract.claim(accounts[0], amounts[0], _proofFor(0));
    }

    function test_RevertWhen_ClaimAfterWindow() public {
        vm.warp(uint256(claimEnd) + 1);
        vm.expectRevert(MigrationClaim.WindowClosed.selector);
        claimContract.claim(accounts[0], amounts[0], _proofFor(0));
    }

    function test_ClaimAtExactBoundaries() public {
        vm.warp(claimStart);
        claimContract.claim(accounts[0], amounts[0], _proofFor(0));
        vm.warp(claimEnd);
        claimContract.claim(accounts[1], amounts[1], _proofFor(1));
    }

    function test_RevertWhen_DoubleClaim() public {
        vm.warp(claimStart);
        claimContract.claim(accounts[0], amounts[0], _proofFor(0));
        vm.expectRevert(abi.encodeWithSelector(MigrationClaim.AlreadyClaimed.selector, accounts[0]));
        claimContract.claim(accounts[0], amounts[0], _proofFor(0));
    }

    function test_RevertWhen_WrongAmount() public {
        vm.warp(claimStart);
        vm.expectRevert(MigrationClaim.InvalidProof.selector);
        claimContract.claim(accounts[0], amounts[0] + 1, _proofFor(0));
    }

    function testFuzz_RevertWhen_NotInTree(address account, uint256 amount) public {
        vm.warp(claimStart);
        for (uint256 i = 0; i < 4; i++) {
            vm.assume(!(account == accounts[i] && amount == amounts[i]));
        }
        vm.expectRevert(MigrationClaim.InvalidProof.selector);
        claimContract.claim(account, amount, _proofFor(0));
    }

    function testFuzz_RevertWhen_ForgedProof(bytes32 a, bytes32 b) public {
        vm.warp(claimStart);
        bytes32[] memory proof = new bytes32[](2);
        (proof[0], proof[1]) = (a, b);
        vm.assume(a != leaves[1] || b != n23);
        vm.expectRevert(MigrationClaim.InvalidProof.selector);
        claimContract.claim(accounts[0], amounts[0], proof);
    }

    // ----------------------------------------------------------------- sweep

    function test_RevertWhen_SweepBeforeWindowCloses() public {
        vm.warp(claimEnd); // still inside window (inclusive)
        vm.expectRevert(MigrationClaim.WindowNotClosed.selector);
        claimContract.sweepUnclaimed();
    }

    function test_SweepAfterWindow_SendsRemainderToTreasury() public {
        vm.warp(claimStart);
        claimContract.claim(accounts[0], amounts[0], _proofFor(0));

        vm.warp(uint256(claimEnd) + 1);
        uint256 remainder = MIGRATION_POOL - amounts[0];
        vm.expectEmit(true, false, false, true);
        emit MigrationClaim.UnclaimedSwept(treasury, remainder);
        vm.prank(makeAddr("anyone"));
        claimContract.sweepUnclaimed();

        assertEq(token.balanceOf(treasury), remainder);
        assertEq(token.balanceOf(address(claimContract)), 0);
    }

    function test_ClaimImpossibleAfterSweep() public {
        vm.warp(uint256(claimEnd) + 1);
        claimContract.sweepUnclaimed();
        vm.expectRevert(MigrationClaim.WindowClosed.selector);
        claimContract.claim(accounts[0], amounts[0], _proofFor(0));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GFTW} from "../src/GFTW.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract GFTWTest is Test {
    GFTW internal token;
    address internal distributor = makeAddr("distributor");

    function setUp() public {
        token = new GFTW(distributor);
    }

    // ---------------------------------------------------------------- deploy

    function test_Metadata() public view {
        assertEq(token.name(), "Giftworld");
        assertEq(token.symbol(), "GFTW");
        assertEq(token.decimals(), 18);
    }

    function test_FixedSupplyMintedToDistributor() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000e18);
        assertEq(token.balanceOf(distributor), 1_000_000_000e18);
    }

    function test_RevertWhen_DistributorIsZero() public {
        vm.expectRevert(GFTW.ZeroDistributor.selector);
        new GFTW(address(0));
    }

    /// @dev No mint function exists in the ABI/bytecode; a call to a mint
    ///      selector must hit the fallback-less contract and revert.
    function test_NoMintFunctionInBytecode() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", distributor, 1));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("mint(uint256)", 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    /// @dev No admin surface: common privileged selectors must not exist.
    function test_NoPrivilegedFunctions() public {
        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeWithSignature("owner()");
        calls[1] = abi.encodeWithSignature("pause()");
        calls[2] = abi.encodeWithSignature("blacklist(address)", distributor);
        calls[3] = abi.encodeWithSignature("setFee(uint256)", 1);
        calls[4] = abi.encodeWithSignature("upgradeTo(address)", address(this));
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
    }

    // ------------------------------------------------------------- transfers

    function testFuzz_Transfer(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != distributor);
        amount = bound(amount, 0, token.totalSupply());

        vm.prank(distributor);
        assertTrue(token.transfer(to, amount));

        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(distributor), token.totalSupply() - amount);
    }

    function testFuzz_TransferFrom(address spender, address to, uint256 allowance_, uint256 amount) public {
        vm.assume(to != address(0) && to != distributor);
        vm.assume(spender != address(0) && spender != distributor && spender != to);
        allowance_ = bound(allowance_, 0, token.totalSupply());
        amount = bound(amount, 0, allowance_);

        vm.prank(distributor);
        token.approve(spender, allowance_);

        vm.prank(spender);
        assertTrue(token.transferFrom(distributor, to, amount));

        assertEq(token.balanceOf(to), amount);
        assertEq(token.allowance(distributor, spender), allowance_ - amount);
    }

    function testFuzz_RevertWhen_TransferExceedsBalance(uint256 amount) public {
        uint256 supply = token.totalSupply();
        amount = bound(amount, 1, type(uint256).max - supply);
        vm.prank(distributor);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, distributor, supply, supply + amount)
        );
        token.transfer(address(0xBEEF), supply + amount);
    }

    function test_RevertWhen_TransferToZero() public {
        vm.prank(distributor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    /// @dev Supply is constant under any sequence of transfers.
    function testFuzz_TotalSupplyInvariant(address a, address b, uint256 x) public {
        vm.assume(a != address(0) && b != address(0));
        x = bound(x, 0, token.totalSupply());
        vm.prank(distributor);
        token.transfer(a, x);
        vm.prank(a);
        token.transfer(b, x / 2);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }
}

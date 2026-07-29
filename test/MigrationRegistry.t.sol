// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MigrationRegistry} from "../src/MigrationRegistry.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @dev Minimal ERC-1271 wallet: approves signatures made by its owner key.
contract Wallet1271 is IERC1271 {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (bytes32 r, bytes32 s, uint8 v) = abi.decode(signature, (bytes32, bytes32, uint8));
        return ecrecover(hash, v, r, s) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract MigrationRegistryTest is Test {
    MigrationRegistry internal registry;
    uint64 internal start;
    uint64 internal end;

    address internal holder;
    uint256 internal holderPk;
    address internal recipient = makeAddr("recipient");

    bytes32 internal constant REGISTER_TYPEHASH = keccak256("Register(address holder,address recipient,uint256 nonce)");

    function setUp() public {
        (holder, holderPk) = makeAddrAndKey("holder");
        start = uint64(block.timestamp) + 1 days;
        end = start + 60 days;
        registry = new MigrationRegistry(start, end);
    }

    function _sign(uint256 pk, address holder_, address recipient_, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                registry.domainSeparator(),
                keccak256(abi.encode(REGISTER_TYPEHASH, holder_, recipient_, nonce))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------- window

    function test_RevertWhen_WindowInvalid() public {
        vm.expectRevert(MigrationRegistry.InvalidWindow.selector);
        new MigrationRegistry(end, start);
        vm.warp(end + 1);
        vm.expectRevert(MigrationRegistry.InvalidWindow.selector);
        new MigrationRegistry(start, end);
    }

    function test_RevertWhen_RegisterOutsideWindow() public {
        vm.warp(start - 1);
        vm.prank(holder);
        vm.expectRevert(MigrationRegistry.WindowClosed.selector);
        registry.register(recipient);

        vm.warp(uint256(end) + 1);
        vm.prank(holder);
        vm.expectRevert(MigrationRegistry.WindowClosed.selector);
        registry.register(recipient);
    }

    function test_RegisterAtExactBoundaries() public {
        vm.warp(start);
        vm.prank(holder);
        registry.register(recipient);
        vm.warp(end);
        vm.prank(holder);
        registry.register(makeAddr("recipient2"));
    }

    // -------------------------------------------------------------- register

    function test_RegisterFromHoldingWallet() public {
        vm.warp(start);
        vm.expectEmit(true, true, false, true);
        emit MigrationRegistry.Registered(holder, recipient, false);
        vm.prank(holder);
        registry.register(recipient);
        assertEq(registry.recipientOf(holder), recipient);
    }

    function test_ReRegisterLastWins() public {
        vm.warp(start);
        address second = makeAddr("second");
        vm.startPrank(holder);
        registry.register(recipient);
        registry.register(second);
        vm.stopPrank();
        assertEq(registry.recipientOf(holder), second);
    }

    function test_RevertWhen_ZeroRecipient() public {
        vm.warp(start);
        vm.prank(holder);
        vm.expectRevert(MigrationRegistry.ZeroRecipient.selector);
        registry.register(address(0));
    }

    function testFuzz_RegistrationsAreIndependent(address h1, address h2, address r1, address r2) public {
        vm.assume(h1 != h2 && r1 != address(0) && r2 != address(0));
        vm.warp(start);
        vm.prank(h1);
        registry.register(r1);
        vm.prank(h2);
        registry.register(r2);
        assertEq(registry.recipientOf(h1), r1);
        assertEq(registry.recipientOf(h2), r2);
    }

    // ------------------------------------------------------ signature relay

    function test_RegisterWithSig_RelayedByAnyone() public {
        vm.warp(start);
        bytes memory sig = _sign(holderPk, holder, recipient, 0);
        vm.expectEmit(true, true, false, true);
        emit MigrationRegistry.Registered(holder, recipient, true);
        vm.prank(makeAddr("platformRelayer"));
        registry.registerWithSig(holder, recipient, sig);
        assertEq(registry.recipientOf(holder), recipient);
        assertEq(registry.nonces(holder), 1);
    }

    function test_RevertWhen_SigReplayed() public {
        vm.warp(start);
        bytes memory sig = _sign(holderPk, holder, recipient, 0);
        registry.registerWithSig(holder, recipient, sig);
        vm.expectRevert(MigrationRegistry.InvalidSignature.selector);
        registry.registerWithSig(holder, recipient, sig);
    }

    /// @dev A stale signature cannot roll back a newer registration.
    function test_StaleSigCannotOverrideNewerRegistration() public {
        vm.warp(start);
        bytes memory staleSig = _sign(holderPk, holder, makeAddr("attackerChoice"), 0);
        vm.prank(holder);
        registry.register(recipient); // direct registration does not consume nonce 0
        registry.registerWithSig(holder, makeAddr("attackerChoice"), staleSig);
        // holder re-registers directly; nonce 1 sigs are now required
        vm.prank(holder);
        registry.register(recipient);
        vm.expectRevert(MigrationRegistry.InvalidSignature.selector);
        registry.registerWithSig(holder, makeAddr("attackerChoice"), staleSig);
        assertEq(registry.recipientOf(holder), recipient);
    }

    function test_RevertWhen_WrongSigner() public {
        vm.warp(start);
        (, uint256 otherPk) = makeAddrAndKey("other");
        bytes memory sig = _sign(otherPk, holder, recipient, 0);
        vm.expectRevert(MigrationRegistry.InvalidSignature.selector);
        registry.registerWithSig(holder, recipient, sig);
    }

    function test_RevertWhen_SigForDifferentRecipient() public {
        vm.warp(start);
        bytes memory sig = _sign(holderPk, holder, recipient, 0);
        vm.expectRevert(MigrationRegistry.InvalidSignature.selector);
        registry.registerWithSig(holder, makeAddr("evil"), sig);
    }

    // --------------------------------------------------------------- erc1271

    function test_ContractWalletViaERC1271() public {
        (address signer, uint256 signerPk) = makeAddrAndKey("walletOwner");
        Wallet1271 wallet = new Wallet1271(signer);

        vm.warp(start);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                registry.domainSeparator(),
                keccak256(abi.encode(REGISTER_TYPEHASH, address(wallet), recipient, uint256(0)))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        registry.registerWithSig(address(wallet), recipient, abi.encode(r, s, v));
        assertEq(registry.recipientOf(address(wallet)), recipient);
    }
}

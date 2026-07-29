// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title MigrationRegistry
/// @notice Registration step for the GFT -> GFTW migration. Snapshot holders
///         designate the wallet that should receive their GFTW ("receipt
///         wallet") by proving control of the snapshot wallet — either by
///         calling {register} from it directly, or by signing an EIP-712
///         message that anyone (e.g. the platform) can relay via
///         {registerWithSig} so holders without BNB for gas are not excluded.
/// @dev Ownerless and immutable, consistent with the rest of the system:
///        - the registration window is fixed at deployment;
///        - registrations are events + storage that anyone can index;
///        - no admin can register on a holder's behalf, edit, or censor an
///          entry — only a proof of control of the holding wallet works.
///      Holders may re-register any number of times inside the window; the
///      last registration wins. Registering does not transfer anything: after
///      the window closes, the project joins registrations against the
///      published snapshot off-chain and builds the MigrationClaim Merkle
///      tree over (receiptWallet, amount) leaves. The join is reproducible by
///      anyone from this contract's events plus the published snapshot.
///
///      Smart-contract wallets are supported in both paths: directly via
///      {register}, and in {registerWithSig} through ERC-1271 signature
///      validation (OpenZeppelin SignatureChecker).
contract MigrationRegistry is EIP712 {
    /// @notice Registration window open, unix seconds (inclusive).
    uint64 public immutable registrationStart;
    /// @notice Registration window close, unix seconds (inclusive).
    uint64 public immutable registrationEnd;

    /// @notice Receipt wallet designated by each holder (zero = unregistered).
    mapping(address holder => address recipient) public recipientOf;
    /// @notice EIP-712 nonce per holder; a signature is bound to the current
    ///         nonce and consumed on use, so stale signatures cannot override
    ///         a newer registration.
    mapping(address holder => uint256 nonce) public nonces;

    bytes32 private constant REGISTER_TYPEHASH = keccak256("Register(address holder,address recipient,uint256 nonce)");

    /// @notice Emitted on every (re-)registration.
    event Registered(address indexed holder, address indexed recipient, bool viaSignature);

    /// @dev The registration window is misordered or already over.
    error InvalidWindow();
    /// @dev Registration attempted outside [registrationStart, registrationEnd].
    error WindowClosed();
    /// @dev Receipt wallet is the zero address.
    error ZeroRecipient();
    /// @dev Signature does not verify for the claimed holder and nonce.
    error InvalidSignature();

    /// @param registrationStart_ Window open, unix seconds.
    /// @param registrationEnd_ Window close, unix seconds; must be after start.
    constructor(uint64 registrationStart_, uint64 registrationEnd_) EIP712("GFTW MigrationRegistry", "1") {
        if (registrationEnd_ <= registrationStart_ || registrationEnd_ <= block.timestamp) {
            revert InvalidWindow();
        }
        registrationStart = registrationStart_;
        registrationEnd = registrationEnd_;
    }

    /// @notice Designate `recipient` as the receipt wallet for the caller.
    ///         Call this from the wallet that held GFT at the snapshot block.
    /// @param recipient Wallet that will receive the GFTW claim.
    function register(address recipient) external {
        _register(msg.sender, recipient, false);
    }

    /// @notice Relay a holder's signed designation. The holder signs the
    ///         EIP-712 struct Register(holder, recipient, nonces[holder]);
    ///         anyone may submit it — the signature, not the sender, is the
    ///         proof of control. Supports ERC-1271 contract wallets.
    /// @param holder Snapshot wallet that signed the registration.
    /// @param recipient Wallet that will receive the GFTW claim.
    /// @param signature EIP-712 signature by `holder` over the current nonce.
    function registerWithSig(address holder, address recipient, bytes calldata signature) external {
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(REGISTER_TYPEHASH, holder, recipient, nonces[holder])));
        if (!SignatureChecker.isValidSignatureNow(holder, digest, signature)) revert InvalidSignature();
        nonces[holder]++;
        _register(holder, recipient, true);
    }

    /// @notice EIP-712 domain separator, for client-side signing.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _register(address holder, address recipient, bool viaSignature) private {
        if (block.timestamp < registrationStart || block.timestamp > registrationEnd) revert WindowClosed();
        if (recipient == address(0)) revert ZeroRecipient();
        recipientOf[holder] = recipient;
        emit Registered(holder, recipient, viaSignature);
    }
}

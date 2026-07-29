// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title MigrationClaim
/// @notice Merkle-based claim of GFTW for snapshotted legacy GFT holders
///         (5 GFT -> 1 GFTW, amounts pre-computed off-chain into the tree).
/// @dev Fully permissionless and ownerless. Every parameter — token, Merkle
///      root, claim window, treasury — is fixed at deployment and can never be
///      changed. Nobody can pause claims, edit eligibility, or redirect funds.
///      After the window closes, anyone may sweep the unclaimed balance to the
///      (immutable) treasury, per the published migration terms.
///
///      Leaf encoding (OpenZeppelin standard double-hash):
///        keccak256(bytes.concat(keccak256(abi.encode(account, amount))))
///      compatible with the OpenZeppelin merkle-tree JS library used by the
///      generation script.
contract MigrationClaim {
    using SafeERC20 for IERC20;

    /// @notice Token being distributed (GFTW).
    IERC20 public immutable token;
    /// @notice Merkle root of the snapshot (account, GFTW amount) leaves.
    bytes32 public immutable merkleRoot;
    /// @notice Treasury receiving unclaimed tokens after the window closes.
    address public immutable treasury;
    /// @notice Claim window opening time, unix seconds (inclusive).
    uint64 public immutable claimStart;
    /// @notice Claim window closing time, unix seconds (inclusive).
    uint64 public immutable claimEnd;

    /// @notice Whether a snapshot account has already claimed.
    mapping(address account => bool) public claimed;

    /// @notice Emitted on a successful claim.
    event Claimed(address indexed account, uint256 amount);
    /// @notice Emitted when the post-window unclaimed balance is swept.
    event UnclaimedSwept(address indexed treasury, uint256 amount);

    /// @dev A constructor parameter is zero/empty.
    error ZeroParameter();
    /// @dev The claim window is misordered or in the past.
    error InvalidWindow();
    /// @dev Claim attempted outside [claimStart, claimEnd].
    error WindowClosed();
    /// @dev Account has already claimed.
    error AlreadyClaimed(address account);
    /// @dev Merkle proof does not verify against the root.
    error InvalidProof();
    /// @dev Sweep attempted before the window has closed.
    error WindowNotClosed();

    /// @param token_ GFTW token address.
    /// @param merkleRoot_ Root of the snapshot Merkle tree.
    /// @param treasury_ Treasury multisig receiving unclaimed tokens.
    /// @param claimStart_ Window open, unix seconds.
    /// @param claimEnd_ Window close, unix seconds; must be after claimStart_.
    constructor(IERC20 token_, bytes32 merkleRoot_, address treasury_, uint64 claimStart_, uint64 claimEnd_) {
        if (address(token_) == address(0) || treasury_ == address(0) || merkleRoot_ == bytes32(0)) {
            revert ZeroParameter();
        }
        if (claimEnd_ <= claimStart_ || claimEnd_ <= block.timestamp) revert InvalidWindow();
        token = token_;
        merkleRoot = merkleRoot_;
        treasury = treasury_;
        claimStart = claimStart_;
        claimEnd = claimEnd_;
    }

    /// @notice Claim `amount` GFTW for `account` with a Merkle proof.
    /// @dev Callable by anyone, but tokens are only ever sent to `account`
    ///      exactly as recorded in the snapshot. No lockup applies (§7.2).
    /// @param account Snapshot address entitled to the claim.
    /// @param amount GFTW amount (18 decimals) recorded in the snapshot leaf.
    /// @param proof Merkle proof for the (account, amount) leaf.
    function claim(address account, uint256 amount, bytes32[] calldata proof) external {
        if (block.timestamp < claimStart || block.timestamp > claimEnd) revert WindowClosed();
        if (claimed[account]) revert AlreadyClaimed(account);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leaf)) revert InvalidProof();

        claimed[account] = true;
        token.safeTransfer(account, amount);
        emit Claimed(account, amount);
    }

    /// @notice After the claim window closes, sweep the remaining balance to
    ///         the treasury. Callable by anyone; destination is immutable.
    function sweepUnclaimed() external {
        if (block.timestamp <= claimEnd) revert WindowNotClosed();
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(treasury, balance);
        emit UnclaimedSwept(treasury, balance);
    }
}

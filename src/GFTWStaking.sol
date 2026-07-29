// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GFTWStaking
/// @notice Stake GFTW, earn GFTW from the 180M community bucket on the
///         published decaying emission curve (whitepaper §9.6):
///           Year 1: 7.5M/month ->  90M
///           Year 2: 4.5M/month ->  54M
///           Year 3: 3.0M/month ->  36M
///           Year 4+: zero — bucket exhausted.
/// @dev Ownerless and immutable, like every other contract in this system:
///        - the emission schedule is hardcoded — nobody can change rates,
///          pause emissions, or extend them;
///        - rewards are pre-funded by the distribution multisig, never minted;
///        - principal is always withdrawable; there is no lock, no penalty,
///          no admin path to user funds;
///        - emissions that elapse while nobody is staked are permanently
///          undistributable and can be swept to the (immutable) treasury by
///          anyone after emissions end — they never go to any private party.
///      A "month" is 30 days; a schedule year is 360 days, consistent with the
///      vesting deployment convention.
///
///      Accounting is the standard accumulator pattern (reward-per-token
///      scaled by 1e18). Emitted amounts are integrated exactly per phase as
///      phaseTotal * elapsed / phaseDuration, so cumulative emissions hit
///      90M / 144M / 180M exactly at year boundaries with no rate rounding
///      drift.
contract GFTWStaking {
    using SafeERC20 for IERC20;

    /// @notice Schedule year: 12 × 30-day months.
    uint256 public constant YEAR = 360 days;
    /// @notice Year-1 emissions (7.5M × 12).
    uint256 public constant Y1_TOTAL = 90_000_000e18;
    /// @notice Year-2 emissions (4.5M × 12).
    uint256 public constant Y2_TOTAL = 54_000_000e18;
    /// @notice Year-3 emissions (3.0M × 12).
    uint256 public constant Y3_TOTAL = 36_000_000e18;
    /// @notice Total reward budget (the 18% community bucket share).
    uint256 public constant TOTAL_REWARDS = 180_000_000e18;

    /// @notice Token staked and rewarded (GFTW).
    IERC20 public immutable token;
    /// @notice Treasury receiving permanently-undistributable leftovers.
    address public immutable treasury;
    /// @notice Emission curve start (TGE / staking launch), unix seconds.
    uint64 public immutable emissionsStart;
    /// @notice Emission curve end: emissionsStart + 3 schedule years.
    uint64 public immutable emissionsEnd;

    /// @notice Total principal currently staked (never mixed with rewards).
    uint256 public totalStaked;
    /// @notice Accumulated reward per staked token, scaled by 1e18.
    uint256 public accRewardPerToken;
    /// @notice Cumulative emissions already integrated into the accumulator.
    uint256 public emittedIntegrated;
    /// @notice Rewards attributed to stakers so far (claimed or claimable).
    uint256 public rewardsAccrued;
    /// @notice Rewards actually paid out so far.
    uint256 public rewardsPaid;

    /// @notice Principal staked per account.
    mapping(address account => uint256) public staked;
    /// @dev Accumulator checkpoint per account.
    mapping(address account => uint256) private _userAccPaid;
    /// @dev Rewards settled but not yet claimed per account.
    mapping(address account => uint256) private _rewards;

    /// @notice Emitted when `account` stakes `amount`.
    event Staked(address indexed account, uint256 amount);
    /// @notice Emitted when `account` withdraws `amount` of principal.
    event Withdrawn(address indexed account, uint256 amount);
    /// @notice Emitted when `account` claims `amount` of rewards.
    event RewardClaimed(address indexed account, uint256 amount);
    /// @notice Emitted when undistributable leftovers are swept to treasury.
    event UndistributedSwept(address indexed treasury, uint256 amount);

    /// @dev A constructor parameter is zero.
    error ZeroParameter();
    /// @dev Zero-amount stake or withdraw.
    error ZeroAmount();
    /// @dev Withdraw amount exceeds staked balance.
    error InsufficientStake();
    /// @dev Sweep attempted before emissions have ended.
    error EmissionsNotEnded();

    /// @param token_ GFTW token.
    /// @param treasury_ Treasury multisig for post-emissions leftovers.
    /// @param emissionsStart_ Curve start (TGE), unix seconds.
    constructor(IERC20 token_, address treasury_, uint64 emissionsStart_) {
        if (address(token_) == address(0) || treasury_ == address(0) || emissionsStart_ == 0) {
            revert ZeroParameter();
        }
        token = token_;
        treasury = treasury_;
        emissionsStart = emissionsStart_;
        emissionsEnd = emissionsStart_ + uint64(3 * YEAR);
    }

    // ------------------------------------------------------------- emissions

    /// @notice Total GFTW emitted by the curve from emissionsStart up to `t`.
    /// @dev Piecewise-linear; exact (no rate rounding) at phase boundaries.
    function cumulativeEmitted(uint256 t) public view returns (uint256) {
        if (t <= emissionsStart) return 0;
        uint256 elapsed = t - emissionsStart;
        if (elapsed >= 3 * YEAR) return TOTAL_REWARDS;
        if (elapsed >= 2 * YEAR) {
            return Y1_TOTAL + Y2_TOTAL + (Y3_TOTAL * (elapsed - 2 * YEAR)) / YEAR;
        }
        if (elapsed >= YEAR) {
            return Y1_TOTAL + (Y2_TOTAL * (elapsed - YEAR)) / YEAR;
        }
        return (Y1_TOTAL * elapsed) / YEAR;
    }

    /// @dev Integrates emissions since the last update into the accumulator.
    ///      Emissions over intervals where totalStaked == 0 are skipped and
    ///      become permanently undistributable (sweepable after end).
    function _update(address account) private {
        uint256 cum = cumulativeEmitted(block.timestamp);
        uint256 delta = cum - emittedIntegrated;
        if (delta > 0) {
            if (totalStaked > 0) {
                accRewardPerToken += (delta * 1e18) / totalStaked;
                rewardsAccrued += delta;
            }
            emittedIntegrated = cum;
        }
        if (account != address(0)) {
            _rewards[account] += (staked[account] * (accRewardPerToken - _userAccPaid[account])) / 1e18;
            _userAccPaid[account] = accRewardPerToken;
        }
    }

    // --------------------------------------------------------------- actions

    /// @notice Stake `amount` GFTW. No lock; withdraw any time.
    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _update(msg.sender);
        totalStaked += amount;
        staked[msg.sender] += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /// @notice Withdraw `amount` of staked principal.
    function withdraw(uint256 amount) public {
        if (amount == 0) revert ZeroAmount();
        if (amount > staked[msg.sender]) revert InsufficientStake();
        _update(msg.sender);
        totalStaked -= amount;
        staked[msg.sender] -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claim all accrued rewards.
    function claimReward() public {
        _update(msg.sender);
        uint256 reward = _rewards[msg.sender];
        if (reward > 0) {
            _rewards[msg.sender] = 0;
            rewardsPaid += reward;
            token.safeTransfer(msg.sender, reward);
            emit RewardClaimed(msg.sender, reward);
        }
    }

    /// @notice Withdraw all principal and claim all rewards.
    function exit() external {
        claimReward();
        uint256 balance = staked[msg.sender];
        if (balance > 0) withdraw(balance);
    }

    /// @notice After emissions end, sweep rewards that can never be
    ///         distributed (emissions elapsed with zero stakers, plus
    ///         accumulator rounding dust) to the treasury. Callable by
    ///         anyone; never touches staked principal or accrued rewards.
    function sweepUndistributed() external {
        if (block.timestamp <= emissionsEnd) revert EmissionsNotEnded();
        _update(address(0));
        uint256 outstanding = rewardsAccrued - rewardsPaid;
        uint256 sweepable = token.balanceOf(address(this)) - totalStaked - outstanding;
        if (sweepable > 0) {
            token.safeTransfer(treasury, sweepable);
            emit UndistributedSwept(treasury, sweepable);
        }
    }

    // ----------------------------------------------------------------- views

    /// @notice Rewards `account` could claim right now.
    function earned(address account) external view returns (uint256) {
        uint256 acc = accRewardPerToken;
        uint256 cum = cumulativeEmitted(block.timestamp);
        uint256 delta = cum - emittedIntegrated;
        if (delta > 0 && totalStaked > 0) {
            acc += (delta * 1e18) / totalStaked;
        }
        return _rewards[account] + (staked[account] * (acc - _userAccPaid[account])) / 1e18;
    }

    /// @notice Current emission rate in GFTW-wei per second (0 outside curve).
    function currentRatePerSecond() external view returns (uint256) {
        if (block.timestamp < emissionsStart || block.timestamp >= emissionsEnd) return 0;
        uint256 elapsed = block.timestamp - emissionsStart;
        if (elapsed >= 2 * YEAR) return Y3_TOTAL / YEAR;
        if (elapsed >= YEAR) return Y2_TOTAL / YEAR;
        return Y1_TOTAL / YEAR;
    }
}

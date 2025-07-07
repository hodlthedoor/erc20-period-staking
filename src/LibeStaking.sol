// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract LibeStaking is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    uint256 public rewardRate; // Rewards per second, scaled by 1e18
    uint256 public unstakeCooldownTime;
    uint256 public constant MAX_LOCK_TIME = 365 days;
    uint256 public rewardStartDelay;

    struct Stake {
        uint256 amount;
        uint256 lastClaimTime;
        uint256 unstakeTime;
    }

    mapping(address => Stake) public stakes;

    // Custom errors
    error InvalidAmount();
    error NoStakeFound();
    error TransferFailed();
    error ZeroRewardRate();
    error UnstakeInCooldown();
    error TokensStaked();
    error InvalidCooldownTime();
    error NoRewardsToClaim();
    // Events

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);

    constructor(address _stakingToken, uint256 _rewardRate, uint256 _unstakeCooldownTime, uint256 _rewardStartDelay)
        Ownable(msg.sender)
    {
        stakingToken = IERC20(_stakingToken);
        rewardRate = _rewardRate;
        unstakeCooldownTime = _unstakeCooldownTime;
        rewardStartDelay = _rewardStartDelay;
    }

    function setRewardStartDelay(uint256 _newDelay) external onlyOwner {
        rewardStartDelay = _newDelay;
    }

    function setRewardRate(uint256 _newRate) external onlyOwner {
        require(_newRate != 0, ZeroRewardRate());
        rewardRate = _newRate;
    }

    function setStakingCooldownTime(uint256 _newCooldownTime) external onlyOwner {
        require(_newCooldownTime <= MAX_LOCK_TIME, InvalidCooldownTime());
        unstakeCooldownTime = _newCooldownTime;
    }

    function stake(uint256 _amount) external {
        require(_amount != 0, InvalidAmount());

        Stake storage userStake = stakes[msg.sender];

        require(userStake.unstakeTime == 0, UnstakeInCooldown());

        // If user has existing stake, claim pending rewards first
        if (userStake.amount > 0) {
            _claimRewards();
        }

        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);

        // Update or create stake
        userStake.amount += _amount;
        userStake.lastClaimTime = block.timestamp;
        userStake.unstakeTime = 0;

        emit Staked(msg.sender, _amount);
    }

    function unstake() external {
        Stake storage userStake = stakes[msg.sender];

        // Check if user has a stake
        require(userStake.amount > 0, NoStakeFound());

        // Check that user is not already unstaking
        require(userStake.unstakeTime == 0, UnstakeInCooldown());

        // Set unstake time to current timestamp
        userStake.unstakeTime = block.timestamp;

        emit Unstaked(msg.sender, userStake.amount);
    }

    function withdraw() external {
        Stake storage userStake = stakes[msg.sender];
        require(userStake.amount > 0, NoStakeFound());
        require(userStake.unstakeTime > 0, TokensStaked());
        require(userStake.unstakeTime + unstakeCooldownTime < block.timestamp, UnstakeInCooldown());

        // Claim rewards before withdrawal
        _claimRewards();

        // Store amount to withdraw before zeroing the stake
        uint256 amountToWithdraw = userStake.amount;
        userStake.amount = 0;
        userStake.unstakeTime = 0;

        if (!stakingToken.transfer(msg.sender, amountToWithdraw)) revert TransferFailed();

        emit Withdrawn(msg.sender, amountToWithdraw);
    }

    function calculatePendingRewards(address _user) public view returns (uint256) {
        Stake memory userStake = stakes[_user];
        if (userStake.amount == 0) return 0;

        uint256 claimTime = userStake.unstakeTime > 0 ? userStake.unstakeTime : block.timestamp;

        // Check if waiting period has elapsed
        if (userStake.lastClaimTime + rewardStartDelay > claimTime) return 0;

        // Adjust start time to account for delay
        uint256 startTime = userStake.lastClaimTime + rewardStartDelay;
        uint256 timeElapsed = claimTime - startTime;
        return (userStake.amount * timeElapsed * rewardRate) / 1e18;
    }

    function claimRewards() external {
        _claimRewards();
    }

    function claimAndRestake() external {
        uint256 rewards = calculatePendingRewards(msg.sender);
        require(rewards > 0, NoRewardsToClaim());

        Stake storage userStake = stakes[msg.sender];
        userStake.amount += rewards;

        // Update lastClaimTime but subtract rewardStartDelay to bypass waiting period
        userStake.lastClaimTime = block.timestamp - rewardStartDelay;
        userStake.unstakeTime = 0;

        emit RewardsClaimed(msg.sender, rewards);
        emit Staked(msg.sender, rewards);
    }

    function _claimRewards() internal {
        uint256 rewards = calculatePendingRewards(msg.sender);
        if (rewards == 0) return;

        Stake storage userStake = stakes[msg.sender];

        userStake.lastClaimTime = block.timestamp;

        if (!stakingToken.transfer(msg.sender, rewards)) revert TransferFailed();

        emit RewardsClaimed(msg.sender, rewards);
    }

    // Add this helper function to convert APR to per-second rate
    function _aprToRewardRate(uint256 aprBasisPoints) internal pure returns (uint256) {
        // aprBasisPoints: 1000 = 10%
        // Convert APR to per-second rate, scaled by 1e18
        // Formula: (aprBasisPoints / 10000) / (365 * 24 * 3600) * 1e18
        return (aprBasisPoints * 1e18) / (10000 * 365 days);
    }

    // Add new function to set reward rate by APR
    function setRewardRateByAPR(uint256 aprBasisPoints) external onlyOwner {
        require(aprBasisPoints != 0, ZeroRewardRate());
        rewardRate = _aprToRewardRate(aprBasisPoints);
    }
}

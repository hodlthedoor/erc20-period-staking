// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract LibePeriodStaking is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    uint256 public unstakeCooldownTime;
    uint256 public constant MAX_LOCK_TIME = 365 days;
    uint256 public rewardStartDelay;
    uint256 public constant QUARTER = 90 days;
    uint256 public immutable startTime;
    uint256 public immutable endTime;

    struct RewardPeriod {
        uint256 startTime;
        uint256 aprBasisPoints;
    }

    struct Stake {
        uint256 amount;
        uint256 lastClaimTime;
        uint256 unstakeTime;
        bool firstStake;
    }

    struct RewardPeriodInfo {
        uint256 periodNumber;
        uint256 startTime;
        uint256 endTime;
        uint256 aprBasisPoints;
    }

    RewardPeriod[] public rewardPeriods;
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
    error StakingProgramEnded();
    error NonSequentialPeriod();
    error CannotModifyPastPeriod();
    error InsufficientRewardsUseEmergencyWithdrawToGetStakeBack();

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardRateUpdated(
        uint256 indexed periodNumber,
        uint256 aprBasisPoints,
        uint256 periodStartTime
    );
    event RewardsAdded(uint256 amount);
    event EmergencyWithdrawn(address indexed user, uint256 amount);

    uint256 public totalStaked;
    uint256 public totalRewardsDistributed;
    uint256 public availableRewards;

    constructor(
        address _stakingToken,
        uint256 _initialAprBasisPoints,
        uint256 _unstakeCooldownTime,
        uint256 _rewardStartDelay,
        uint256 _startTime
    ) Ownable(msg.sender) {
        stakingToken = IERC20(_stakingToken);
        startTime = _startTime;
        endTime = _startTime + (5 * 365 days);
        rewardPeriods.push(RewardPeriod(_startTime, _initialAprBasisPoints));
        unstakeCooldownTime = _unstakeCooldownTime;
        rewardStartDelay = _rewardStartDelay;
        totalStaked = 0;
        totalRewardsDistributed = 0;
        availableRewards = 0;
    }

    function setRewardStartDelay(uint256 _newDelay) external onlyOwner {
        rewardStartDelay = _newDelay;
    }

    function setStakingCooldownTime(uint256 _newCooldownTime) external onlyOwner {
        require(_newCooldownTime <= MAX_LOCK_TIME, InvalidCooldownTime());
        unstakeCooldownTime = _newCooldownTime;
    }

    function setQuarterlyRewardRateByAPR(uint256 quarterIndex, uint256 aprBasisPoints) public onlyOwner {
        require(aprBasisPoints != 0, ZeroRewardRate());

        uint256 periodStartTime = startTime + (quarterIndex * QUARTER);
        uint256 periodEndTime = periodStartTime + QUARTER;
        require(periodStartTime < endTime, StakingProgramEnded());

        // Cannot modify periods that have ended
        if (periodEndTime <= block.timestamp) {
            revert CannotModifyPastPeriod();
        }

        // Check if previous period exists for non-zero periods
        if (quarterIndex > 0 && rewardPeriods.length <= quarterIndex - 1) {
            revert NonSequentialPeriod();
        }

        // If setting next period, push to array
        if (rewardPeriods.length == quarterIndex) {
            rewardPeriods.push(RewardPeriod({
                startTime: startTime + (quarterIndex * QUARTER),
                aprBasisPoints: aprBasisPoints
            }));
        } else {
            // Otherwise update existing period
            rewardPeriods[quarterIndex] = RewardPeriod({
                startTime: startTime + (quarterIndex * QUARTER),
                aprBasisPoints: aprBasisPoints
            });
        }

        emit RewardRateUpdated(
            quarterIndex,
            aprBasisPoints,
            startTime + (quarterIndex * QUARTER)
        );
    }

    function addNextRewardPeriod(uint256 aprBasisPoints) external onlyOwner {
        // Get the next period number based on the current array length
        uint256 nextPeriodNumber = rewardPeriods.length;

        // Call the existing function with the calculated period number
        setQuarterlyRewardRateByAPR(nextPeriodNumber, aprBasisPoints);
    }

    function stake(uint256 _amount) external {
        require(_amount != 0, InvalidAmount());

        Stake storage userStake = stakes[msg.sender];

        // Transfer tokens first
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        totalStaked += _amount;

        // Calculate any pending rewards
        uint256 rewards = calculatePendingRewards(msg.sender);

        // Set firstStake flag and update stake info
        userStake.firstStake = true;
        userStake.amount += _amount;
        userStake.lastClaimTime = block.timestamp;
        userStake.unstakeTime = 0;

        // If there are rewards and enough available, claim them
        if (rewards > 0) {
            if (rewards > availableRewards) revert InsufficientRewardsUseEmergencyWithdrawToGetStakeBack();
            availableRewards -= rewards;
            totalRewardsDistributed += rewards;
            userStake.amount += rewards;
            emit RewardsClaimed(msg.sender, rewards);
        }
        
        emit Staked(msg.sender, _amount);
    }

    function unstake() external {
        Stake storage userStake = stakes[msg.sender];
        require(userStake.amount > 0, NoStakeFound());
        require(userStake.unstakeTime == 0, UnstakeInCooldown());

        userStake.unstakeTime = block.timestamp;

        emit Unstaked(msg.sender, userStake.amount);
    }

    function withdraw() external {
        Stake storage userStake = stakes[msg.sender];
        require(userStake.amount > 0, NoStakeFound());
        require(userStake.unstakeTime > 0, TokensStaked());
        require(userStake.unstakeTime + unstakeCooldownTime < block.timestamp, UnstakeInCooldown());

        uint256 rewards = calculatePendingRewards(msg.sender);
        
        // Check if we have enough rewards available
        if (rewards > availableRewards) {
            revert InsufficientRewardsUseEmergencyWithdrawToGetStakeBack();
        }

        uint256 amountToWithdraw = userStake.amount + rewards;
        userStake.amount = 0;
        userStake.unstakeTime = 0;

        // Update rewards tracking
        availableRewards -= rewards;
        totalRewardsDistributed += rewards;

        require(stakingToken.transfer(msg.sender, amountToWithdraw), TransferFailed());

        emit Withdrawn(msg.sender, amountToWithdraw);
    }

    function calculatePendingRewards(address _user) public view returns (uint256) {
        Stake memory userStake = stakes[_user];
        if (userStake.amount == 0) return 0;

        uint256 claimTime = userStake.unstakeTime > 0 ? userStake.unstakeTime : block.timestamp;
        claimTime = Math.min(claimTime, endTime);

        // If still in waiting period, return 0
        if (userStake.firstStake && block.timestamp <= userStake.lastClaimTime + rewardStartDelay) {
            return 0;
        }

        uint256 currentTime = userStake.lastClaimTime;
        if (userStake.firstStake) {
            currentTime = userStake.lastClaimTime + rewardStartDelay;
        }
        uint256 totalRewards = 0;

        while (currentTime < claimTime) {
            uint256 periodIndex = findRewardPeriod(currentTime);
            uint256 nextPeriodStart =
                periodIndex + 1 < rewardPeriods.length ? rewardPeriods[periodIndex + 1].startTime : type(uint256).max;

            uint256 periodEndTime = Math.min(Math.min(Math.min(nextPeriodStart, claimTime), block.timestamp), endTime);
            uint256 timeInPeriod = periodEndTime - currentTime;

            // Calculate rewards using basis points
            // amount * (apr/10000) * (timeInSeconds/SECONDS_PER_YEAR)
            totalRewards += (userStake.amount * rewardPeriods[periodIndex].aprBasisPoints * timeInPeriod) / (10000 * 365 days);

            currentTime = periodEndTime;
        }

        return totalRewards;
    }

    function claimRewards() external {
        _claimRewards();
    }

    function claimAndRestake() public {
        uint256 rewards = calculatePendingRewards(msg.sender);
        require(rewards > 0, NoRewardsToClaim());
        
        // Check if we have enough rewards available
        if (rewards > availableRewards) {
            revert InsufficientRewardsUseEmergencyWithdrawToGetStakeBack();
        }

        Stake storage userStake = stakes[msg.sender];
        userStake.amount += rewards;
        userStake.lastClaimTime = block.timestamp;
        userStake.unstakeTime = 0;
        userStake.firstStake = false;

        // Update rewards tracking
        availableRewards -= rewards;
        totalRewardsDistributed += rewards;

        emit RewardsClaimed(msg.sender, rewards);
        emit Staked(msg.sender, rewards);
    }

    function _claimRewards() internal {
        uint256 rewards = calculatePendingRewards(msg.sender);
        if (rewards > availableRewards) revert InsufficientRewardsUseEmergencyWithdrawToGetStakeBack();
        
        availableRewards -= rewards;
        totalRewardsDistributed += rewards;
        if (rewards == 0) return;

        Stake storage userStake = stakes[msg.sender];
        userStake.lastClaimTime = block.timestamp;
        userStake.firstStake = false;

        require(stakingToken.transfer(msg.sender, rewards), TransferFailed());

        emit RewardsClaimed(msg.sender, rewards);
    }

    function findRewardPeriod(uint256 timestamp) internal view returns (uint256) {
        // If after program end, return last period
        if (timestamp >= endTime) {
            return rewardPeriods.length - 1;
        }

        // Start from the earliest period
        for (uint256 i = 0; i < rewardPeriods.length; i++) {
            // If this is the last period or the timestamp is before the next period
            if (i == rewardPeriods.length - 1 || timestamp < rewardPeriods[i + 1].startTime) {
                return i;
            }
        }
        return 0;
    }

    function getCurrentPeriodInfo() external view returns (RewardPeriodInfo memory) {
        // Check if we're past program end
        if (block.timestamp >= endTime) {
            return RewardPeriodInfo({
                periodNumber: 20,  // 5 years = 20 quarters
                startTime: startTime + (20 * QUARTER),
                endTime: endTime,
                aprBasisPoints: 0  // Changed from rewardRate
            });
        }

        // Calculate current period based on time
        uint256 currentPeriod = (block.timestamp - startTime) / QUARTER;
        
        // If this period exists in our rewards array, use that data
        if (currentPeriod < rewardPeriods.length) {
            uint256 nextPeriodStart = currentPeriod + 1 < rewardPeriods.length 
                ? rewardPeriods[currentPeriod + 1].startTime 
                : startTime + ((currentPeriod + 1) * QUARTER);

            return RewardPeriodInfo({
                periodNumber: currentPeriod,
                startTime: rewardPeriods[currentPeriod].startTime,
                endTime: nextPeriodStart,
                aprBasisPoints: rewardPeriods[currentPeriod].aprBasisPoints  // Return basis points directly
            });
        }

        // For unset future periods
        return RewardPeriodInfo({
            periodNumber: currentPeriod,
            startTime: startTime + (currentPeriod * QUARTER),
            endTime: startTime + ((currentPeriod + 1) * QUARTER),
            aprBasisPoints: 0  // Changed from rewardRate
        });
    }

    function addRewards(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        availableRewards += amount;
        emit RewardsAdded(amount);
    }

    function emergencyWithdraw() external {
        Stake storage userStake = stakes[msg.sender];
        require(userStake.amount > 0, "No stake found");
        
        // First set unstake time if not already set
        if (userStake.unstakeTime == 0) {
            userStake.unstakeTime = block.timestamp;
            emit Unstaked(msg.sender, userStake.amount);
            return;
        }
        
        // Check cooldown period
        require(
            userStake.unstakeTime + unstakeCooldownTime < block.timestamp, 
            UnstakeInCooldown()
        );
        
        // Only return original stake amount, not rewards
        uint256 originalStake = userStake.amount;
        userStake.amount = 0;
        userStake.unstakeTime = 0;
        totalStaked -= originalStake;
        
        stakingToken.safeTransfer(msg.sender, originalStake);
        emit EmergencyWithdrawn(msg.sender, originalStake);
    }
}

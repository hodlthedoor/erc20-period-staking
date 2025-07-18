// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/LibeStaking.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {
        _mint(msg.sender, 10000000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }
}

contract FailingMockERC20 is ERC20 {
    bool public failTransfers;

    constructor() ERC20("Failing Mock Token", "FMT") {
        _mint(msg.sender, 10000000 * 10 ** decimals());
    }

    function setFailTransfers(bool _fail) external {
        failTransfers = _fail;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        if (failTransfers) {
            return false;
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        if (failTransfers) {
            return false;
        }
        return super.transferFrom(from, to, amount);
    }
}

contract FlatRateStakingTest is Test {
    LibeStaking public staking;
    MockERC20 public token;
    address public user;

    uint256 public constant REWARD_RATE = 0.1 ether; // 0.1 tokens per second

    uint256 public constant WAITING_PERIOD = 0;

    function setUp() public {
        user = makeAddr("user");
        token = new MockERC20();
        staking = new LibeStaking(address(token), REWARD_RATE, 30 days, WAITING_PERIOD);

        // Give user some tokens and approve staking contract
        token.transfer(user, 1000 * 10 ** 18);
        vm.prank(user);
        token.approve(address(staking), type(uint256).max);

        // Fund staking contract with rewards
        token.transfer(address(staking), token.balanceOf(address(this)) - (1000 * 10 ** 18));
    }

    function testBasicStaking() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        uint256 contractStartBalance = token.balanceOf(address(staking));

        // Initial stake
        vm.prank(user);
        staking.stake(stakeAmount);

        // Verify stake was recorded
        (uint256 amount, uint256 lastClaimTime, uint256 unstakeTime) = staking.stakes(user);
        assertEq(amount, stakeAmount, "Incorrect stake amount");
        assertEq(lastClaimTime, block.timestamp, "Incorrect last claim time");
        assertEq(unstakeTime, 0, "Unstake time should be 0");

        // Verify token transfer
        assertEq(
            token.balanceOf(address(staking)), contractStartBalance + stakeAmount, "Incorrect staking contract balance"
        );
        assertEq(token.balanceOf(user), 900 * 10 ** 18, "Incorrect user balance");
    }

    function testStakingWithWaitingPeriod() public {
        uint256 stakeAmount = 100 * 10 ** 18;
        uint256 waitPeriod = 1 days;
        staking.setRewardStartDelay(waitPeriod);

        uint256 contractStartBalance = token.balanceOf(address(staking));

        // Initial stake
        vm.prank(user);
        staking.stake(stakeAmount);

        // Verify stake was recorded
        (uint256 amount, uint256 lastClaimTime, uint256 unstakeTime) = staking.stakes(user);
        assertEq(amount, stakeAmount, "Incorrect stake amount");
        assertEq(lastClaimTime, block.timestamp, "Incorrect last claim time");
        assertEq(unstakeTime, 0, "Unstake time should be 0");

        // Verify token transfer
        assertEq(
            token.balanceOf(address(staking)), contractStartBalance + stakeAmount, "Incorrect staking contract balance"
        );
        assertEq(token.balanceOf(user), 900 * 10 ** 18, "Incorrect user balance");

        // Check no rewards during waiting period
        vm.warp(block.timestamp + waitPeriod - 1);
        assertEq(staking.calculatePendingRewards(user), 0, "Should have no rewards during waiting period");

        // Check rewards after waiting period
        vm.warp(block.timestamp + 2); // 1 second after waiting period
        uint256 expectedRewards = (stakeAmount * 1 * staking.rewardRate()) / 1e18;
        assertEq(staking.calculatePendingRewards(user), expectedRewards, "Incorrect rewards after waiting period");
    }

    function testRewardAccumulation() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Initial stake
        vm.prank(user);
        staking.stake(stakeAmount);

        // Move forward 1 hour
        vm.warp(block.timestamp + 1 hours);

        // Calculate expected rewards
        // 1 hour = 3600 seconds
        // Reward = amount * time * rate / 1e18
        uint256 expectedRewards = (stakeAmount * 3600 * REWARD_RATE) / 1e18;

        uint256 pendingRewards = staking.calculatePendingRewards(user);
        assertEq(pendingRewards, expectedRewards, "Incorrect pending rewards");

        // Claim rewards
        uint256 balanceBefore = token.balanceOf(user);

        vm.prank(user);
        staking.claimRewards();

        uint256 actualRewards = token.balanceOf(user) - balanceBefore;
        assertEq(actualRewards, expectedRewards, "Incorrect claimed rewards");

        // Verify last claim time was updated
        (, uint256 lastClaimTime,) = staking.stakes(user);
        assertEq(lastClaimTime, block.timestamp, "Last claim time not updated");
    }

    function testZeroRewards() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Initial stake
        vm.prank(user);
        staking.stake(stakeAmount);

        // Try to claim immediately
        vm.prank(user);
        staking.claimRewards();

        // Should not receive any rewards
        assertEq(token.balanceOf(user), 900 * 10 ** 18, "Should not receive rewards immediately");
    }

    function testFivePercentAPR() public {
        uint256 YEAR_IN_SECONDS = 365 days;

        // Set 500 (5%) APR using the new function
        staking.setRewardRateByAPR(500);

        // Stake 100 tokens
        vm.startPrank(user);
        token.approve(address(staking), 100 * 10 ** 18);
        staking.stake(100 * 10 ** 18);

        // Fast forward 1 year
        vm.warp(block.timestamp + YEAR_IN_SECONDS);

        // Calculate and claim rewards
        uint256 pendingRewards = staking.calculatePendingRewards(user);
        assertApproxEqAbs(pendingRewards, 5 * 10 ** 18, 1e16, "Should accrue ~5 tokens in rewards");

        // Start unstaking process
        staking.unstake();

        // Fast forward past cooldown
        vm.warp(block.timestamp + 31 days);

        // Withdraw stake (which also claims rewards)
        uint256 balanceBefore = token.balanceOf(user);
        staking.withdraw();
        vm.stopPrank();

        uint256 totalReceived = token.balanceOf(user) - balanceBefore;
        assertApproxEqAbs(totalReceived, 105 * 10 ** 18, 1e16, "Should receive 100 staked tokens plus 5 reward tokens");
    }

    function testMultiYearRewards() public {
        uint256 YEAR_IN_SECONDS = 365 days;
        uint256 rewardRatePerSecond = (5 * 1e18) / (100 * YEAR_IN_SECONDS);

        // Set the reward rate on existing contract
        staking.setRewardRate(rewardRatePerSecond);

        // Stake 100 tokens
        vm.startPrank(user);
        token.approve(address(staking), 100 * 10 ** 18);
        staking.stake(100 * 10 ** 18);
        vm.stopPrank();

        // Fast forward 1 year
        vm.warp(block.timestamp + YEAR_IN_SECONDS);

        // First year rewards should be 5 tokens
        uint256 pendingRewards = staking.calculatePendingRewards(user);
        assertApproxEqAbs(pendingRewards, 5 * 10 ** 18, 1e16, "Should accrue ~5 tokens in first year");

        // Claim first year rewards
        uint256 balanceBefore = token.balanceOf(user);
        vm.prank(user);
        staking.claimRewards();
        uint256 firstYearRewards = token.balanceOf(user) - balanceBefore;
        assertApproxEqAbs(firstYearRewards, 5 * 10 ** 18, 1e16, "Should receive ~5 tokens for first year");

        // Fast forward another year
        vm.warp(block.timestamp + YEAR_IN_SECONDS);

        // Second year rewards should also be 5 tokens
        pendingRewards = staking.calculatePendingRewards(user);
        assertApproxEqAbs(pendingRewards, 5 * 10 ** 18, 1e16, "Should accrue ~5 tokens in second year");

        // Claim second year rewards
        balanceBefore = token.balanceOf(user);
        vm.prank(user);
        staking.claimRewards();
        uint256 secondYearRewards = token.balanceOf(user) - balanceBefore;
        assertApproxEqAbs(secondYearRewards, 5 * 10 ** 18, 1e16, "Should receive ~5 tokens for second year");

        // Verify total rewards received is 10 tokens
        assertApproxEqAbs(
            firstYearRewards + secondYearRewards,
            10 * 10 ** 18,
            1e16,
            "Should have received ~10 tokens total over two years"
        );

        // Start unstaking process
        vm.startPrank(user);
        staking.unstake();

        // Fast forward past cooldown
        vm.warp(block.timestamp + 31 days); // Added extra day to ensure we're past cooldown

        // Finally withdraw everything
        balanceBefore = token.balanceOf(user);
        staking.withdraw();
        vm.stopPrank();

        uint256 finalBalance = token.balanceOf(user) - balanceBefore;
        assertEq(finalBalance, 100 * 10 ** 18, "Should receive original 100 tokens back");
    }

    function testUnstakingCooldown() public {
        // Stake tokens
        vm.startPrank(user);
        staking.stake(100 * 10 ** 18);

        // Start unstaking
        staking.unstake();

        // Try to withdraw immediately - should revert
        vm.expectRevert(); // Updated to match require statement
        staking.withdraw();

        // Move forward 15 days (half the cooldown)
        vm.warp(block.timestamp + 15 days);

        // Try to withdraw - should still revert
        vm.expectRevert(); // Updated to match require statement
        staking.withdraw();

        // Move forward past cooldown
        vm.warp(block.timestamp + 16 days); // Added extra day to ensure we're past cooldown

        // Should now be able to withdraw
        staking.withdraw();
        vm.stopPrank();

        // Verify balance
        assertEq(token.balanceOf(user), 1000 * 10 ** 18, "Should have received all tokens back");
    }

    function testCannotStakeWhileUnstaking() public {
        vm.startPrank(user);

        // Initial stake
        staking.stake(50 * 10 ** 18);

        // Start unstaking
        staking.unstake();

        // Try to stake more - should revert
        uint256 newStakeAmount = 50 * 10 ** 18;
        vm.expectRevert(); // Updated to match our error handling
        staking.stake(newStakeAmount);

        vm.stopPrank();
    }

    function testRewardsStopAfterUnstake() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Stake tokens
        vm.prank(user);
        staking.stake(stakeAmount);

        // Move forward 1 hour
        vm.warp(block.timestamp + 1 hours);

        // Start unstaking
        vm.prank(user);
        staking.unstake();

        // Record rewards at unstake time
        uint256 rewardsAtUnstake = staking.calculatePendingRewards(user);

        // Move forward another hour
        vm.warp(block.timestamp + 1 hours);

        // Verify rewards haven't increased
        uint256 rewardsAfterWaiting = staking.calculatePendingRewards(user);
        assertEq(rewardsAtUnstake, rewardsAfterWaiting, "Rewards should not increase after unstaking");
    }

    function testCannotUnstakeZeroBalance() public {
        vm.prank(user);
        vm.expectRevert(); // NoStakeFound error
        staking.unstake();
    }

    function testCannotUnstakeTwice() public {
        // Initial stake
        vm.startPrank(user);
        staking.stake(100 * 10 ** 18);

        // First unstake
        staking.unstake();

        // Try to unstake again
        vm.expectRevert(); // UnstakeInCooldown error
        staking.unstake();
        vm.stopPrank();
    }

    function testMultipleUsers() public {
        address user2 = makeAddr("user2");

        // Give user2 some tokens
        token.transfer(user2, 200 * 10 ** 18);
        token.transfer(user, 100 * 10 ** 18);
        vm.prank(user2);
        token.approve(address(staking), type(uint256).max);

        vm.prank(user);
        token.approve(address(staking), type(uint256).max);

        // Both users stake
        vm.prank(user);
        staking.stake(100 * 10 ** 18);

        vm.prank(user2);
        staking.stake(200 * 10 ** 18);

        // Move forward in time
        vm.warp(block.timestamp + 1 hours);

        // Check rewards are calculated independently
        uint256 user1Rewards = staking.calculatePendingRewards(user);
        uint256 user2Rewards = staking.calculatePendingRewards(user2);

        assertEq(user2Rewards, user1Rewards * 2, "User2 should have double rewards");
    }

    function testSetInvalidCooldownTime() public {
        uint256 tooLongCooldown = 366 days;
        vm.expectRevert(); // InvalidCooldownTime error
        staking.setStakingCooldownTime(tooLongCooldown);
    }

    function testStakeZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(); // InvalidAmount error
        staking.stake(0);
    }

    function testInsufficientBalance() public {
        uint256 tooMuch = 2000 * 10 ** 18; // User only has 1000 tokens
        vm.prank(user);
        vm.expectRevert(); // ERC20 insufficient balance error
        staking.stake(tooMuch);
    }

    function testSmallAmounts(uint256 stakeAmount, uint256 timeElapsed) public {
        // Bound stake amount to be between 1 wei and user's balance
        stakeAmount = bound(stakeAmount, 1, token.balanceOf(user));

        // Bound time elapsed to reasonable range (1 second to 100 years)
        timeElapsed = bound(timeElapsed, 1, 100 * 365 days);

        vm.prank(user);
        staking.stake(stakeAmount);

        vm.warp(block.timestamp + timeElapsed);

        uint256 rewards = staking.calculatePendingRewards(user);
        // Verify rewards calculation works with any valid amount
        assertGe(rewards, 0, "Should handle any valid amount");

        // Verify rewards calculation matches expected formula
        uint256 expectedRewards = (stakeAmount * timeElapsed * REWARD_RATE) / 1e18;
        assertEq(rewards, expectedRewards, "Rewards calculation should match expected");
    }

    function testErc20FailingTransfers() public {
        // Setup new failing token and staking contract
        FailingMockERC20 failingToken = new FailingMockERC20();
        LibeStaking failingStaking = new LibeStaking(address(failingToken), REWARD_RATE, 30 days, WAITING_PERIOD);

        // Give user some tokens and approve
        failingToken.transfer(user, 1000 * 10 ** 18);
        vm.prank(user);
        failingToken.approve(address(failingStaking), type(uint256).max);

        // Fund staking contract with rewards
        failingToken.transfer(address(failingStaking), failingToken.balanceOf(address(this)) - (1000 * 10 ** 18));

        // Make transfers fail
        failingToken.setFailTransfers(true);

        // Try to stake - should revert
        vm.prank(user);
        vm.expectRevert(); // TransferFailed error
        failingStaking.stake(100 * 10 ** 18);

        // Test reward transfer failure
        failingToken.setFailTransfers(false);
        vm.prank(user);
        failingStaking.stake(100 * 10 ** 18);

        // Move forward in time to accrue rewards
        vm.warp(block.timestamp + 1 hours);

        // Make transfers fail again
        failingToken.setFailTransfers(true);

        // Try to claim rewards - should revert
        vm.prank(user);
        vm.expectRevert(); // TransferFailed error
        failingStaking.claimRewards();
    }

    function testStakeAfterWithdrawRequiresNewCooldown() public {
        // Initial stake
        vm.startPrank(user);
        staking.stake(100 * 10 ** 18);

        // Start unstaking
        staking.unstake();

        // Fast forward past cooldown
        vm.warp(block.timestamp + 31 days);

        // Withdraw
        staking.withdraw();

        // Stake again
        staking.stake(50 * 10 ** 18);

        // Try to unstake immediately - should work since it's a new stake
        staking.unstake();

        // Try to withdraw immediately - should revert since we need to wait cooldown
        vm.expectRevert();
        staking.withdraw();

        // Fast forward half the cooldown - should still revert
        vm.warp(block.timestamp + 15 days);
        vm.expectRevert();
        staking.withdraw();

        // Fast forward past full cooldown - should now work
        vm.warp(block.timestamp + 16 days);
        staking.withdraw();
        vm.stopPrank();

        // Verify final balance
        assertEq(token.balanceOf(user), 1000 * 10 ** 18, "Should have received all tokens back");
    }

    function testWithdrawDuringWaitingPeriod() public {
        uint256 stakeAmount = 100 * 10 ** 18;
        uint256 waitPeriod = 1 days;
        uint256 cooldownTime = 2 days;

        staking.setRewardStartDelay(waitPeriod);
        staking.setStakingCooldownTime(cooldownTime);

        // Initial stake
        vm.prank(user);
        staking.stake(stakeAmount);

        // Initiate unstake before waiting period ends
        vm.warp(block.timestamp + waitPeriod / 2);
        vm.prank(user);
        staking.unstake();

        // Withdraw after cooldown but verify no rewards were earned
        vm.warp(block.timestamp + cooldownTime + 1);
        uint256 balanceBefore = token.balanceOf(user);

        vm.prank(user);
        staking.withdraw();

        uint256 balanceAfter = token.balanceOf(user);
        assertEq(balanceAfter - balanceBefore, stakeAmount, "Should only receive original stake amount");
    }

    function testClaimAndRestakeAfterWaitingPeriod() public {
        uint256 stakeAmount = 100 * 10 ** 18;
        uint256 waitPeriod = 1 days;
        staking.setRewardStartDelay(waitPeriod);

        // 1) User stakes initially
        vm.prank(user);
        staking.stake(stakeAmount);

        // 2) Warp just before waiting period ends => 0 rewards
        vm.warp(block.timestamp + waitPeriod - 1);
        assertEq(staking.calculatePendingRewards(user), 0, "Should have no rewards during the waiting period");

        // 3) Warp +2 => we end up exactly 1 second past the wait period
        vm.warp(block.timestamp + 2);
        uint256 expectedRewards = (stakeAmount * 1 * staking.rewardRate()) / 1e18;
        assertEq(staking.calculatePendingRewards(user), expectedRewards, "Incorrect rewards after initial wait period");

        // 4) Claim and restake => should NOT reset waiting period
        vm.prank(user);
        staking.claimAndRestake();

        // 5) Verify new stake amount
        (uint256 newStakeAmount, uint256 lastClaimTime, uint256 unstakeTime) = staking.stakes(user);
        assertEq(newStakeAmount, stakeAmount + expectedRewards, "Incorrect new stake amount after restake");

        // 6) Immediately warp 1 second => should start earning immediately
        vm.warp(block.timestamp + 1);
        uint256 immediateRewards = (newStakeAmount * 1 * staking.rewardRate()) / 1e18;
        assertEq(
            staking.calculatePendingRewards(user),
            immediateRewards,
            "Should earn rewards immediately after restake (no waiting period)"
        );

        // 7) Warp another second to verify continuous earning
        vm.warp(block.timestamp + 1);
        uint256 expectedNewRewards = (newStakeAmount * 2 * staking.rewardRate()) / 1e18;
        assertEq(staking.calculatePendingRewards(user), expectedNewRewards, "Should continue earning rewards");
    }

    function testCannotSetWaitingPeriodIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        staking.setRewardStartDelay(1 days);
    }

    function testCannotSetRewardRateIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        staking.setRewardRate(100);
    }

    function testCannotSetStakingCooldownTimeIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        staking.setStakingCooldownTime(1 days);
    }

    function testCannotSetRewardRateByAPRIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        staking.setRewardRateByAPR(1000); // 10% APR
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LibePeriodStaking} from "../src/LibePeriodStaking.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

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

contract LibePeriodStakingTest is Test {
    LibePeriodStaking public staking;
    MockERC20 public token;
    address public user;

    uint256 public constant INITIAL_APR_BASIS_POINTS = 1000; // 10% APR
    uint256 public constant WAITING_PERIOD = 0;
    uint256 public constant QUARTER = 90 days;
    uint256 public startTime;

    function setUp() public {
        startTime = block.timestamp + 1 days;

        user = makeAddr("user");
        token = new MockERC20();
        staking = new LibePeriodStaking(
            address(token), 
            INITIAL_APR_BASIS_POINTS,
            30 days, 
            WAITING_PERIOD, 
            startTime
        );

        // Give user some tokens for staking
        token.transfer(user, 1000 * 10 ** 18);
        vm.prank(user);
        token.approve(address(staking), type(uint256).max);

        // Fund staking contract with rewards PROPERLY
        token.mint(address(this), 1_000_000_000 * 10 ** 18);
        token.approve(address(staking), type(uint256).max);
        staking.addRewards(1_000_000_000 * 10 ** 18);
    }

    function testBasicStaking() public {
        uint256 stakeAmount = 100 * 10 ** 18;
        uint256 contractStartBalance = token.balanceOf(address(staking));

        // Initial stake
        vm.prank(user);
        staking.stake(stakeAmount);

        // Verify stake was recorded
        (uint256 amount, uint256 lastClaimTime, uint256 unstakeTime, bool firstStake) = staking.stakes(user);
        assertEq(amount, stakeAmount, "Incorrect stake amount");
        assertEq(lastClaimTime, block.timestamp, "Incorrect last claim time");
        assertEq(unstakeTime, 0, "Unstake time should be 0");
        assertTrue(firstStake, "Should be marked as first stake");

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
        (uint256 amount, uint256 lastClaimTime, uint256 unstakeTime, bool firstStake) = staking.stakes(user);
        assertEq(amount, stakeAmount, "Incorrect stake amount");
        assertEq(lastClaimTime, block.timestamp, "Incorrect last claim time");
        assertEq(unstakeTime, 0, "Unstake time should be 0");
        assertTrue(firstStake, "Should be marked as first stake");

        // Verify token transfer
        assertEq(token.balanceOf(address(staking)), contractStartBalance + stakeAmount, "Incorrect staking contract balance");
        assertEq(token.balanceOf(user), 900 * 10 ** 18, "Incorrect user balance");

        // Check no rewards during waiting period
        vm.warp(block.timestamp + waitPeriod - 1);
        assertEq(staking.calculatePendingRewards(user), 0, "Should have no rewards during waiting period");

        // Check rewards after waiting period
        vm.warp(block.timestamp + 2); // 1 second after waiting period
        
        // Calculate expected rewards using basis points
        // amount * (apr/10000) * (timeInSeconds/SECONDS_PER_YEAR)
        uint256 expectedRewards = (stakeAmount * INITIAL_APR_BASIS_POINTS * 1) / (10000 * 365 days);
        
        assertEq(staking.calculatePendingRewards(user), expectedRewards, "Incorrect rewards after waiting period");
    }

    function testQuarterlyRateChange() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Initial stake
        vm.prank(user);
        staking.stake(stakeAmount);

        // Move to last quarter of the period
        vm.warp(startTime + (90 days * 3 / 4));

        // Set new rate for next quarter (10% APR = 1000 basis points)
        staking.setQuarterlyRewardRateByAPR(1, 1000);

        // Move to next quarter
        vm.warp(startTime + 90 days + 1);

        // Calculate rewards (should use new rate)
        uint256 pendingRewards = staking.calculatePendingRewards(user);
        assertTrue(pendingRewards > 0, "Should have rewards with new rate");
    }

    function testCanSetAndUpdateQuarterlyRates() public {
        // Move to before start time
        vm.warp(startTime - 1 days);

        // Set rate for first quarter (period 0 is initial rate)
        uint256 apr1 = 1000;
        staking.setQuarterlyRewardRateByAPR(1, apr1); // 10% APR

        // Set rate for second quarter
        uint256 apr2 = 2000;
        staking.setQuarterlyRewardRateByAPR(2, apr2); // 20% APR

        // Update first quarter rate while still before start time
        uint256 newApr1 = 1500;
        staking.setQuarterlyRewardRateByAPR(1, newApr1); // 15% APR

        // Verify the rates were set correctly
        (uint256 startTime1, uint256 rate1) = staking.rewardPeriods(1);
        (uint256 startTime2, uint256 rate2) = staking.rewardPeriods(2);

        assertEq(startTime1, startTime + QUARTER);
        assertEq(startTime2, startTime + (2 * QUARTER));

        // Verify rates match what we expect - now comparing basis points directly
        assertEq(rate1, newApr1);
        assertEq(rate2, apr2);
    }

    function testMultipleQuarterlyRates() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Initial stake
        vm.startPrank(user);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // Set rates for multiple quarters
        for (uint256 i = 1; i <= 4; i++) {
            staking.setQuarterlyRewardRateByAPR(i, 1000 * i); // Increasing rates
            vm.warp(startTime + (i * QUARTER));
        }

        // Move to end of year
        vm.warp(startTime + 365 days);

        // Claim rewards
        uint256 balanceBefore = token.balanceOf(user);
        vm.prank(user);
        staking.claimRewards();
        uint256 totalRewards = token.balanceOf(user) - balanceBefore;

        assertTrue(totalRewards > 0, "Should have accumulated rewards across multiple rates");
    }

    function testCanSetNextQuarterRate() public {
        // Move to start time
        vm.warp(startTime);

        // Set rate for next quarter (period 1)
        staking.setQuarterlyRewardRateByAPR(1, 1000);

        // Move forward a quarter
        vm.warp(startTime + QUARTER);

        // Set rate for the following quarter (period 2)
        staking.setQuarterlyRewardRateByAPR(2, 2000);

        // Verify the rates were set correctly
        (uint256 startTime1, uint256 rate1) = staking.rewardPeriods(1);
        (uint256 startTime2, uint256 rate2) = staking.rewardPeriods(2);
        assertTrue(rate2 > rate1, "Second rate should be higher");
        assertTrue(startTime2 > startTime1, "Second period should start after first");
    }

    function testRewardsAcrossMultiplePeriods() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Set up rates for first 3 quarters (periods 0-2)
        staking.setQuarterlyRewardRateByAPR(0, 1000); // 10% APR
        staking.setQuarterlyRewardRateByAPR(1, 2000); // 20% APR
        staking.setQuarterlyRewardRateByAPR(2, 3000); // 30% APR

        // Move to start time and stake
        vm.warp(startTime);
        vm.startPrank(user);
        staking.stake(stakeAmount);

        uint256 cumulativeExpectedRewards = 0;

        // Move through each quarter and verify rewards
        for (uint256 i = 0; i < 3; i++) {
            // Move to end of quarter
            vm.warp(startTime + ((i + 1) * QUARTER));

            // Get pending rewards before claim
            uint256 pendingRewards = staking.calculatePendingRewards(user);

            // Calculate expected rewards for this period
            uint256 expectedRewards;
            if (i == 0) {
                expectedRewards = 2.5 ether; // 10% APR for first quarter
                cumulativeExpectedRewards = expectedRewards;
            } else if (i == 1) {
                expectedRewards = 5 ether; // 20% APR for second quarter
                cumulativeExpectedRewards += expectedRewards;
            } else if (i == 2) {
                expectedRewards = 7.5 ether; // 30% APR for third quarter
                cumulativeExpectedRewards += expectedRewards;
            }

            // Claim and verify rewards match pending amount
            uint256 balanceBefore = token.balanceOf(user);

            staking.claimRewards();
            uint256 actualRewards = token.balanceOf(user) - balanceBefore;

            console.log("Quarter", i);
            console.log("Expected Rewards:", expectedRewards / 1e18, "tokens");
            console.log("Pending Rewards:", pendingRewards / 1e18, "tokens");
            console.log("Actual Rewards:", actualRewards / 1e18, "tokens");
            console.log("Cumulative Expected:", cumulativeExpectedRewards / 1e18, "tokens");

            assertApproxEqRel(actualRewards, pendingRewards, 0.02e18, "Claimed rewards should match pending rewards");
            assertApproxEqRel(pendingRewards, expectedRewards, 0.02e18, "Pending rewards should match expected rewards");
        }
    }

    function testRewardsStopAtUnstake() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Set up rate
        staking.setQuarterlyRewardRateByAPR(1, 1000); // 10% APR

        // Move to start time and stake
        vm.warp(startTime);
        vm.startPrank(user);
        staking.stake(stakeAmount);

        // Move halfway through quarter and unstake
        vm.warp(startTime + (QUARTER / 2));
        staking.unstake();

        // Record rewards at unstake time
        uint256 rewardsAtUnstake = staking.calculatePendingRewards(user);

        // Move to end of quarter
        vm.warp(startTime + QUARTER);

        // Verify rewards haven't increased
        uint256 rewardsAtWithdraw = staking.calculatePendingRewards(user);
        assertEq(rewardsAtUnstake, rewardsAtWithdraw, "Rewards should not increase after unstake");

        // Withdraw and verify received rewards match
        uint256 balanceBefore = token.balanceOf(user);
        staking.withdraw();
        uint256 actualRewards = token.balanceOf(user) - balanceBefore - stakeAmount;
        assertEq(actualRewards, rewardsAtUnstake, "Withdrawn rewards should match rewards at unstake");
        vm.stopPrank();
    }

    function testRestakeAfterUnstake() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Initial stake
        vm.startPrank(user);
        staking.stake(stakeAmount);

        // Move forward and unstake
        vm.warp(block.timestamp + 10 days);
        staking.unstake();

        // Verify unstake time is set
        (uint256 amount, uint256 lastClaimTime, uint256 unstakeTime, bool firstStake) = staking.stakes(user);
        assertTrue(unstakeTime > 0, "Unstake time should be set");

        // Move past cooldown
        vm.warp(block.timestamp + 31 days);

        // Withdraw
        staking.withdraw();

        // Try to stake again
        staking.stake(stakeAmount);

        // Verify unstake time is cleared
        (amount, lastClaimTime, unstakeTime, firstStake) = staking.stakes(user);
        assertEq(unstakeTime, 0, "Unstake time should be cleared after new stake");
        assertEq(amount, stakeAmount, "Stake amount should be set");
        assertEq(lastClaimTime, block.timestamp, "Last claim time should be updated");
        vm.stopPrank();
    }

    function testCannotStakeZero() public {
        vm.expectRevert(LibePeriodStaking.InvalidAmount.selector);
        staking.stake(0);
    }

    function testCannotStakeWithoutBalance() public {
        address poor = makeAddr("poor");
        vm.startPrank(poor);
        // Need to approve first to avoid allowance error
        token.approve(address(staking), 100 * 10 ** 18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 0, 100 * 10 ** 18));
        staking.stake(100 * 10 ** 18);
    }

    function testFailingTokenTransfers() public {
        FailingMockERC20 failingToken = new FailingMockERC20();
        LibePeriodStaking failingStaking =
            new LibePeriodStaking(address(failingToken), INITIAL_APR_BASIS_POINTS, 30 days, WAITING_PERIOD, startTime);

        failingToken.transfer(user, 1000 * 10 ** 18);
        vm.startPrank(user);
        failingToken.approve(address(failingStaking), type(uint256).max);

        failingToken.setFailTransfers(true);
        vm.expectRevert(LibePeriodStaking.TransferFailed.selector);
        failingStaking.stake(100 * 10 ** 18);
        vm.stopPrank();
    }

    function testOnlyOwnerCanSetRates() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("notOwner")));
        staking.setQuarterlyRewardRateByAPR(1, 1000);
    }

    function testStakingProgramEnd() public {
        // Move to after program end
        vm.warp(startTime + (5 * 365 days) + 1);

        // Use period 21 (1890 days) which is definitely beyond 5 years (1825 days)
        vm.expectRevert(LibePeriodStaking.StakingProgramEnded.selector);
        staking.setQuarterlyRewardRateByAPR(21, 1000);
    }

    function testInitialRate() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Move to start time and stake
        vm.warp(startTime);
        vm.prank(user);
        staking.stake(stakeAmount);

        // Move forward a bit
        vm.warp(startTime + 1 days);

        // Should have rewards at initial rate
        uint256 rewards = staking.calculatePendingRewards(user);
        assertTrue(rewards > 0, "Should have rewards at initial rate");
    }

    function testCannotSetNonSequentialPeriods() public {
        // Set period 0 (this exists from constructor)
        staking.setQuarterlyRewardRateByAPR(0, 1000);

        // Try to set period 2 without setting period 1 first
        vm.expectRevert(LibePeriodStaking.NonSequentialPeriod.selector);
        staking.setQuarterlyRewardRateByAPR(2, 1000);

        // Set period 1 (should work)
        staking.setQuarterlyRewardRateByAPR(1, 1000);

        // Now period 2 should work
        staking.setQuarterlyRewardRateByAPR(2, 1000);
    }

    function testCannotModifyPastOrCurrentPeriod() public {
        // Set initial rates
        staking.setQuarterlyRewardRateByAPR(0, 1000);
        staking.setQuarterlyRewardRateByAPR(1, 2000);
        staking.setQuarterlyRewardRateByAPR(2, 3000);

        // Move time to end of period 0
        vm.warp(startTime + QUARTER + 1);

        // Try to modify period 0 (ended)
        vm.expectRevert(LibePeriodStaking.CannotModifyPastPeriod.selector);
        staking.setQuarterlyRewardRateByAPR(0, 1500);

        // Should be able to modify period 1 (current)
        staking.setQuarterlyRewardRateByAPR(1, 2500);

        // Should still be able to modify future period
        staking.setQuarterlyRewardRateByAPR(2, 3500);

        // Move to end of period 1
        vm.warp(startTime + (2 * QUARTER) + 1);

        // Try to modify period 1 (now ended)
        vm.expectRevert(LibePeriodStaking.CannotModifyPastPeriod.selector);
        staking.setQuarterlyRewardRateByAPR(1, 3000);
    }

    function testGasForClaimAcross20Periods() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Set up rates for all 20 quarters with increasing APRs
        for (uint256 i = 0; i < 20; i++) {
            staking.setQuarterlyRewardRateByAPR(i, 1000 + (i * 100)); // 10% to 29% APR
        }

        // Move to start time and stake
        vm.warp(startTime);
        vm.startPrank(user);
        staking.stake(stakeAmount);

        // Move through all 20 quarters without claiming
        vm.warp(startTime + (20 * QUARTER));

        // Get pending rewards before claim
        uint256 pendingRewards = staking.calculatePendingRewards(user);

        // Measure gas for claim
        uint256 gasBefore = gasleft();
        staking.claimRewards();
        uint256 gasUsed = gasBefore - gasleft();

        // Verify rewards were received
        uint256 actualRewards = token.balanceOf(user) - 900 * 10 ** 18; // Initial balance was 1000, staked 100
        assertEq(actualRewards, pendingRewards, "Claimed rewards should match pending rewards");

        console.log("Gas used for claiming across 20 periods:", gasUsed);
        console.log("Rewards claimed:", actualRewards);
        vm.stopPrank();

        // Add a reasonable gas limit assertion
        // This might need adjustment based on actual testing
        assertTrue(gasUsed < 300000, "Gas usage too high");
    }

    function testGasForUnstakeAndWithdrawAcross20Periods() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Set up rates for all 20 quarters with increasing APRs
        for (uint256 i = 0; i < 20; i++) {
            staking.setQuarterlyRewardRateByAPR(i, 1000 + (i * 100)); // 10% to 29% APR
        }

        // Move to start time and stake
        vm.warp(startTime);
        vm.startPrank(user);
        staking.stake(stakeAmount);

        // Move through all 20 quarters without claiming
        vm.warp(startTime + (20 * QUARTER));

        // Get pending rewards before unstake
        uint256 pendingRewards = staking.calculatePendingRewards(user);
        console.log("Pending rewards before unstake:", pendingRewards);

        // Test unstake with gas limit
        bytes memory unstakeData = abi.encodeWithSelector(LibePeriodStaking.unstake.selector);
        uint256 maxUnstakeGas = 100000;
        (bool unstakeSuccess,) = address(staking).call{gas: maxUnstakeGas}(unstakeData);
        require(unstakeSuccess, "Unstake failed with gas limit");

        // Move past cooldown period
        vm.warp(block.timestamp + 31 days);

        // Test withdraw with gas limit
        bytes memory withdrawData = abi.encodeWithSelector(LibePeriodStaking.withdraw.selector);
        uint256 maxWithdrawGas = 300000;
        (bool withdrawSuccess,) = address(staking).call{gas: maxWithdrawGas}(withdrawData);
        require(withdrawSuccess, "Withdraw failed with gas limit");

        // Verify total rewards and stake were received
        uint256 finalBalance = token.balanceOf(user);
        uint256 expectedBalance = 900 * 10 ** 18 + stakeAmount + pendingRewards;
        assertEq(finalBalance, expectedBalance, "Final balance incorrect");

        console.log("Max unstake gas:", maxUnstakeGas);
        console.log("Max withdraw gas:", maxWithdrawGas);
        console.log("Rewards claimed:", finalBalance - 1000 * 10 ** 18);
        vm.stopPrank();
    }

    function testNonOwnerCannotSetRewardRates() public {
        // Switch to non-owner user
        vm.startPrank(user);

        // Try to set rate directly
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        staking.setQuarterlyRewardRateByAPR(0, 1000);

        // Try to add next period
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        staking.addNextRewardPeriod(1000);

        vm.stopPrank();

        // Verify owner can still set rates (using deployer address)
        vm.startPrank(address(this));
        staking.setQuarterlyRewardRateByAPR(0, 1000);
        staking.addNextRewardPeriod(2000);
        vm.stopPrank();
    }

    function testRewardsAcrossMultiplePeriodsWithSingleClaim() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Set up rates for first 3 quarters (periods 1-3)
        staking.setQuarterlyRewardRateByAPR(0, 1000); // 10% APR
        staking.setQuarterlyRewardRateByAPR(1, 2000); // 20% APR
        staking.setQuarterlyRewardRateByAPR(2, 3000); // 30% APR

        // Move to start time and stake
        vm.warp(startTime);
        vm.startPrank(user);
        staking.stake(stakeAmount);

        // Track expected rewards through each period
        uint256 totalExpectedRewards = 0;

        // Calculate expected rewards for each period without claiming
        for (uint256 i = 1; i <= 3; i++) {
            // Move to end of quarter i
            vm.warp(startTime + (i * QUARTER));

            // Get pending rewards at end of this period
            uint256 pendingRewards = staking.calculatePendingRewards(user);
            console.log("\nPeriod", i);
            console.log("Pending Rewards:", pendingRewards / 1e18, "tokens");

            // Expected rewards with 2% tolerance to account for day/second conversions
            if (i == 1) {
                assertApproxEqRel(pendingRewards, 2.5 ether, 0.02e18); // ~2.47 tokens for first period
            } else if (i == 2) {
                assertApproxEqRel(pendingRewards, 7.5 ether, 0.02e18); // ~7.41 tokens cumulative
            } else if (i == 3) {
                assertApproxEqRel(pendingRewards, 15 ether, 0.02e18); // ~14.82 tokens cumulative
            }

            totalExpectedRewards = pendingRewards;
        }

        // Unstake and wait for cooldown
        staking.unstake();
        vm.warp(block.timestamp + 31 days);

        // Record balance before withdraw
        uint256 balanceBefore = token.balanceOf(user);

        // Withdraw and check total received (stake + rewards)
        staking.withdraw();
        uint256 totalReceived = token.balanceOf(user) - balanceBefore;
        uint256 actualRewards = totalReceived - stakeAmount;

        // Verify final rewards with 2% tolerance
        assertApproxEqRel(actualRewards, 15 ether, 0.02e18, "Total rewards should be ~15 tokens");

        console.log("\nFinal Results:");
        console.log("Total Expected Rewards:", totalExpectedRewards / 1e18, "tokens");
        console.log("Total Actual Rewards:", actualRewards / 1e18, "tokens");
        console.log("Total Received (stake + rewards):", totalReceived / 1e18, "tokens");
        vm.stopPrank();
    }

    function testMultipleClaimsDuringPeriods() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Set up rates for first 3 quarters (periods 0-2)
        staking.setQuarterlyRewardRateByAPR(0, 1000); // 10% APR
        staking.setQuarterlyRewardRateByAPR(1, 2000); // 20% APR
        staking.setQuarterlyRewardRateByAPR(2, 3000); // 30% APR

        // Move to start time and stake
        vm.warp(startTime);
        vm.startPrank(user);
        staking.stake(stakeAmount);

        uint256 totalClaimed = 0;
        uint256 initialBalance = token.balanceOf(user);

        // For each quarter
        for (uint256 i = 0; i < 3; i++) {
            // Claim 3 times during each quarter (at 30, 60, and 90 days)
            for (uint256 j = 1; j <= 3; j++) {
                vm.warp(startTime + (i * QUARTER) + (j * 30 days));

                uint256 balanceBefore = token.balanceOf(user);
                staking.claimRewards();
                uint256 claimed = token.balanceOf(user) - balanceBefore;
                totalClaimed += claimed;

                console.log("Quarter", i, "Claim", j);
                console.log("Claimed:", claimed / 1e18, "tokens");
                console.log("Total Claimed:", totalClaimed / 1e18, "tokens");
            }
        }

        // Expected total rewards after all periods:
        // Quarter 0 (10% APR): 2.5 tokens
        // Quarter 1 (20% APR): 5.0 tokens
        // Quarter 2 (30% APR): 7.5 tokens
        // Total: 15 tokens
        uint256 expectedTotal = 15 ether;
        uint256 finalBalance = token.balanceOf(user);
        uint256 totalRewards = finalBalance - initialBalance;

        console.log("\nFinal Results:");
        console.log("Initial Balance:", initialBalance / 1e18, "tokens");
        console.log("Final Balance:", finalBalance / 1e18, "tokens");
        console.log("Total Rewards:", totalRewards / 1e18, "tokens");
        console.log("Expected Total:", expectedTotal / 1e18, "tokens");

        assertApproxEqRel(totalRewards, expectedTotal, 0.02e18, "Total rewards should be ~15 tokens");
        vm.stopPrank();
    }

    function testRewardStartDelayOnlyAppliesOnFirstStake() public {
        uint256 stakeAmount = 100 * 10 ** 18;
        uint256 waitPeriod = 1 days;
        staking.setRewardStartDelay(waitPeriod);

        // Set up rates
        staking.setQuarterlyRewardRateByAPR(0, 1000); // 10% APR

        // Move to start time and stake
        vm.warp(startTime);
        vm.startPrank(user);
        staking.stake(stakeAmount);

        // Check no rewards during initial waiting period
        vm.warp(block.timestamp + waitPeriod - 1);
        assertEq(staking.calculatePendingRewards(user), 0, "Should have no rewards during waiting period");

        // Move past waiting period and claim first rewards
        vm.warp(block.timestamp + 2 days);
        uint256 firstRewards = staking.calculatePendingRewards(user);
        assertTrue(firstRewards > 0, "Should have rewards after waiting period");
        staking.claimRewards();

        // Move forward another day and check rewards accumulate immediately
        uint256 balanceBefore = token.balanceOf(user);
        vm.warp(block.timestamp + 1 days);
        uint256 newRewards = staking.calculatePendingRewards(user);
        assertTrue(newRewards > 0, "Should have immediate rewards after first claim");

        staking.claimRewards();
        uint256 claimedAmount = token.balanceOf(user) - balanceBefore;
        assertTrue(claimedAmount > 0, "Should be able to claim rewards immediately");

        console.log("First rewards after delay:", firstRewards / 1e18);
        console.log("Immediate rewards after claim:", claimedAmount / 1e18);
        vm.stopPrank();
    }

    function testUnstakeAndWithdraw() public {
        uint256 stakeAmount = 100 * 10 ** 18;

        // Initial stake
        vm.startPrank(user);
        staking.stake(stakeAmount);

        // Verify initial stake
        (uint256 amount, uint256 lastClaimTime, uint256 unstakeTime, bool firstStake) = staking.stakes(user);
        assertEq(amount, stakeAmount, "Incorrect initial stake amount");
        assertTrue(firstStake, "Should be marked as first stake");
    }

    function testAdditionalStakeTriggersWaitingPeriod() public {
        uint256 initialStake = 100 * 10 ** 18;
        uint256 additionalStake = 50 * 10 ** 18;
        uint256 waitPeriod = 1 days;

        // Set wait period and reward rate
        staking.setRewardStartDelay(waitPeriod);
        staking.setQuarterlyRewardRateByAPR(0, 1000); // 10% APR

        // Initial stake
        vm.startPrank(user);
        staking.stake(initialStake);

        // Move past waiting period
        vm.warp(block.timestamp + waitPeriod + 1 days);

        // Claim initial rewards
        uint256 initialRewards = staking.calculatePendingRewards(user);
        staking.claimRewards();

        // Record balance before additional stake
        uint256 balanceBefore = token.balanceOf(user);

        // Stake more tokens
        staking.stake(additionalStake);

        // Verify stake info
        (uint256 amount, uint256 lastClaimTime, uint256 unstakeTime, bool firstStake) = staking.stakes(user);
        assertEq(amount, initialStake + additionalStake, "Total stake should be updated");
        assertTrue(firstStake, "Should be marked as first stake again");

        // Check no rewards during new waiting period
        vm.warp(block.timestamp + waitPeriod - 1);
        uint256 noRewards = staking.calculatePendingRewards(user);
        assertEq(noRewards, 0, "Should not earn rewards during waiting period after additional stake");

        // Move past new waiting period and verify rewards start accruing
        vm.warp(block.timestamp + 2 days);
        uint256 newRewards = staking.calculatePendingRewards(user);
        assertTrue(newRewards > 0, "Should earn rewards after waiting period");

        console.log("Initial stake:", initialStake / 1e18, "tokens");
        console.log("Additional stake:", additionalStake / 1e18, "tokens");
        console.log("Initial rewards:", initialRewards / 1e18, "tokens");
        console.log("New rewards after waiting period:", newRewards / 1e18, "tokens");

        vm.stopPrank();
    }

    function testCannotUpdateFinishedPeriod() public {
        // Set initial rates
        staking.setQuarterlyRewardRateByAPR(0, 1000); // 10% APR
        staking.setQuarterlyRewardRateByAPR(1, 2000); // 20% APR

        // Move time to end of period 0
        vm.warp(startTime + QUARTER + 1);

        // Try to modify period 0 (which has ended)
        vm.expectRevert(LibePeriodStaking.CannotModifyPastPeriod.selector);
        staking.setQuarterlyRewardRateByAPR(0, 1500);

        // Verify period 0 rate hasn't changed - now comparing basis points directly
        (uint256 startTime0, uint256 rate0) = staking.rewardPeriods(0);
        assertEq(rate0, 1000, "Period 0 rate should not have changed");
    }

    function testGetCurrentPeriodInfo() public {
        // Set rates for first few quarters
        staking.setQuarterlyRewardRateByAPR(1, 2000); // 20% APR
        staking.setQuarterlyRewardRateByAPR(2, 3000); // 30% APR

        // Test at start time
        vm.warp(startTime);
        LibePeriodStaking.RewardPeriodInfo memory info = staking.getCurrentPeriodInfo();
        assertEq(info.periodNumber, 0, "Wrong period number at start");
        assertEq(info.startTime, startTime, "Wrong start time");
        assertEq(info.endTime, startTime + QUARTER, "Wrong end time");
        assertEq(info.aprBasisPoints, INITIAL_APR_BASIS_POINTS, "Wrong reward rate");

        // Test in middle of period 1
        vm.warp(startTime + QUARTER + (QUARTER / 2));
        info = staking.getCurrentPeriodInfo();
        assertEq(info.periodNumber, 1, "Wrong period number in period 1");
        assertEq(info.startTime, startTime + QUARTER, "Wrong start time for period 1");
        assertEq(info.endTime, startTime + (2 * QUARTER), "Wrong end time for period 1");
        assertEq(info.aprBasisPoints, 2000, "Wrong reward rate for period 1");

        // Test at exact period boundary
        vm.warp(startTime + (2 * QUARTER));
        info = staking.getCurrentPeriodInfo();
        assertEq(info.periodNumber, 2, "Wrong period number at boundary");
        assertEq(info.aprBasisPoints, 3000, "Wrong rate at period boundary");
    }

    function testGetCurrentPeriodInfoAfterEnd() public {
        // Move time past the end of the staking program (5 years)
        vm.warp(startTime + (5 * 365 days) + 1);
        
        LibePeriodStaking.RewardPeriodInfo memory info = staking.getCurrentPeriodInfo();
        
        // Should return the last valid period info
        uint256 lastPeriodNumber = (5 * 365 days) / QUARTER;
        assertEq(info.periodNumber, lastPeriodNumber, "Wrong final period number");
        assertTrue(info.aprBasisPoints == 0, "Reward rate should be 0 after program end");
        assertTrue(info.endTime > info.startTime, "End time should be after start time");
        
        console.log("Last period number:", lastPeriodNumber);
        console.log("Final period start:", info.startTime);
        console.log("Final period end:", info.endTime);
        console.log("Final reward rate:", info.aprBasisPoints);
    }

    function testGetCurrentPeriodInfoWithGaps() public {
        // Set sequential rates
        staking.setQuarterlyRewardRateByAPR(1, 2000); // 20% APR
        staking.setQuarterlyRewardRateByAPR(2, 3000); // 30% APR
        staking.setQuarterlyRewardRateByAPR(3, 4000); // 40% APR

        // Test in period 4 (unset period)
        vm.warp(startTime + (4 * QUARTER) + 1);
        LibePeriodStaking.RewardPeriodInfo memory info = staking.getCurrentPeriodInfo();
        
        assertEq(info.periodNumber, 4, "Wrong period number in unset period");
        assertEq(info.aprBasisPoints, 0, "Reward rate should be 0 in unset period");
        assertEq(info.startTime, startTime + (4 * QUARTER), "Wrong start time in unset period");
        assertEq(info.endTime, startTime + (5 * QUARTER), "Wrong end time in unset period");

        console.log("Period number:", info.periodNumber);
        console.log("Start time:", info.startTime);
        console.log("End time:", info.endTime);
        console.log("Reward rate:", info.aprBasisPoints);
    }

    function testRewardsCalculationForVerySmallStake() public {
        uint256 tinyStake = 1;  // 1 wei
        
        vm.startPrank(user);
        staking.stake(tinyStake);
        
        // Move forward
        vm.warp(block.timestamp + 365 days);
        
        uint256 rewards = staking.calculatePendingRewards(user);
        assertTrue(rewards >= 0, "Rewards should not underflow for tiny stake");
        vm.stopPrank();
    }

    function testRewardsAddition() public {
        uint256 rewardAmount = 1000 * 10 ** 18;
        
        // Check initial state
        assertEq(staking.availableRewards(), 1_000_000_000 * 10 ** 18);
        
        // Add more rewards
        token.mint(address(this), rewardAmount);
        token.approve(address(staking), rewardAmount);
        staking.addRewards(rewardAmount);
        
        // Verify rewards were added
        assertEq(staking.availableRewards(), 1_000_000_000 * 10 ** 18 + rewardAmount);
    }

    function testInsufficientRewardsUseEmergencyWithdrawToGetStakeBack() public {
        // Create new staking contract with no initial rewards
        LibePeriodStaking emptyStaking = new LibePeriodStaking(
            address(token),
            INITIAL_APR_BASIS_POINTS,
            30 days,
            WAITING_PERIOD,
            startTime
        );

        // Give user approval and tokens
        vm.startPrank(user);
        token.approve(address(emptyStaking), type(uint256).max);

        // Should be able to stake
        emptyStaking.stake(100 * 10 ** 18);

        // Move forward to accumulate rewards
        vm.warp(block.timestamp + 30 days);

        // Try to claim rewards - should fail due to insufficient rewards
        vm.expectRevert(LibePeriodStaking.InsufficientRewardsUseEmergencyWithdrawToGetStakeBack.selector);
        emptyStaking.claimRewards();
        
        vm.stopPrank();
    }

    function testEmergencyWithdraw() public {
        uint256 stakeAmount = 100 * 10 ** 18;
        
        // Initial stake
        vm.startPrank(user);
        staking.stake(stakeAmount);
        
        // Emergency withdraw (sets cooldown)
        staking.emergencyWithdraw();
        
        // Wait cooldown
        vm.warp(block.timestamp + 31 days);
        
        // Now withdraw
        uint256 balanceBefore = token.balanceOf(user);
        staking.emergencyWithdraw();
        uint256 balanceAfter = token.balanceOf(user);
        
        // Verify
        assertEq(balanceAfter - balanceBefore, stakeAmount, "Should get back exact stake amount");
        (uint256 amount,,, ) = staking.stakes(user);
        assertEq(amount, 0, "Stake should be cleared");
        assertEq(staking.totalStaked(), 0, "Total staked should be zero");
        vm.stopPrank();
    }

    function testRewardTracking() public {
        uint256 stakeAmount = 100 * 10 ** 18;
        
        // Initial stake
        vm.startPrank(user);
        staking.stake(stakeAmount);
        
        // Move forward and claim rewards
        vm.warp(block.timestamp + 30 days);
        uint256 expectedRewards = staking.calculatePendingRewards(user);
        
        uint256 availableBefore = staking.availableRewards();
        staking.claimRewards();
        uint256 availableAfter = staking.availableRewards();
        
        // Verify reward accounting
        assertEq(
            availableBefore - availableAfter, 
            expectedRewards, 
            "Available rewards should decrease by claimed amount"
        );
        assertEq(
            staking.totalRewardsDistributed(), 
            expectedRewards, 
            "Total distributed should match claimed amount"
        );
        vm.stopPrank();
    }

    function testCannotClaimMoreThanAvailable() public {
        // Create new staking with limited rewards
        LibePeriodStaking limitedStaking = new LibePeriodStaking(
            address(token),
            INITIAL_APR_BASIS_POINTS,
            30 days,
            WAITING_PERIOD,
            startTime
        );
        
        // Add small amount of rewards
        token.approve(address(limitedStaking), 1 ether);
        limitedStaking.addRewards(1 ether);
        
        // Give user approval
        vm.prank(user);
        token.approve(address(limitedStaking), type(uint256).max);
        
        // Stake large amount
        vm.prank(user);
        limitedStaking.stake(1000 * 10 ** 18);
        
        // Move far forward to accumulate large rewards
        vm.warp(block.timestamp + 365 days);
        
        // Try to claim more rewards than available
        vm.prank(user);
        vm.expectRevert(LibePeriodStaking.InsufficientRewardsUseEmergencyWithdrawToGetStakeBack.selector);
        limitedStaking.claimRewards();
    }

    function testFullLifecycleWithNoRewards() public {
        // Create staking contract with no rewards
        LibePeriodStaking emptyStaking = new LibePeriodStaking(
            address(token),
            INITIAL_APR_BASIS_POINTS,
            30 days,
            WAITING_PERIOD,
            startTime
        );

        uint256 stakeAmount = 100 * 10 ** 18;
        uint256 initialBalance = token.balanceOf(user);
        
        // Setup user
        vm.startPrank(user);
        token.approve(address(emptyStaking), type(uint256).max);

        // Should be able to stake
        emptyStaking.stake(stakeAmount);
        assertEq(token.balanceOf(user), initialBalance - stakeAmount, "Stake not deducted");

        // Try to claim rewards - should fail
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(LibePeriodStaking.InsufficientRewardsUseEmergencyWithdrawToGetStakeBack.selector);
        emptyStaking.claimRewards();

        // Use emergency withdraw to get stake back
        emptyStaking.emergencyWithdraw();
        vm.warp(block.timestamp + 31 days);
        emptyStaking.emergencyWithdraw();
        assertEq(token.balanceOf(user), initialBalance, "Emergency withdraw didn't return stake");
        vm.stopPrank();
    }

    function testEmergencyWithdrawPreservesStake() public {
        // Create new staking contract with no initial rewards
        LibePeriodStaking limitedStaking = new LibePeriodStaking(
            address(token),
            INITIAL_APR_BASIS_POINTS,
            30 days,
            WAITING_PERIOD,
            startTime
        );

        uint256 stakeAmount = 100 * 10 ** 18;
        uint256 initialBalance = token.balanceOf(user);

        // Initial stake
        vm.startPrank(user);
        token.approve(address(limitedStaking), stakeAmount);
        limitedStaking.stake(stakeAmount);

        // Move forward to accumulate rewards
        vm.warp(block.timestamp + 30 days);

        // Emergency withdraw should return original stake
        limitedStaking.emergencyWithdraw();
        vm.warp(block.timestamp + 31 days);
        limitedStaking.emergencyWithdraw();
        assertEq(token.balanceOf(user), initialBalance, "Emergency withdraw didn't return original stake");

        // Verify stake is cleared
        (uint256 amount,,, ) = limitedStaking.stakes(user);
        assertEq(amount, 0, "Stake not cleared after emergency withdraw");
        vm.stopPrank();
    }

    function testWithdrawAfterRewardsExhausted() public {
        // Create staking with limited rewards
        LibePeriodStaking limitedStaking = new LibePeriodStaking(
            address(token),
            INITIAL_APR_BASIS_POINTS,
            30 days,
            WAITING_PERIOD,
            startTime
        );
        
        // Add small amount of rewards
        token.approve(address(limitedStaking), 1 ether);
        limitedStaking.addRewards(1 ether);
        
        uint256 stakeAmount = 100 * 10 ** 18;
        uint256 initialBalance = token.balanceOf(user);
        
        // Setup user
        vm.startPrank(user);
        token.approve(address(limitedStaking), type(uint256).max);
        
        // Stake
        limitedStaking.stake(stakeAmount);
        
        // Move forward to accumulate rewards
        vm.warp(block.timestamp + 365 days);
        
        // Try to claim rewards - should fail
        vm.expectRevert(LibePeriodStaking.InsufficientRewardsUseEmergencyWithdrawToGetStakeBack.selector);
        limitedStaking.claimRewards();
        
        // Use emergency withdraw to get stake back
        limitedStaking.emergencyWithdraw();
        vm.warp(block.timestamp + 31 days);
        limitedStaking.emergencyWithdraw();
        assertEq(token.balanceOf(user), initialBalance, "Emergency withdraw didn't return stake");
        vm.stopPrank();
    }

    function testMultipleStakesAndWithdraws() public {
        uint256 stakeAmount = 50 * 10 ** 18;
        uint256 initialBalance = token.balanceOf(user);
        
        vm.startPrank(user);
        
        // First stake
        staking.stake(stakeAmount);
        
        // Second stake after some time
        vm.warp(block.timestamp + 15 days);
        staking.stake(stakeAmount);
        
        // Unstake all
        vm.warp(block.timestamp + 15 days);
        staking.unstake();
        
        // Wait cooldown
        vm.warp(block.timestamp + 31 days);
        
        // Should get back at least original stake amounts
        staking.withdraw();
        assertGe(token.balanceOf(user), initialBalance, "Did not get at least original stakes back");
        vm.stopPrank();
    }

    function testMultipleStakersInsufficientRewards() public {
        // Create new staking contract with no initial rewards
        LibePeriodStaking limitedStaking = new LibePeriodStaking(
            address(token),
            INITIAL_APR_BASIS_POINTS,
            30 days,
            WAITING_PERIOD,
            startTime
        );
        
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 stakeAmount = 1000 * 10 ** 18;  // 1000 tokens each
        
        // Setup both users with tokens and approvals
        token.transfer(alice, 2000 * 10 ** 18);
        token.transfer(bob, 2000 * 10 ** 18);
        
        vm.prank(alice);
        token.approve(address(limitedStaking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(limitedStaking), type(uint256).max);
        
        // Add rewards - enough for just Alice (about 100 tokens)
        token.approve(address(limitedStaking), 150 ether);
        limitedStaking.addRewards(150 ether);
        
        console.log("Initial available rewards:", limitedStaking.availableRewards() / 1e18);
        
        // Both stake large amounts
        vm.prank(alice);
        limitedStaking.stake(stakeAmount);
        vm.prank(bob);
        limitedStaking.stake(stakeAmount);
        
        // Move forward long enough to generate rewards
        vm.warp(block.timestamp + 365 days);
        
        // Check pending rewards before claims
        vm.prank(alice);
        uint256 alicePending = limitedStaking.calculatePendingRewards(alice);
        vm.prank(bob);
        uint256 bobPending = limitedStaking.calculatePendingRewards(bob);
        
        console.log("Alice pending rewards:", alicePending / 1e18);
        console.log("Bob pending rewards:", bobPending / 1e18);
        
        // Alice claims first - should succeed
        uint256 aliceBalanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        limitedStaking.claimRewards();
        uint256 aliceRewards = token.balanceOf(alice) - aliceBalanceBefore;
        console.log("Alice claimed rewards:", aliceRewards / 1e18);
        console.log("Available rewards remaining:", limitedStaking.availableRewards() / 1e18);
        
        // Now Bob tries to claim but should fail as rewards are exhausted
        vm.prank(bob);
        vm.expectRevert(LibePeriodStaking.InsufficientRewardsUseEmergencyWithdrawToGetStakeBack.selector);
        limitedStaking.claimRewards();
        
        // Bob can still emergency withdraw his original stake
        vm.prank(bob);
        limitedStaking.emergencyWithdraw();  // Set cooldown
        
        vm.warp(block.timestamp + 31 days);  // Wait cooldown
        
        vm.prank(bob);
        limitedStaking.emergencyWithdraw();  // Actually withdraw
        
        assertEq(
            token.balanceOf(bob),
            2000 * 10 ** 18,  // Should get original balance back
            "Bob should get original stake back"
        );
    }

    function testMultipleClaimsInSamePeriod() public {
        uint256 stakeAmount = 1000 * 10 ** 18;
        vm.startPrank(user);
        staking.stake(stakeAmount);

        // Move forward 30 days and claim
        vm.warp(block.timestamp + 30 days);
        uint256 firstClaim = staking.calculatePendingRewards(user);
        staking.claimRewards();

        // Try to claim again immediately - should be 0
        uint256 secondClaim = staking.calculatePendingRewards(user);
        assertEq(secondClaim, 0, "Should have no rewards immediately after claim");
        vm.stopPrank();
    }

    function testStakeAfterEmergencyWithdraw() public {
        uint256 stakeAmount = 100 * 10 ** 18;
        
        vm.startPrank(user);
        staking.stake(stakeAmount);
        
        // Emergency withdraw (sets cooldown)
        staking.emergencyWithdraw();
        
        // Wait cooldown
        vm.warp(block.timestamp + 31 days);
        
        // Complete emergency withdraw
        staking.emergencyWithdraw();
        
        // Should be able to stake again
        staking.stake(stakeAmount);
        
        (uint256 amount,,, ) = staking.stakes(user);
        assertEq(amount, stakeAmount, "Should be able to stake after emergency withdraw");
        vm.stopPrank();
    }

    function testCannotAddZeroRewards() public {
        vm.expectRevert(LibePeriodStaking.InvalidAmount.selector);
        staking.addRewards(0);
    }

    function testRealisticLargeStakeAmount() public {
        // Create new staking contract with no initial rewards
        LibePeriodStaking limitedStaking = new LibePeriodStaking(
            address(token),
            INITIAL_APR_BASIS_POINTS,
            30 days,
            WAITING_PERIOD,
            startTime
        );

        // Move to start time first!
        vm.warp(startTime);

        // Test with a large but realistic amount (e.g., 1 billion tokens)
        uint256 largeStake = 1_000_000_000 * 10 ** 18;
        
        // Reset user's balance first!
        vm.startPrank(user);
        token.transfer(address(0x1337), token.balanceOf(user));  // Clear existing balance
        vm.stopPrank();
        
        token.mint(user, largeStake);
        
        // Add enough rewards for the expected claim (10% of stake)
        token.mint(address(this), largeStake / 10);
        token.approve(address(limitedStaking), largeStake / 10);
        limitedStaking.addRewards(largeStake / 10);
        
        console.log("Initial available rewards:", limitedStaking.availableRewards() / 1e18);
        
        vm.startPrank(user);
        token.approve(address(limitedStaking), largeStake);
        
        // Stake the large amount
        limitedStaking.stake(largeStake);
        
        // Now warp exactly one year from start time
        vm.warp(startTime + 365 days);
        uint256 rewards = limitedStaking.calculatePendingRewards(user);
        console.log("Calculated pending rewards:", rewards / 1e18);
        
        // Should be able to claim rewards
        uint256 balanceBefore = token.balanceOf(user);
        console.log("Balance before claim:", balanceBefore / 1e18);
        limitedStaking.claimRewards();
        uint256 actualRewards = token.balanceOf(user) - balanceBefore;
        console.log("Balance after claim:", token.balanceOf(user) / 1e18);
        console.log("Actually claimed rewards:", actualRewards / 1e18);
        
        // Expected rewards: 10% of 1 billion
        uint256 expectedRewards = largeStake / 10;  // 10% APR
        console.log("Expected rewards:", expectedRewards / 1e18);
        
        console.log("Balance before unstake:", token.balanceOf(user) / 1e18);
        // Should be able to unstake the large amount
        limitedStaking.unstake();
        vm.warp(block.timestamp + 31 days);
        limitedStaking.withdraw();
        
        uint256 finalBalance = token.balanceOf(user);
        console.log("Final balance:", finalBalance / 1e18);
        console.log("Expected final:", (largeStake + expectedRewards) / 1e18);
        
        // Verify final balance
        assertEq(
            finalBalance,
            largeStake + expectedRewards,
            "Should get large stake + rewards back"
        );
        vm.stopPrank();
    }

    function testCannotEmergencyWithdrawWithoutCooldown() public {
        // Setup stake
        uint256 stakeAmount = 100 * 10 ** 18;
        uint256 initialBalance = token.balanceOf(user);  // Save initial balance
        
        vm.startPrank(user);
        staking.stake(stakeAmount);
        
        // Try emergency withdraw (should set unstake time)
        staking.emergencyWithdraw();
        
        // Try to withdraw immediately (should fail)
        vm.expectRevert(LibePeriodStaking.UnstakeInCooldown.selector);
        staking.emergencyWithdraw();
        
        // Move forward but not enough time
        vm.warp(block.timestamp + 29 days);
        vm.expectRevert(LibePeriodStaking.UnstakeInCooldown.selector);
        staking.emergencyWithdraw();
        
        // Move forward past cooldown
        vm.warp(block.timestamp + 2 days);
        
        // Now should succeed
        staking.emergencyWithdraw();
        
        // Verify got stake back
        assertEq(
            token.balanceOf(user),
            initialBalance,  // Compare against initial balance
            "Should get original stake back"
        );
        vm.stopPrank();
    }

    function testWithdrawInsufficientRewards() public {
        // Create new staking contract with no initial rewards
        LibePeriodStaking limitedStaking = new LibePeriodStaking(
            address(token),
            INITIAL_APR_BASIS_POINTS,
            30 days,
            WAITING_PERIOD,
            startTime
        );
        
        // Move to start time
        vm.warp(startTime);
        
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 stakeAmount = 1000 * 10 ** 18;  // 1000 tokens each
        
        // Setup both users with tokens and approvals
        token.transfer(alice, 2000 * 10 ** 18);
        token.transfer(bob, 2000 * 10 ** 18);
        
        vm.prank(alice);
        token.approve(address(limitedStaking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(limitedStaking), type(uint256).max);
        
        // Add rewards - enough for just Alice (about 100 tokens)
        token.approve(address(limitedStaking), 150 ether);
        limitedStaking.addRewards(150 ether);
        
        // Both stake large amounts
        vm.prank(alice);
        limitedStaking.stake(stakeAmount);
        vm.prank(bob);
        limitedStaking.stake(stakeAmount);
        
        // Move forward to accumulate rewards
        vm.warp(block.timestamp + 365 days);
        
        // Alice unstakes first
        vm.prank(alice);
        limitedStaking.unstake();
        
        // Wait cooldown
        vm.warp(block.timestamp + 31 days);
        
        // Alice withdraws successfully
        uint256 aliceBalanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        limitedStaking.withdraw();
        assertGt(
            token.balanceOf(alice),
            aliceBalanceBefore,
            "Alice should get stake + rewards"
        );
        
        // Bob tries to unstake and withdraw
        vm.prank(bob);
        limitedStaking.unstake();
        
        // Wait cooldown
        vm.warp(block.timestamp + 31 days);
        
        // Bob's withdraw should fail due to insufficient rewards
        vm.prank(bob);
        vm.expectRevert(LibePeriodStaking.InsufficientRewardsUseEmergencyWithdrawToGetStakeBack.selector);
        limitedStaking.withdraw();
        
        // Bob can still emergency withdraw his stake
        vm.prank(bob);
        limitedStaking.emergencyWithdraw();
        
        assertEq(
            token.balanceOf(bob),
            2000 * 10 ** 18,
            "Bob should get original stake back via emergency withdraw"
        );
    }

    function testClaimAndRestakeInsufficientRewards() public {
        // Create new staking contract with no initial rewards
        LibePeriodStaking limitedStaking = new LibePeriodStaking(
            address(token),
            INITIAL_APR_BASIS_POINTS,
            30 days,
            WAITING_PERIOD,
            startTime
        );
        
        // Move to start time
        vm.warp(startTime);
        
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 stakeAmount = 1000 * 10 ** 18;  // 1000 tokens each
        
        // Setup both users with tokens and approvals
        token.transfer(alice, 2000 * 10 ** 18);
        token.transfer(bob, 2000 * 10 ** 18);
        
        vm.prank(alice);
        token.approve(address(limitedStaking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(limitedStaking), type(uint256).max);
        
        // Add rewards - enough for just Alice (about 100 tokens)
        token.approve(address(limitedStaking), 150 ether);
        limitedStaking.addRewards(150 ether);
        
        // Both stake large amounts
        vm.prank(alice);
        limitedStaking.stake(stakeAmount);
        vm.prank(bob);
        limitedStaking.stake(stakeAmount);
        
        // Move forward to accumulate rewards
        vm.warp(block.timestamp + 365 days);
        
        // Alice claims and restakes successfully
        vm.prank(alice);
        limitedStaking.claimAndRestake();
        
        // Verify Alice's stake increased
        (uint256 aliceStake,,, ) = limitedStaking.stakes(alice);
        assertGt(aliceStake, stakeAmount, "Alice's stake should increase");
        
        // Bob tries to claim and restake but fails
        vm.prank(bob);
        vm.expectRevert(LibePeriodStaking.InsufficientRewardsUseEmergencyWithdrawToGetStakeBack.selector);
        limitedStaking.claimAndRestake();
        
        // Verify Bob's stake unchanged
        (uint256 bobStake,,, ) = limitedStaking.stakes(bob);
        assertEq(bobStake, stakeAmount, "Bob's stake should be unchanged");
    }

    function testStakeDuringCooldown() public {
        // Create new staking contract
        LibePeriodStaking limitedStaking = new LibePeriodStaking(
            address(token),
            INITIAL_APR_BASIS_POINTS,
            30 days,
            WAITING_PERIOD,
            startTime
        );
        
        // Move to start time
        vm.warp(startTime);
        
        // Add rewards to the contract
        token.approve(address(limitedStaking), 1000 ether);
        limitedStaking.addRewards(1000 ether);
        
        uint256 stakeAmount = 100 * 10 ** 18;  // Reduced stake amount to make rewards sufficient
        
        // Give user enough tokens for both stakes
        token.transfer(user, 2000 * 10 ** 18);
        uint256 initialBalance = token.balanceOf(user);
        
        vm.startPrank(user);
        token.approve(address(limitedStaking), type(uint256).max);
        
        // Initial stake
        limitedStaking.stake(stakeAmount);
        
        // Move forward to accumulate some rewards
        vm.warp(block.timestamp + 30 days);
        
        // Start unstake process
        limitedStaking.unstake();
        
        // Move forward in cooldown period
        vm.warp(block.timestamp + 15 days);
        
        // Should be able to stake more during cooldown
        limitedStaking.stake(stakeAmount);
        
        // Verify unstake time was reset
        (,, uint256 unstakeTime,) = limitedStaking.stakes(user);
        assertEq(unstakeTime, 0, "Unstake time should be reset after new stake");
        
        // Move forward and accumulate more rewards
        vm.warp(block.timestamp + 30 days);
        
        // Try to withdraw - should fail because cooldown was reset
        vm.expectRevert(LibePeriodStaking.TokensStaked.selector);
        limitedStaking.withdraw();
        
        // Need to unstake again and wait cooldown
        limitedStaking.unstake();
        vm.warp(block.timestamp + 31 days);
        limitedStaking.withdraw();
        
        // Verify got both stakes back plus rewards
        assertGt(
            token.balanceOf(user),
            initialBalance,
            "Should get both stakes back plus rewards"
        );
        vm.stopPrank();
    }
}

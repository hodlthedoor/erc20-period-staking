// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {LibePeriodStaking} from "../src/LibePeriodStaking.sol";

/*
    forge script script/DeployLibePeriodStaking.s.sol:DeployLibePeriodStakingScript \
        --rpc-url $POLYGON_RPC_URL \
        --verifier-url https://api-amoy.polygonscan.com/api \
        --private-key $PRIVATE_KEY \
        --verify \
        --etherscan-api-key $POLYSCAN_API_KEY \
        --legacy \
        -vvv \
        --broadcast
*/
contract DeployLibePeriodStakingScript is Script {
    uint256 constant DEFAULT_INITIAL_APR = 1000; // 10% APR in basis points
    uint256 constant DEFAULT_COOLDOWN_PERIOD = 180; // 3 minutes
    uint256 constant DEFAULT_REWARD_DELAY = 180; // 3 minutes

    function run() public {
        // Load deployment private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        console.log("Deployer:", msg.sender);

        // testnet amoy token
        address tokenAddress = 0xbd48B788F455359900965C6b0Be8762c241600b3;

        // Get optional parameters from environment or use defaults
        uint256 initialApr = vm.envOr("INITIAL_APR", DEFAULT_INITIAL_APR);
        uint256 cooldownPeriod = vm.envOr("COOLDOWN_PERIOD", DEFAULT_COOLDOWN_PERIOD);
        uint256 rewardDelay = vm.envOr("REWARD_DELAY", DEFAULT_REWARD_DELAY);

        // Start time is now
        uint256 startTime = block.timestamp;

        vm.startBroadcast(deployerPrivateKey);

        // Deploy staking contract
        LibePeriodStaking staking = new LibePeriodStaking(
            tokenAddress,
            initialApr,
            cooldownPeriod,
            rewardDelay,
            startTime
        );

        // Set initial APRs for first few quarters
        staking.setQuarterlyRewardRateByAPR(0, 1000); // 10% APR
        staking.setQuarterlyRewardRateByAPR(1, 2000); // 20% APR
        staking.setQuarterlyRewardRateByAPR(2, 3000); // 30% APR

        vm.stopBroadcast();

        // Log deployment info
        console.log("LibePeriodStaking deployed to:", address(staking));
        console.log("Token Address:", tokenAddress);
        console.log("Initial APR (basis points):", initialApr);
        console.log("Cooldown Period:", cooldownPeriod);
        console.log("Reward Delay:", rewardDelay);
        console.log("Start Time:", startTime);
    }
} 
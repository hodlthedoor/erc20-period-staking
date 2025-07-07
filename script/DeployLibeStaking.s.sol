// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {LibeStaking} from "../src/LibeStaking.sol";

/*
        forge script script/DeployLibeStaking.s.sol:DeployLibeStakingScript 
        --rpc-url $POLYGON_RPC_URL --verifier-url https://api-amoy.polygonscan.com/api 
        --private-key $PRIVATE_KEY --verify --etherscan-api-key $POLYSCAN_API_KEY 
        --legacy -vvv --broadcast
    */
contract DeployLibeStakingScript is Script {
    uint256 constant DEFAULT_REWARD_RATE = 0.1 ether; // 0.1 tokens per second
    uint256 constant DEFAULT_COOLDOWN_PERIOD = 180; // 30 days; (3 minutes)

    function run() public {
        // Load deployment private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log(msg.sender);

        // testnet amoy token
        address tokenAddress = 0xbd48B788F455359900965C6b0Be8762c241600b3;

        // Get optional parameters from environment or use defaults
        uint256 rewardRate = vm.envOr("REWARD_RATE", DEFAULT_REWARD_RATE);
        uint256 cooldownPeriod = vm.envOr("COOLDOWN_PERIOD", DEFAULT_COOLDOWN_PERIOD);

        uint256 waitingPeriod = 12 hours;

        vm.startBroadcast(deployerPrivateKey);

        // Deploy staking contract
        LibeStaking staking = new LibeStaking(tokenAddress, rewardRate, cooldownPeriod, waitingPeriod);

        staking.setRewardRateByAPR(10000);

        vm.stopBroadcast();

        // Log deployment info
        console.log("LibeStaking deployed to:", address(staking));
        console.log("Token Address:", tokenAddress);
        console.log("Reward Rate:", rewardRate);
        console.log("Cooldown Period:", cooldownPeriod);
    }
}

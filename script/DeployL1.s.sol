// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {L1Token} from "../src/L1Token.sol";

// forge script script/DeployL1.s.sol:DeployL1Script --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --verify --etherscan-api-key $SEPOLIA_API_KEY --legacy --broadcast
contract DeployL1Script is Script {
    function setUp() public {}

    function run() public {
        vm.broadcast();

        address l1Token = address(new L1Token(1000 ether));
        console.log("L1Token deployed at: ", l1Token);
    }
}

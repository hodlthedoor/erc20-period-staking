// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {L2Token} from "../src/L2Token.sol";

// forge script script/DeployL2.s.sol:DeployL2Script --rpc-url $POLYGON_RPC_URL --private-key $PRIVATE_KEY --verify --etherscan-api-key $POLYSCAN_API_KEY --legacy --broadcast
contract DeployL2Script is Script {
    function setUp() public {}

    function run() public {
        vm.broadcast();

        address l2Token = address(new L2Token(1000 ether));
        console.log("L2Token deployed at: ", l2Token);
    }
}

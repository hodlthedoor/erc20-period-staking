// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {L2Escrow} from "../src/L2Escrow.sol";

contract DeployL2EscrowScript is Script {
    function setUp() public {}

    error UnsupportedChain(uint256 chainId);

    /*
        forge script script/DeployL2Escrow.s.sol:DeployL2EscrowScript 
        --rpc-url $POLYGON_RPC_URL --verifier-url https://api-amoy.polygonscan.com/api 
        --private-key $PRIVATE_KEY --verify --etherscan-api-key $POLYSCAN_API_KEY 
        --legacy -vvv --broadcast
    */

    function run() public {
        vm.startBroadcast();

        // Get the chain id to differentiate between Amoy testnet and Polygon mainnet
        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        address tokenAddress;
        address fxChild;
        address childChainManager;

        if (chainId == 137) {
            // Polygon mainnet addresses
            tokenAddress = 0xbd48B788F455359900965C6b0Be8762c241600b3;
            fxChild = 0x8397259c983751DAf40400790063935a11afa28a;
            childChainManager = 0xD9c7C4ED4B66858301D0cb28Cc88bf655Fe34861;
        } else if (chainId == 80002) {
            // Amoy testnet addresses
            tokenAddress = 0xbd48B788F455359900965C6b0Be8762c241600b3; // Same token address for testing
            fxChild = 0xE5930336866d0388f0f745A2d9207C7781047C0f;
            childChainManager = 0x4f9cd8a945EE035523979D7A120a23999D17D8C0;
        } else {
            revert UnsupportedChain(chainId);
        }

        // Deploy the L2Escrow contract
        address l2Escrow = address(new L2Escrow(tokenAddress, fxChild, childChainManager));
        console.log("L2Escrow deployed at: ", l2Escrow);

        vm.stopBroadcast();
    }
}

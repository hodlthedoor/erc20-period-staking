// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {L1Escrow} from "../src/L1Escrow.sol";

/*
        forge script script/DeployL1Escrow.s.sol:DeployL1EscrowScript 
        --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --verify 
        --etherscan-api-key $SEPOLIA_API_KEY --legacy -vvv --broadcast
    */
contract DeployL1EscrowScript is Script {
    function setUp() public {}

    error UnsupportedChain(uint256 chainId);

    function run() public {
        vm.startBroadcast();

        // Get the chain id to differentiate between Mainnet and Sepolia
        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        address checkpointManager;
        address fxRoot;
        address tokenAddress;
        address l2EscrowAddress;

        if (chainId == 1) {
            // Mainnet addresses
            checkpointManager = 0x86E4Dc95c7FBdBf52e33D563BbDB00823894C287;
            fxRoot = 0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2;
            tokenAddress = 0xb7b277E008E825faea27dd97A276EDa4B3F3db8e;
            l2EscrowAddress = 0xAf765224c71339C104a59828955992e169D02c4e; // Replace with actual L2Escrow address on Mainnet
        } else if (chainId == 11155111) {
            // Sepolia addresses
            checkpointManager = 0xbd07D7E1E93c8d4b2a261327F3C28a8EA7167209;
            fxRoot = 0x0E13EBEdDb8cf9f5987512d5E081FdC2F5b0991e;
            tokenAddress = 0x5a3A8238f9A0564b30B90AF267146504FCc303F1;
            l2EscrowAddress = 0xD9440513874aa9621C5286CF71F664EF19699bb3;
        } else {
            revert UnsupportedChain(chainId);
        }

        // Deploy the L1Escrow contract
        address l1Escrow = address(new L1Escrow(checkpointManager, fxRoot, tokenAddress));
        console.log("L1Escrow deployed at: ", l1Escrow);

        // Set the L2Escrow address as the fxChildTunnel in L1Escrow
        L1Escrow(l1Escrow).setFxChildTunnel(l2EscrowAddress);
        console.log("L2Escrow address set in L1Escrow contract.");

        vm.stopBroadcast();
    }
}

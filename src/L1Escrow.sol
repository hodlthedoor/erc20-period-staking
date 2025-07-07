    // SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@bridge/contracts/tunnel/FxBaseRootTunnel.sol";

contract L1Escrow is FxBaseRootTunnel, Ownable {
    IERC20 public immutable token; // ERC-20 token instance

    mapping(address => uint256) public escrowBalances;

    error NotSupported();
    error InvalidAmount();
    error TransferFailed();

    constructor(address _checkpointManager, address _fxRoot, address _token)
        FxBaseRootTunnel(_checkpointManager, _fxRoot)
        Ownable(msg.sender)
    {
        token = IERC20(_token);
    }

    function bridgeTokens(uint256 amount) external {
        if (amount == 0 || amount > token.balanceOf(msg.sender)) {
            revert InvalidAmount();
        }

        uint256 balance = token.balanceOf(address(this));

        // Transfer tokens from the user to this contract (escrow)
        token.transferFrom(msg.sender, address(this), amount);

        // Check if the tokens were transferred successfully
        if (token.balanceOf(address(this)) != (balance + amount)) {
            revert TransferFailed();
        }

        // Update the escrow balance
        escrowBalances[msg.sender] += amount;

        // Prepare the message to be sent to the Polygon contract
        bytes memory message = abi.encode(msg.sender, amount);

        // Send the message to the child tunnel
        _sendMessageToChild(message);
    }

    // This function is called when a message is received from Polygon
    function _processMessageFromChild(bytes memory data) internal override {
        revert NotSupported();
    }

    // Function to set the L2 contract address on Polygon
    function setFxChildTunnel(address _fxChildTunnel) public override onlyOwner {
        super.setFxChildTunnel(_fxChildTunnel);
    }

    // Withdraw tokens (for admin use or in emergencies)
    function withdrawTokens(uint256 amount, IERC20 token_) external onlyOwner {
        token_.transfer(msg.sender, amount);
    }

    function withdrawTokens(uint256 amount) external onlyOwner {
        token.transfer(msg.sender, amount);
    }
}

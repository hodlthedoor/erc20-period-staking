// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IChildToken.sol";
import "@bridge/contracts/tunnel/FxBaseChildTunnel.sol";

contract L2Escrow is FxBaseChildTunnel, AccessControl {
    IERC20 public immutable token;
    address public immutable childChainManager;
    mapping(uint256 => bool) public processedStates;
    address public l1Contract;

    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");

    event Escrow(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    error ZeroAddress();
    error InsufficientBalance();
    error TransferFailed();
    error OnlyChildChainManager();
    error IncorrectL1Contract();
    error AlreadyProcessed();

    constructor(address tokenAddress, address _fxChild, address childChainManager_) FxBaseChildTunnel(_fxChild) {
        if (tokenAddress == address(0) || childChainManager_ == address(0)) {
            revert ZeroAddress();
        }

        token = IERC20(tokenAddress);
        childChainManager = childChainManager_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(WITHDRAW_ROLE, msg.sender);
    }

    /**
     * @dev Withdraw function to simulate a token withdrawal.
     * This is protected by WITHDRAW_ROLE to allow only authorized accounts to perform withdrawals.
     */
    function withdraw(address to, uint256 amount) external onlyRole(WITHDRAW_ROLE) {
        if (token.balanceOf(address(this)) < amount) {
            revert InsufficientBalance();
        }
        if (!token.transfer(to, amount)) {
            revert TransferFailed();
        }

        emit Withdraw(to, amount);
    }

    function setL1Contract(address _l1Contract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        l1Contract = _l1Contract;
    }

    /**
     * @dev Process message from root (L1) chain.
     * This function handles the incoming message from the L1 contract.
     */
    function _processMessageFromRoot(uint256 stateId, address sender, bytes memory data) internal override {
        if (sender != l1Contract) {
            revert IncorrectL1Contract();
        }

        // Check if stateId was already processed
        if (processedStates[stateId]) {
            revert AlreadyProcessed();
        }

        processedStates[stateId] = true;

        (address user, uint256 amount) = abi.decode(data, (address, uint256));

        if (!token.transfer(user, amount)) {
            revert TransferFailed();
        }
    }
}

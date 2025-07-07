# ERC20 Period Staking with Cross-Chain Bridge

A comprehensive staking platform that operates across Ethereum (L1) and Polygon (L2) networks, featuring period-based staking rewards and secure cross-chain token bridging via the Polygon PoS Bridge (FxPortal).

## Features

### Period-Based Staking

- **Flexible Reward Periods**: Quarterly-based reward periods with configurable APR rates
- **Dynamic APR**: Adjustable APR basis points for each quarter
- **Time-Locked Staking**: Configurable unstake cooldown period (max 365 days)
- **Reward Delay**: Configurable delay before rewards start accruing
- **5-Year Program**: Fixed duration staking program (5 years from start)

### Reward System

- **APR-Based Rewards**: Rewards calculated based on:
  - Staked amount
  - APR for the period
  - Time in the staking period
- **Auto-Compounding**: Rewards are automatically added to stake
- **Reward Tracking**:
  - Total rewards distributed
  - Available rewards pool
  - Individual reward calculations

### Cross-Chain Architecture

- **Network Support**:
  - Ethereum (L1)
  - Polygon (L2)
- **Bridge Components**:
  - L1Escrow: Manages token locking on Ethereum
  - L2Escrow: Handles token minting on Polygon
  - Uses Polygon's FxPortal for secure cross-chain messaging

### Security Features

- **Safe Operations**:
  - OpenZeppelin's SafeERC20 implementation
  - Comprehensive error handling
  - Emergency withdrawal mechanisms
- **Access Control**:
  - Owner-controlled admin functions
  - Protected bridge operations
- **Safety Mechanisms**:
  - Unstaking cooldown period
  - Reward start delay
  - Maximum lock time constraints

## Technical Stack

- **Framework**: Foundry (Rust-based Ethereum development toolkit)
- **Smart Contracts**: Solidity ^0.8.0
- **Dependencies**:
  - OpenZeppelin Contracts
  - Polygon PoS Bridge (FxPortal)
  - forge-std (testing)

## Setup & Installation

1. **Install Foundry**

   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```

2. **Clone & Install Dependencies**

   ```bash
   git clone <repository-url>
   cd erc20-period-staking
   forge install
   ```

3. **Build**
   ```bash
   forge build
   ```

## Testing

Run the test suite:

```bash
forge test
```

Generate gas report:

```bash
forge snapshot
```

## Deployment

### L1 Deployment (Ethereum)

1. Deploy L1 Token:

   ```bash
   forge script script/DeployL1.s.sol:DeployL1Script --rpc-url <ethereum_rpc> --private-key <key>
   ```

2. Deploy L1 Escrow:
   ```bash
   forge script script/DeployL1Escrow.s.sol:DeployL1EscrowScript --rpc-url <ethereum_rpc> --private-key <key>
   ```

### L2 Deployment (Polygon)

1. Deploy L2 Token:

   ```bash
   forge script script/DeployL2.s.sol:DeployL2Script --rpc-url <polygon_rpc> --private-key <key>
   ```

2. Deploy L2 Escrow:

   ```bash
   forge script script/DeployL2Escrow.s.sol:DeployL2EscrowScript --rpc-url <polygon_rpc> --private-key <key>
   ```

3. Deploy Staking Contract:
   ```bash
   forge script script/DeployLibePeriodStaking.s.sol:DeployLibePeriodStakingScript --rpc-url <polygon_rpc> --private-key <key>
   ```

## Contract Interaction

### Staking Operations

1. **Stake Tokens**

   ```solidity
   stakingContract.stake(amount)
   ```

2. **Initiate Unstaking**

   ```solidity
   stakingContract.unstake()
   ```

3. **Withdraw After Cooldown**

   ```solidity
   stakingContract.withdraw()
   ```

4. **Claim Rewards**
   ```solidity
   stakingContract.claimRewards()
   ```

### Bridge Operations

1. **Bridge Tokens to L2**
   ```solidity
   l1Escrow.bridgeTokens(amount)
   ```

## Configuration

### Staking Parameters

- `unstakeCooldownTime`: Time required between unstaking and withdrawal
- `rewardStartDelay`: Delay before rewards start accruing
- `MAX_LOCK_TIME`: Maximum allowed lock time (365 days)
- `QUARTER`: Duration of each reward period (90 days)

### Bridge Parameters

- `checkpointManager`: Polygon checkpoint manager address
- `fxRoot`: FxRoot contract address on Ethereum
- `fxChild`: FxChild contract address on Polygon

## Security Considerations

1. **Staking Security**

   - Ensure sufficient rewards are available
   - Monitor APR adjustments
   - Verify unstaking cooldown periods

2. **Bridge Security**

   - Validate checkpoint submissions
   - Monitor bridge state
   - Regular balance reconciliation

3. **Admin Operations**
   - Controlled access to admin functions
   - Regular monitoring of reward rates
   - Emergency withdrawal capabilities

## License

MIT

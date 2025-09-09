# 🚀 Deployment Guide

## ConfluxModular Hook Deployment

### Prerequisites
- Foundry installed and configured
- Access to Ethereum mainnet/testnet
- Chainlink Functions subscription
- Sufficient ETH for deployment

### Step 1: Deploy Supporting Contracts

```bash
cd v4-template

# Deploy DaemonManager
forge create src/DaemonManager.sol:DaemonManager \
  --constructor-args <OWNER_ADDRESS> \
  --private-key <YOUR_PRIVATE_KEY> \
  --rpc-url <RPC_URL>

# Deploy ChainlinkOracle  
forge create src/ChainlinkOracle.sol:ChainlinkOracle \
  --constructor-args <ROUTER_ADDRESS> <DON_ID> <DAEMON_MANAGER_ADDRESS> <OWNER_ADDRESS> \
  --private-key <YOUR_PRIVATE_KEY> \
  --rpc-url <RPC_URL>
```

### Step 2: Calculate Hook Address

```bash
# Use HookMiner to find valid address
forge script script/HookMiner.s.sol \
  --constructor-args <POOL_MANAGER> <DAEMON_MANAGER> <CHAINLINK_ORACLE> <REBATE_TOKEN> \
  --required-flags "AFTER_INITIALIZE,BEFORE_SWAP,AFTER_SWAP,BEFORE_ADD_LIQUIDITY,BEFORE_REMOVE_LIQUIDITY"
```

### Step 3: Deploy ConfluxModular Hook

```bash
# Deploy to calculated address using CREATE2
forge create src/ConfluxModular.sol:ConfluxModular \
  --constructor-args <POOL_MANAGER> <DAEMON_MANAGER> <CHAINLINK_ORACLE> <REBATE_TOKEN> \
  --private-key <YOUR_PRIVATE_KEY> \
  --rpc-url <RPC_URL> \
  --create2 \
  --salt <CALCULATED_SALT>
```

### Step 4: Verification

```bash
# Verify contracts on Etherscan
forge verify-contract <DAEMON_MANAGER_ADDRESS> src/DaemonManager.sol:DaemonManager
forge verify-contract <CHAINLINK_ORACLE_ADDRESS> src/ChainlinkOracle.sol:ChainlinkOracle  
forge verify-contract <HOOK_ADDRESS> src/ConfluxModular.sol:ConfluxModular
```

## Contract Addresses

### Mainnet (when deployed)
- ConfluxModular Hook: `TBD`
- DaemonManager: `TBD`
- ChainlinkOracle: `TBD`

### Testnet (Sepolia)
- ConfluxModular Hook: `TBD`
- DaemonManager: `TBD`
- ChainlinkOracle: `TBD`

## Configuration

### Initial Setup
1. Set epoch duration in ChainlinkOracle
2. Add initial daemons to DaemonManager
3. Configure Chainlink Functions source code
4. Fund ChainlinkOracle with LINK tokens

### Security Considerations
- Use multi-sig for owner addresses
- Test thoroughly on testnet first
- Monitor gas usage and contract sizes
- Implement emergency pause mechanisms if needed

## Monitoring

### Key Metrics to Monitor
- Gas usage per transaction
- Contract balance changes
- Daemon activation/deactivation events
- Top epoch updates
- Failed transactions

### Recommended Tools
- Tenderly for transaction monitoring
- Dune Analytics for on-chain analytics
- Custom monitoring scripts for daemon health

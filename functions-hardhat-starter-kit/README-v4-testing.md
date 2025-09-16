# V4 Architecture Chainlink Functions Testing

This directory contains updated tests for the V4 architecture that integrates Foundry-built contracts with Chainlink Functions testing.

## Architecture Overview

The V4 system consists of:

- **ConfluxHook**: Uniswap V4 hook that manages rebates and daemon jobs
- **TopOracle**: Chainlink Functions client that maintains ranked daemon list
- **DaemonRegistryModerated**: Registry managing daemon contracts with moderation
- **LinearDaemon**: Example daemon implementation with linear rebate model
- **IDaemon**: Interface for daemon contracts

## Quick Start

### 1. Build and Copy Foundry Artifacts

```bash
cd /Users/vladissa/cursor_projects/Solidity_Projects/Chainlink_Playground/functions-hardhat-starter-kit
npm run build:v4
```

This will:
- Build your Foundry contracts in `v4-template/`
- Copy contracts to `contracts/v4/`
- Copy artifacts to `build/artifacts/`

### 2. Start Local Functions Testnet

```bash
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c
npm run startLocalFunctionsTestnet
```

### 3. Run V4 Test Cycle

```bash
# In a new terminal
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c
npm run test:v4
```

### 4. Run Unit Tests

```bash
npx hardhat test test/unit/V4Architecture.spec.js
```

## Manual Testing Steps

### Step 1: Deploy Daemons and Registry

```bash
TOTAL_DAEMONS=20 ACTIVE_DAEMONS=10 npx hardhat run scripts/00_deploy_v4_daemons_and_registry.ts --network localFunctionsTestnet
```

### Step 2: Deploy TopOracle

```bash
npx hardhat run scripts/02_deploy_v4_top_oracle.ts --network localFunctionsTestnet
```

### Step 3: Deploy ConfluxHook

```bash
npx hardhat run scripts/03_deploy_v4_conflux_hook.ts --network localFunctionsTestnet
```

### Step 4: Check State

```bash
npx hardhat run scripts/04_check_v4_state.ts --network localFunctionsTestnet
```

## Functions Request Configuration

The V4 system uses a new Functions request configuration:

- **Config File**: `functions/Functions-request-config-v4.js`
- **Source**: `functions/source/topDaemonsFromRegistry.js`
- **Args**: Registry address and block number
- **Return Type**: Packed uint256[8] with daemon IDs

## Key Differences from V3

### Registry Changes
- **DaemonRegistryModerated** replaces **PointsRegistry**
- Uses **IDaemon** interface instead of **IPoints**
- Supports daemon ownership and moderation
- **getRebateAmount(blockNumber)** instead of **getPoints()**

### Oracle Changes
- **TopOracle** replaces **Top3Consumer**
- Uses pre-encoded CBOR requests for gas efficiency
- Supports epoch-based updates
- Hook authority can trigger updates

### Hook Integration
- **ConfluxHook** integrates with Uniswap V4
- Manages rebate execution and daemon jobs
- Supports moderation of failing daemons
- Uses **BeforeSwapDelta** for rebate application

## Environment Variables

- `TOTAL_DAEMONS`: Number of daemons to deploy (default: 50)
- `ACTIVE_DAEMONS`: Number of daemons to activate (default: 25)
- `SEED`: RNG seed for reproducible test data
- `PRIVATE_KEY`: Wallet private key for transactions

## Testing Scenarios

### 1. Basic Integration
- Deploy all contracts
- Verify daemon registration and activation
- Check rebate amount calculations

### 2. Functions Request
- Set up TopOracle with request template
- Send Functions request for daemon ranking
- Verify top daemon list updates

### 3. Hook Execution
- Simulate swap with rebate token
- Verify daemon job execution
- Check rebate amount distribution

### 4. Moderation
- Test daemon deactivation on failure
- Verify ban functionality
- Check hook authority permissions

## Troubleshooting

### Common Issues

1. **Contract Not Found**: Run `npm run build:v4` to copy Foundry artifacts
2. **Compilation Errors**: Check Solidity version compatibility (0.8.30)
3. **Functions Request Fails**: Verify CBOR encoding and subscription funding
4. **Hook Permissions**: Ensure proper hook authority setup

### Debug Commands

```bash
# Check deployment artifacts
ls -la deploy-artifacts/

# Verify contract compilation
npx hardhat compile --force

# Check network configuration
npx hardhat console --network localFunctionsTestnet
```

## Next Steps

1. **CBOR Request Encoding**: Create proper Functions request template
2. **PoolManager Integration**: Connect with actual Uniswap V4 PoolManager
3. **Gas Optimization**: Optimize contract interactions for production
4. **Error Handling**: Add comprehensive error scenarios
5. **Performance Testing**: Test with larger daemon sets

## File Structure

```
functions-hardhat-starter-kit/
├── contracts/v4/                 # Copied from Foundry
│   ├── ConfluxHook.sol
│   ├── TopOracle.sol
│   ├── DaemonRegistryModerated.sol
│   └── ...
├── functions/
│   ├── Functions-request-config-v4.js
│   └── source/topDaemonsFromRegistry.js
├── scripts/
│   ├── build-and-copy-artifacts.js
│   ├── 00_deploy_v4_daemons_and_registry.ts
│   ├── 02_deploy_v4_top_oracle.ts
│   ├── 03_deploy_v4_conflux_hook.ts
│   ├── 04_check_v4_state.ts
│   └── full_cycle_v4.js
└── test/unit/
    └── V4Architecture.spec.js
```

# V4 Chainlink Functions Launch Commands

## Quick Start (TopOracle as the consumer)

### 1. Start Local Functions Testnet
```bash
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c
npm run startLocalFunctionsTestnet
```

### 2. Run Complete V4 Test Cycle (TopOracle flow)

**Option A: One-command full cycle**
```bash
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c
npm run test:v4:toporacle
```

**Option B: Manual step-by-step**
```bash
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c
node scripts/build-and-copy-artifacts.js
npx hardhat compile
npx hardhat run scripts/00_deploy_v4_daemons_and_registry.ts --network localFunctionsTestnet
npx hardhat run scripts/02_deploy_v4_top_oracle.ts --network localFunctionsTestnet
npx hardhat run scripts/05_setup_top_oracle_template_direct.ts --network localFunctionsTestnet
npx hardhat run scripts/09_check_top_oracle.ts --network localFunctionsTestnet
```

### 3. Alternative: V4Consumer Test (also working)
```bash
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c
npm run test:v4:consumer
```

## Individual Commands

### Build and Deploy (TopOracle flow)
```bash
# Build Foundry contracts and copy to Hardhat
node scripts/build-and-copy-artifacts.js

# Compile Hardhat contracts
npx hardhat compile

# Deploy V4 daemons and registry
npx hardhat run scripts/00_deploy_v4_daemons_and_registry.ts --network localFunctionsTestnet

# Deploy TopOracle (production consumer)
npx hardhat run scripts/02_deploy_v4_top_oracle.ts --network localFunctionsTestnet
```

### Set request template on TopOracle and send request
```bash
# Set template (direct params) and trigger refreshTopNow()
npx hardhat run scripts/05_setup_top_oracle_template_direct.ts --network localFunctionsTestnet
```

### Check Results (TopOracle)
```bash
# Check TopOracle state
npx hardhat run scripts/09_check_top_oracle.ts --network localFunctionsTestnet
```

## Configuration Files

- **Functions Source**: `functions/source/topDaemonsFromRegistry.js`
- **TopOracle Contract**: `contracts/v4/TopOracle.sol` (uses direct template params)

## Expected Results

The system will:
1. Deploy 50 LinearDaemon contracts
2. Activate 25 of them (random selection)  
3. Set TopOracle template with direct params (no CBOR encoding)
4. Trigger a real Functions request via `refreshTopNow()` with proper gas limits
5. Functions request gets fulfilled and TopOracle state updates
6. Display results with daemon IDs, addresses, and points - all properly ranked!

## Example Output
```
Top daemon IDs with points:
0: daemon ID = 5, address = 0x233e5109E604FEa39A955a91d88298AC64419fAC, points = 6391
1: daemon ID = 37, address = 0x26a2b45036a2CbA06d1dB9652a3C619E3f4b0243, points = 6391
2: daemon ID = 0, address = 0xdD489cf7c07E487CDD6061f4B01022d8e4543E56, points = 5630
...
```

## Troubleshooting

- **"No Hardhat config file found"**: Make sure you're in the `functions-hardhat-starter-kit` directory
- **"Transaction failed"**: This is normal in local testnet - the Functions request still executes
- **"secp256k1 unavailable"**: This is a warning and doesn't affect functionality

## Architecture

- **TopOracle**: Production consumer for Chainlink Functions (stores direct template params)
- **DaemonRegistryModerated**: V4 registry for managing daemons
- **LinearDaemon**: Example daemon implementation with `getRebateAmount()`
- **Chainlink Functions**: Off-chain computation for ranking daemons

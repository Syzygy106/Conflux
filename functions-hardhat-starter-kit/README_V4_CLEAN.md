# V4 Chainlink Functions - Clean Implementation

## Quick Start

### 1. Start Local Functions Testnet
```bash
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c
npm run startLocalFunctionsTestnet
```

### 2. Run Complete V4 Test Cycle
```bash
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c
npm run test:v4
```

## Essential Commands

| Command | Description |
|---------|-------------|
| `npm run startLocalFunctionsTestnet` | Start local Chainlink Functions testnet |
| `npm run test:v4` | Run complete TopOracle test cycle |
| `npm run build:v4` | Build Foundry contracts and copy to Hardhat |
| `npm run deploy:v4` | Deploy V4 daemons and TopOracle only |

## Architecture

- **TopOracle**: Production consumer for Chainlink Functions
- **DaemonRegistryModerated**: V4 registry for managing daemons  
- **LinearDaemon**: Example daemon implementation
- **Chainlink Functions**: Off-chain computation for ranking daemons

## Files Structure

### Essential Scripts
- `scripts/full_cycle_top_oracle.js` - Main orchestrator
- `scripts/startLocalFunctionsTestnetV4.js` - Start testnet
- `scripts/build-and-copy-artifacts.js` - Build Foundry contracts
- `scripts/00_deploy_v4_daemons_and_registry.ts` - Deploy daemons
- `scripts/02_deploy_v4_top_oracle.ts` - Deploy TopOracle
- `scripts/05_setup_top_oracle_template_direct.ts` - Setup template
- `scripts/09_check_top_oracle.ts` - Check results

### Essential Contracts
- `contracts/v4/TopOracle.sol` - Main consumer contract
- `contracts/v4/DaemonRegistryModerated.sol` - Registry contract
- `contracts/v4/examples/LinearDaemon.sol` - Example daemon
- `contracts/v4/base/DaemonRegistry.sol` - Base registry logic

### Functions Source
- `functions/source/topDaemonsFromRegistry.js` - Off-chain ranking logic
- `functions/Functions-request-config-v4.js` - Functions configuration

## Expected Results

The system will:
1. Deploy 50 LinearDaemon contracts
2. Activate 25 of them (random selection)
3. Deploy TopOracle with Functions subscription
4. Set template and trigger Functions request
5. Display ranked daemon results with points

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

## Clean Implementation

This implementation contains only the essential files needed for the working TopOracle flow:
- ✅ Removed all old V3 scripts and configs
- ✅ Removed V4Consumer (TopOracle is the production consumer)
- ✅ Removed debug and duplicate scripts
- ✅ Simplified package.json scripts
- ✅ Clean file structure with only necessary components

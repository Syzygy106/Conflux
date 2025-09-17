## Local V4 Full Cycle - Quick Start

This doc is ONLY for local testing with the Chainlink Functions local testnet. Sepolia deploy scripts stay in `scripts/deploy/` and are not used here.

### Prerequisites
- Node.js, npm
- Hardhat and Foundry installed
- `npm install` already executed in `functions-hardhat-starter-kit`

### One‑shot full cycle
Terminal 1:
```bash
cd functions-hardhat-starter-kit
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c
node scripts/local/startLocalFunctionsTestnetV4.js
```

Terminal 2:
```bash
cd functions-hardhat-starter-kit
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c
node scripts/local/full_cycle_top_oracle.js
```

What it does:
- Builds/copies Foundry artifacts
- Deploys 50 `LinearDaemon` and the `DaemonRegistryModerated`
- Deploys `TopOracle` locally and creates/funds a local subscription
- Sets the Functions template and triggers a request
- Prints TopOracle/Registry state and top daemons

### Manual step‑by‑step (alternative)
```bash
cd functions-hardhat-starter-kit
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c

# Start local Functions testnet in another terminal first
node scripts/local/startLocalFunctionsTestnetV4.js

# Build and copy artifacts
node scripts/build-and-copy-artifacts.js
npx hardhat compile

# Deploy registry + daemons
npx hardhat run scripts/00_deploy_v4_daemons_and_registry.ts --network localFunctionsTestnet

# Deploy TopOracle (local variant creates & funds subscription and saves it)
npx hardhat run scripts/local/02_deploy_v4_top_oracle.local.ts --network localFunctionsTestnet

# Configure template and trigger request (works for local and prod)
npx hardhat run scripts/deploy/05_setup_top_oracle_template_direct.ts --network localFunctionsTestnet

# Inspect current state
npx hardhat run scripts/deploy/09_check_top_oracle.ts --network localFunctionsTestnet
```

### Environment variables
- `PRIVATE_KEY` (required): local test private key; the default Hardhat key above is fine for local
- Optional: `SECOND_PRIVATE_KEY` to auto‑fund a second wallet when starting the local testnet
- Not needed on local: `TOP_ORACLE`, `SUBSCRIPTION_ID` (they are written/read from `deploy-artifacts/TopOracle.json`)

### Notes
- `scripts/local/startLocalFunctionsTestnetV4.js` updates `localFunctionsTestnet` section in `networks.js` with mock LINK and router addresses.
- On local, the Functions request uses inline secrets; DON‑hosted secrets are only for live networks.

### Troubleshooting
- invalid BigNumber value (subscription undefined):
  - Run `scripts/local/02_deploy_v4_top_oracle.local.ts` to create/fund a local subscription and write its ID to `deploy-artifacts/TopOracle.json`.
- Path errors (Cannot find module ../networks):
  - Ensure you run commands from `functions-hardhat-starter-kit` and use the exact script paths shown above.
- No LINK/ETH on local accounts:
  - The local testnet starter funds the wallet with 100 ETH and 100,000 LINK automatically.



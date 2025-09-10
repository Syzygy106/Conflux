# Top-3 Points PoC (Chainlink Functions + Hardhat local)

This PoC deploys 10 `Points` contracts with scores 1..10, stores them in a `PointsRegistry`, and uses a Chainlink Functions script to fetch all addresses, batch-call `getPoints()` via a multicall contract, sort off-chain, and write the top‑3 addresses back to the consumer.

Key files:
- `contracts/Points.sol`, `contracts/IPoints.sol`, `contracts/PointsRegistry.sol`
- `contracts/GasCappedMulticall.sol` (simple staticcall batcher)
- `contracts/Top3Consumer.sol` (Functions v1.0.0 consumer)
- `functions/source/top3FromRegistry.js` (registry.getAll → multicall getPoints → sort → return bytes)
- `functions/Functions-request-config.js` (auto-loads deployed addresses and sets args)

## Prerequisites
- Node.js 20+
- npm

## Install
```bash
cd /Users/vladissa/cursor_projects/Solidity_Projects/Chainlink_Playground/functions-hardhat-starter-kit
npm i
```

## 1) Start local Functions testnet
Terminal A:
```bash
cd /Users/vladissa/cursor_projects/Solidity_Projects/Chainlink_Playground/functions-hardhat-starter-kit
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c
npm run startLocalFunctionsTestnet
```
This starts a local chain on http://localhost:8545 and prints the Functions Router, DON ID, and LINK token. It also funds the account with ETH and LINK and updates `networks.js`.

## 2) Deploy and run end-to-end
Terminal B:
```bash
cd /Users/vladissa/cursor_projects/Solidity_Projects/Chainlink_Playground/functions-hardhat-starter-kit
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c

# (Optional) Compile
npx hardhat compile

# Deploy 10 Points (scores 1..10) and the Registry; writes deploy-artifacts/*.json
npx hardhat run scripts/00_deploy_points_and_registry.ts --network localFunctionsTestnet

# Deploy multicall helper (GasCappedMulticall); writes deploy-artifacts/GasCappedMulticall.json
npx hardhat run scripts/01b_deploy_multicall.ts --network localFunctionsTestnet

# (Optional) Sanity-check multicall works
npx hardhat run scripts/99_test_multicall.ts --network localFunctionsTestnet

# Deploy the consumer and auto-create + fund a subscription
npx hardhat run scripts/02_deploy_consumer.ts --network localFunctionsTestnet

# Send the Functions request (uses functions/Functions-request-config.js)
CONSUMER=$(node -p "require('./deploy-artifacts/Top3Consumer.json').address")
SUBID=$(node -p "require('./deploy-artifacts/Top3Consumer.json').subscriptionId")
SKIP_PROMPTS=1 npx hardhat functions-request \
  --network localFunctionsTestnet \
  --configpath functions/Functions-request-config.js \
  --contract $CONSUMER \
  --subid $SUBID \
  --simulate false \
  --callbackgaslimit 300000

# Verify the stored top-3 addresses in the consumer
npx hardhat run scripts/03_check_consumer_state.ts --network localFunctionsTestnet
```
You should see a “fulfilled!” message for the request and then three addresses printed by the check script. They will be the contracts with the highest `getPoints()` values (descending), with ties broken by lower address.

## Notes & Troubleshooting
- If the testnet script errors about `toHexString`, export `PRIVATE_KEY` before running `npm run startLocalFunctionsTestnet`.
- If the request fails due to insufficient LINK, re-run consumer deployment (it creates and funds the subscription), or adjust the funding amount in `utils/localSubscription.js`.
- The Functions script returns ABI-encoded `(address,address,address)` as bytes; the consumer decodes and stores them.

## Upstream starter kit
This project builds on: `https://github.com/smartcontractkit/functions-hardhat-starter-kit`



## LOCAL FULL TEST:

IN TERMINAL 1:

`cd /Users/vladissa/cursor_projects/Solidity_Projects/Chainlink_Playground/functions-hardhat-starter-kit
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c
npm run startLocalFunctionsTestnet`


IN TERMINAL 2:

`cd /Users/vladissa/cursor_projects/Solidity_Projects/Chainlink_Playground/functions-hardhat-starter-kit
export PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c
npm run full:cycle`
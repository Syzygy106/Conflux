## Sepolia deployment guide (TopOracle + LinearDaemons + ConfluxHook)

This is the exact, tested order for deploying on Sepolia using this repo. Run commands pedantically as shown.

### 0) Requirements
- Wallet funded with ETH and LINK on Sepolia
- Node + Hardhat (this package) and Foundry (for hook)
- QuickNode/Infura HTTPS RPC URL

Conventions:
- Run Hardhat scripts in `functions-hardhat-starter-kit/`
- Run Foundry hook script in `v4-template/`

### 1) Base env (Hardhat) + build artifacts
```bash
cd functions-hardhat-starter-kit
export PRIVATE_KEY=0x<YOUR_32_BYTE_HEX_PRIVATE_KEY>
export ETHEREUM_SEPOLIA_RPC_URL='https://<your-sepolia-rpc-url>'

# If you changed anything in v4-template/src, rebuild and copy artifacts first
node scripts/build-and-copy-artifacts.js
npx hardhat compile
```

### 2) DON-hosted secrets (HTTPS RPC URL)
Upload RPC URL and chainId to DON and capture slot/version.
```bash
# Example QuickNode URL and chainId
export RPC_URL='https://<your-sepolia-rpc-url>'
export CHAIN_ID=11155111
export SLOT_ID=1
export TTL_MIN=4300   # ~3 days max on testnets

npx hardhat run scripts/deploy/03_upload_don_secrets.ts --network ethereumSepolia

# Then export the values printed by the script
export DON_SECRETS_SLOT_ID=<slot>
export DON_SECRETS_VERSION=<version>
```

### 3) Deploy Registry (DaemonRegistryModerated)
```bash
npx hardhat run scripts/deploy/01_deploy_registry_only.ts --network ethereumSepolia
```
Artifacts: `deploy-artifacts/DaemonRegistryModerated.json` (contains `address`).

### 4) Deploy 5 LinearDaemons and add/activate in registry
```bash
export REGISTRY=<DaemonRegistryModerated.address>
npx hardhat run scripts/deploy/02_deploy_daemons_and_add.ts --network ethereumSepolia
```
Artifacts: `deploy-artifacts/DaemonSet.json` (contains `addresses`).

<!-- Moved below Hook deployment so we can approve the Hook as spender -->

### 6) Deploy TopOracle (no subscription logic here)
```bash
npx hardhat run scripts/deploy/02_deploy_v4_top_oracle.ts --network ethereumSepolia
```
Artifacts: `deploy-artifacts/TopOracle.json` (contains `address`).

### 7) Create Functions subscription (UI) and add consumer
- In Chainlink Functions UI, create/fund subscription
- Add `TopOracle.address` as a consumer to the subscription
```bash
export SUBSCRIPTION_ID=<your_sub_id>
```

### 8) Set Functions template on TopOracle and start epochs
This writes the current JS source (Functions) into the oracle template and triggers the first request.
```bash
export TOP_ORACLE=<TopOracle.address>
export SUBSCRIPTION_ID=<your_sub_id>
export DON_SECRETS_SLOT_ID=<slot>
export DON_SECRETS_VERSION=<version>

npx hardhat run scripts/deploy/05_setup_top_oracle_template_direct.ts --network ethereumSepolia
```
If you subsequently change the JS source at `functions/source/topDaemonsFromRegistry.js`, re-run this step.

### 9) (Optional) Manually trigger a refresh
```bash
npx hardhat run scripts/deploy/06_refresh_top_now.ts --network ethereumSepolia
```

### 10) Check oracle state
```bash
export TOP_ORACLE=<TopOracle.address>
export SUBSCRIPTION_ID=<your_sub_id>
npx hardhat run scripts/deploy/09_check_top_oracle.ts --network ethereumSepolia
```
You should see `topCount > 0` once the request is fulfilled.

### 11) Deploy ConfluxHook (Foundry, EVM Cancun)
ConfluxHook must be deployed via Foundry with proper flags (address mining is handled inside the script).
```bash
cd ../v4-template
export TOP_ORACLE=<TopOracle.address>
export REGISTRY=<DaemonRegistryModerated.address>
export REBATE_TOKEN=0x779877A7B0D9E8603169DdbD7836e478b4624789

forge script script/00_DeployHook.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```
Note the deployed hook address from the broadcast logs (or output).

### 12) Wire hook authorities
Give the hook moderation/trigger rights on registry and oracle.
```bash
cd ../functions-hardhat-starter-kit
export HOOK=<ConfluxHook.address>
export TOP_ORACLE=<TopOracle.address>
npx hardhat run scripts/deploy/04_wire_hook_authorities.ts --network ethereumSepolia
```

### 13) Configure daemons (rebate token, funding, approvals)
Run AFTER the hook is deployed so we can approve it as spender. The script:
- sets rebate token (LINK by default),
- transfers LINK to each daemon,
- approves BOTH the Hook and PoolManager as spenders,
- optionally funds each daemon with ETH for gas.

```bash
# Defaults if not overridden:
# REBATE_TOKEN=0x779877A7B0D9E8603169DdbD7836e478b4624789   # LINK Sepolia
# REBATE_AMOUNT=1        # 1 LINK per daemon
# REBATE_ETH=0.05        # 0.05 ETH per daemon

export HOOK=<ConfluxHook.address>
npx hardhat run scripts/deploy/03_configure_daemons.ts --network ethereumSepolia
```
Notes:
- The script now requires `HOOK` and approves it as the ERC20 spender (the Hook calls `transferFrom`).
- It also approves PoolManager for completeness.

### 14) (Optional) Create pool and add liquidity (Foundry)
If you need to stand up a pool involving the rebate token and your custom token:
```bash
cd ../v4-template
export TOKEN0=<token0_address>
export TOKEN1=<token1_address>
export HOOK=<ConfluxHook.address>

# Amounts in raw wei of each token
export AMOUNT0_WEI=<amount_for_token0_in_wei>
export AMOUNT1_WEI=<amount_for_token1_in_wei>

forge script script/01_CreatePoolAndAddLiquidity.s.sol:CreatePoolAndAddLiquidityScript \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### 15) (Optional) Tiny swap to validate rebate (Foundry)
Execute a very small swap to trigger the Hook and observe a rebate payment.
```bash
cd ../v4-template
export TOKEN0=<token0_address>
export TOKEN1=<token1_address>
export HOOK=<ConfluxHook.address>

# Tiny input and direction
export SWAP_IN_WEI=100            # very small amount
export SWAP_ZERO_FOR_ONE=true     # token0 -> token1; set false for token1 -> token0
export SWAP_DEADLINE_SEC=3600     # 1 hour

forge script script/03_Swap.s.sol:SwapScript \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

Validate on-chain events (example commands):
```bash
# Swap tx receipt
cast receipt <swap_tx_hash> --rpc-url $ETHEREUM_SEPOLIA_RPC_URL

# Hook logs (look for RebateExecuted and DaemonJobSuccess)
cast logs --address <ConfluxHook.address> --from-block 0 --to-block latest --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

---

### Troubleshooting
- Permission Denied in Functions execution:
  - Ensure `functions/source/topDaemonsFromRegistry.js` uses `Functions.makeHttpRequest` (already implemented)
  - `secrets.rpcUrl` must be HTTPS; reupload DON secrets and re-run template setup
- Wrong oracle address in check/setup:
  - Export `TOP_ORACLE=<address>` to override artifact address
- No top entries after request:
  - Confirm subscription has funds, TopOracle is added as consumer, and request mined
- TTL limits for testnets: up to ~4320 minutes; reupload secrets before expiry

### References
- Hardhat scripts: `functions-hardhat-starter-kit/scripts/deploy/`
- Artifacts: `functions-hardhat-starter-kit/deploy-artifacts/`
- Functions source: `functions-hardhat-starter-kit/functions/source/topDaemonsFromRegistry.js`
- Foundry hook script: `v4-template/script/00_DeployHook.s.sol`



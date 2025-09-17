## Sepolia deployment guide (TopOracle + LinearDaemons + ConfluxHook)

This is the exact, tested order for deploying on Sepolia using this repo. Run commands pedantically as shown.

### 0) Requirements
- Wallet funded with ETH and LINK on Sepolia
- Node + Hardhat (this package) and Foundry (for hook)
- QuickNode/Infura HTTPS RPC URL

Conventions:
- Run Hardhat scripts in `functions-hardhat-starter-kit/`
- Run Foundry hook script in `v4-template/`

### 1) Base env (Hardhat)
```bash
cd functions-hardhat-starter-kit
export PRIVATE_KEY=0x<YOUR_32_BYTE_HEX_PRIVATE_KEY>
export ETHEREUM_SEPOLIA_RPC_URL='https://<your-sepolia-rpc-url>'
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

### 5) Configure daemons (rebate token and approvals)
Sends 1 LINK and approves PoolManager to pull it; funds each daemon with 0.05 ETH.
```bash
# Defaults used if not overridden:
# REBATE_TOKEN=0x779877A7B0D9E8603169DdbD7836e478b4624789 (LINK Sepolia)
# REBATE_AMOUNT=1   # 1 LINK
# REBATE_ETH=0.05   # 0.05 ETH

npx hardhat run scripts/deploy/03_configure_daemons.ts --network ethereumSepolia
```
Note: PoolManager (Sepolia) is auto-selected from AddressConstants for chain 11155111.

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



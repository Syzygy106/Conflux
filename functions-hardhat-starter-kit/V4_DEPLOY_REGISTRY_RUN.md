## Deploy DaemonRegistryModerated (Sepolia)

Minimal env + command to deploy only the Registry using the current wallet.

```bash
export PRIVATE_KEY=0x<YOUR_32_BYTE_HEX_PRIVATE_KEY>
export ETHEREUM_SEPOLIA_RPC_URL='https://<your-sepolia-rpc-url>'

npx hardhat run scripts/01_deploy_registry_only.ts --network ethereumSepolia
```

On success, address is saved to `functions-hardhat-starter-kit/deploy-artifacts/DaemonRegistryModerated.json`.



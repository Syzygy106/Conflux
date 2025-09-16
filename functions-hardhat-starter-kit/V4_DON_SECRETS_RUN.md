## DON-hosted secrets upload (Sepolia)

Minimal env and command to upload RPC URL + chainId to the DON, then print slot/version.

```bash
# Required: funded deployer and Sepolia RPC for Hardhat
export PRIVATE_KEY=0x<YOUR_32_BYTE_HEX_PRIVATE_KEY>
export ETHEREUM_SEPOLIA_RPC_URL='https://<your-sepolia-rpc-url>'

# Secrets to store in DON (examples)
export RPC_URL='https://<your-sepolia-rpc-url>'
export CHAIN_ID=11155111
export SLOT_ID=1
export TTL_MIN=4300   # ~<3 days max on testnets>

# Optional: if you keep a separate token (not needed when key is in URL)
# export HTTP_NODE_KEY='<api_or_bearer_key>'

# Upload and print slot/version
npx hardhat run scripts/03_upload_don_secrets.ts --network ethereumSepolia

# Then export for setup scripts:
# export DON_SECRETS_SLOT_ID=<slot>
# export DON_SECRETS_VERSION=<version>
```



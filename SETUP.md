## Project Setup (Clean Machine)

This guide covers installing required tools and preparing the workspace for both local testing and Sepolia deployment. Follow in order.

### 1) System prerequisites
- macOS/Linux (Windows: use WSL2)
- Git 2.30+
- Node.js 18+ and npm 8+
  - Recommended via nvm: `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash`
  - `nvm install 18 && nvm use 18`
- Foundry (forge/cast)
  - `curl -L https://foundry.paradigm.xyz | bash`
  - `foundryup`
- Optional CLIs (helpful)
  - jq: `brew install jq` (macOS) or `apt-get install jq` (Linux)

### 2) Clone the repository
```bash
git clone https://github.com/<your_org>/Chainlink_Playground.git
cd Chainlink_Playground
```

No git submodules are required. Dependencies for the Foundry project are vendored under `v4-template/lib/`.

### 3) Install JavaScript dependencies (Hardhat workspace)
```bash
cd functions-hardhat-starter-kit
# Husky is not used; skip prepare scripts to avoid git-hook errors
HUSKY=0 npm ci
```

### 4) Verify Foundry toolchain and build v4 contracts
```bash
cd ../v4-template
forge --version
forge build
```

This compiles Uniswap v4 hook contracts and our on-chain components used by the Hardhat scripts.

### 5) Prime Hardhat with v4 artifacts
```bash
cd ../functions-hardhat-starter-kit
node scripts/build-and-copy-artifacts.js
npx hardhat compile
```

### 6) Next steps by workflow
- Local full cycle (Functions local testnet): see `functions-hardhat-starter-kit/README_LOCAL.md`
- Sepolia deployment: see `functions-hardhat-starter-kit/DEPLOY_SEPOLIA.md`

### Environment variables quick note
- For local: only `PRIVATE_KEY` is needed (local test key is fine, see README_LOCAL.md)
- For Sepolia: set `PRIVATE_KEY`, `ETHEREUM_SEPOLIA_RPC_URL`, `DON_SECRETS_SLOT_ID`, `DON_SECRETS_VERSION` (see DEPLOY_SEPOLIA.md)

### Troubleshooting
- Husky error during npm install: use `HUSKY=0 npm ci` or `npm ci --ignore-scripts`.
- Hardhat warns about Solidity 0.8.30 support: harmless; compilation still works.
- If `forge` is not found, open a new shell (adds Foundry to PATH) or rerun `foundryup`.
- If artifact copy fails initially, ensure step 4 (Foundry build) completed, then rerun step 5.



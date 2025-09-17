# Chainlink Functions + Uniswap v4 Hook (Conflux)

This repository integrates Chainlink Functions with a Uniswap v4 hook to implement a daemon‑driven rebate mechanism.

## 🏗️ Layout

- `functions-hardhat-starter-kit/` — Hardhat workspace for Chainlink Functions (TopOracle, deploy scripts, local DON, Sepolia deploy)
- `v4-template/` — Foundry workspace for the Uniswap v4 hook and on‑chain components (ConfluxHook, DaemonRegistryModerated)

## 📚 Docs index

- Setup: `SETUP.md`
- Sepolia deploy (commands): `functions-hardhat-starter-kit/DEPLOY_SEPOLIA.md`
- Local run (commands): `functions-hardhat-starter-kit/TEST_LOCAL.md`
- Local concepts: `functions-hardhat-starter-kit/LOCAL_TESTING_OVERVIEW.md`
- Sepolia concepts: `functions-hardhat-starter-kit/SEPOLIA_TESTING_OVERVIEW.md`
- Hook: `v4-template/HOOK.md`
- Registry: `v4-template/REGISTRY.md`
- Oracle: `v4-template/ORACLE.md`

## 🔌 Compatibility

- Chainlink Functions contracts are Paris‑compatible (deployed via Hardhat)
- Uniswap v4 Hooks require Cancun (EIP‑1153); deploy hook via Foundry

## 🔧 Quick start

See `SETUP.md` for prerequisites and the initial build/copy steps.

## 🧪 Tests

- Foundry unit tests live in `v4-template/test/`
- Local end‑to‑end Functions flow via `functions-hardhat-starter-kit/scripts/local/*`

## 📝 License

MIT — see individual directories for license headers where applicable.

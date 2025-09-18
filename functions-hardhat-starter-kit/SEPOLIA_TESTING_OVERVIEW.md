## Sepolia Deployment Overview (Concepts)

This document explains the intent behind deploying to Sepolia with Chainlink Functions. For exact commands, see `DEPLOY_SEPOLIA.md`.

### Goals
- Realistically validate the Chainlink Functions lifecycle on a public network:
  - request → DON computation → on-chain fulfill
- Prove integration with live DON-hosted secrets and a funded subscription
- Confirm that `TopOracle` stores ranked daemon ids derived from the on-chain registry

### What’s different vs local
- Secrets: on Sepolia, the DON must read encrypted secrets (HTTPS RPC URL, chainId) from the DON secret store
- Subscription: you must create/fund a real Functions subscription and add `TopOracle` as a consumer
- Networking: Functions compute runs on DON nodes and can access HTTP endpoints via the Chainlink gateways; direct provider objects are not permitted
- Gas/confirmations: transactions and fulfill happen on real chain with normal block times

### Key Components
- DON-hosted secrets (slot/version): encrypt and upload your `rpcUrl`, `chainId`
- Subscription (ID): funds that pay for Functions requests
- `DaemonRegistryModerated`: source of daemon addresses and activation state
- `TopOracle`: Functions client that stores template parameters, sends requests, and processes fulfill

### High-level Flow
1) Prepare DON-hosted secrets
   - Upload `rpcUrl` and `chainId` to the DON; record `slot/version`
2) Deploy registry and daemons, then activate
3) Deploy `TopOracle`
4) Create/fund subscription in the Chainlink Functions UI; add `TopOracle` as consumer
5) Set request template on `TopOracle`
   - Use the current off-chain JS source (`functions/source/topDaemonsFromRegistry.js`)
   - Reference DON-hosted secrets (`slot/version`) and set `subscriptionId`
6) Trigger first request and observe fulfill
   - `TopOracle` should set `hasPendingTopRequest`, then, on fulfill, store packed top ids and compute `topCount`
7) Deploy Uniswap v4 Hook and wire authorities
   - Deploy `ConfluxHook` via Foundry (Cancun)
   - Set `hookAuthority` on registry and grant hook rights on oracle
8) Configure daemons for rebates
   - Set rebate token (LINK), fund daemons with LINK and a bit of ETH
   - Approve the Hook as ERC20 spender (required), and optionally the PoolManager
9) Validate with a tiny swap
   - Perform a minimal swap through the hook-enabled pool and observe rebate/job events

### Validation checklist
- Template stored on `TopOracle` (tx confirmed)
- `refreshTopNow()` succeeds and emits a request ID
- Functions UI shows request received and computed (no “blocked resource” errors)
- `TopOracle` after fulfill: `topCount > 0`, `hasPendingTopRequest == false`, epoch updated
- Hook wired as authority on both registry and oracle
- Daemons have LINK balance and ERC20 allowance to the Hook
- Tiny swap emits `RebateExecuted(daemonId, amount)` and `DaemonJobSuccess(daemonId)`

### Common pitfalls (Sepolia)
- Template tx not mined before refresh → "tpl not set"; wait 1–2 confirmations
- Missing/expired DON secrets → request fails on DON; re-upload and re-run template setup
- `TopOracle` not added as consumer → request rejected; fix in UI and retry
- Insufficient LINK in subscription → request not executed; fund and retry
- No allowance to Hook from daemon → rebate transferFrom fails; approve Hook as spender
- Pool without rebate token → hook initialization reverts for that pool

### Iteration/Rollback
- If off-chain JS source changes, re-run the template setup step to replace the inline source
- If registry/daemons change, it only affects the next request; no re-deploy of `TopOracle` needed

### After validation
- Deploy the Uniswap v4 Hook (Foundry, Cancun) and wire authorities so the hook can trigger/iterate epochs and moderate daemons
- Configure and fund daemons (LINK + ETH), set approvals to Hook (required) and PoolManager (optional)
- Keep subscription funded and rotate secrets before TTL expiry

### Compatibility and risks
- EVM Paris vs Cancun
  - Chainlink Functions contracts are Paris-compatible and do not require Cancun-only opcodes
  - Uniswap v4 Hooks rely on EIP-1153 (transient storage TLOAD/TSTORE), enabled only with Cancun
  - Therefore we split toolchains: Functions/registry/oracle via Hardhat (Paris target), Hook via Foundry (Cancun target)
- Versions (don’t bump blindly)
  - Functions toolkit requires ethers v5.x; this repo pins `ethers@^5.7` and `@chainlink/functions-toolkit@^0.2`
  - Upgrading ethers/toolkit without checking release notes can break request encoding or providers
- Ops hygiene
  - Ensure subscription has LINK before requests
  - DON-hosted secrets expire (TTL). Re-upload before expiry and re-run template setup
  - Local DON is a simulation; always validate at least one full request/fulfill on Sepolia

### Notes on amounts and pricing
- Rebate amounts returned by daemons are token wei (raw units). If you expect e.g. 0.01 LINK, return `1e16`
- Pool initialization price affects which side’s amount is consumed when adding liquidity. Consider parameterizing initial tick if you need asymmetric amounts consumed.



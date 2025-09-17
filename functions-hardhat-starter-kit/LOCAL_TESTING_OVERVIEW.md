## Local Testing Overview (Concepts)

This document explains what happens during the local full cycle and why. For concrete commands, see `TEST_LOCAL.md`.

### Goals
- Primary: validate Chainlink Functions lifecycle end-to-end (request → DON compute → fulfill) with production-like behavior and zero cost
- Secondary: verify on-chain integration points (registry reads, template storage in oracle, epoching) that Chainlink interacts with
- Result: `TopOracle` gets populated with ranked daemon ids calculated from the registry

### Key Components
- Local Functions Testnet (Ganache + mock DON): simulates Chainlink Functions off-chain runtime.
- `DaemonRegistryModerated`: stores daemon contracts, activation flags and moderation state.
- `LinearDaemon` (examples): simple, deterministic rebate model used for ranking.
- `TopOracle`: Chainlink Functions client that stores a ranked top set and triggers updates.

### High-level Flow
1) Start Local Functions Testnet
   - Spins up a local chain and a mock DON
   - Seeds your wallet with test ETH and LINK
   - Writes local addresses (router, LINK, DON ID) into `networks.js`

2) Build/copy artifacts
   - Foundry compiles contracts in `v4-template/`
   - Artifacts and source files are copied into the Hardhat project so scripts can deploy them

3) Deploy registry and daemons
   - Deploys `DaemonRegistryModerated`
   - Deploys multiple `LinearDaemon` with varied parameters
   - Adds and activates daemons in the registry

4) Deploy `TopOracle` and create a local subscription
   - Deploys `TopOracle` with local Functions router/DON ID
   - Creates/funds a local subscription and saves `subscriptionId` alongside the oracle address

5) Configure Functions template and trigger request
   - Writes the current request JS source (`functions/source/topDaemonsFromRegistry.js`) directly into `TopOracle`
   - Uses inline secrets for local run (no DON-hosted secrets required)
   - Triggers `refreshTopNow()` to send a Functions request to the local DON

6) Read results and verify state
   - When fulfill completes, `TopOracle` stores up to 128 daemon ids packed into 8 words and computes `topCount`
   - Scripts print the ranked top, epoch data, and registry totals

### Why this matters
- We specifically test the Chainlink Functions mechanics: encoding request, DON execution, delivery, and `fulfillRequest` state updates
- The registry + oracle are used as realistic inputs/outputs to exercise Functions in context (what Functions reads; where fulfill writes)
- Mirrors production wiring with zero cost; catches issues early (blocked network access, bad args/bytesArgs, wrong subscription, missing template)

### Notes
- Local run uses the exact same source code as Sepolia. If you change `v4-template/src` or the Functions JS source, rerun the build-and-copy step and re-run the template setup.
- The local DON uses inline secrets; on live networks you must upload your RPC URL/chainId to the DON and reference the encrypted slot/version.
- Local vs Sepolia differences to keep in mind:
  - Local DON is permissive and immediate; real DON has network policies and block times
  - Secrets aren’t hosted locally (inline only); on Sepolia use DON-hosted secrets and manage TTL
  - Always repeat at least one request/fulfill on Sepolia before considering the flow production-ready



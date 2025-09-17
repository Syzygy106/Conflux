## TopOracle (Design & Usage)

This document explains the on-chain oracle used with Chainlink Functions to compute and store a ranked set of daemon ids.

### Scope
- Contract: `src/TopOracle.sol`
- Purpose: own and persist the Functions request template, send requests (manually or on epoch), and process DON fulfillments into a compact, on-chain top list

### Chainlink Functions setup
- Constructor: `(router, donId, registry, hookAuthority)`
  - `router`: Functions Router address for the current network
  - `donId`: DON identifier (bytes32)
  - `registry`: daemon registry address (read-only lookups)
  - `hookAuthority`: optional authority for in-protocol triggers (can be set later)
- Request template (owner-only):
  - `setRequestTemplate(source, secretsLocation, encryptedSecretsReference, args, bytesArgs, subscriptionId, callbackGasLimit)`
  - Stores parameters in an internal immutable-like struct used for subsequent requests
  - Typical values:
    - `secretsLocation = Location.DONHosted` on Sepolia, inline for local
    - `encryptedSecretsReference` built from DON slot/version (on Sepolia)
    - `subscriptionId` is a valid Functions subscription where this oracle is a consumer
    - `callbackGasLimit` sized for decoding and storage (e.g., 300k)

### Epoching and triggers
- State:
  - `epochDurationBlocks`: blocks per epoch (0 disables auto-epochs)
  - `lastEpochStartBlock`: block when the current/last epoch started
  - `hasPendingTopRequest`: true after a request is sent and before fulfill
  - `topEpoch`: monotonically increasing counter once fulfill succeeds
- Owner actions:
  - `setEpochDuration(blocks)`: enable/adjust epoching (must be > 0)
  - `startRebateEpochs(initialEpochBlocks)`: one-time init; sends the first request immediately using the stored template
  - `refreshTopNow()`: manual request without waiting for epoch expiry (requires a stored template)
- Hook authority action:
  - `maybeRequestTopUpdate()`: if `epochDurationBlocks > 0`, epoch expired, and no pending request — sends a new request using the template

### Storage layout for the Top
- `topPacked[8]`: 8 x 256-bit words; each word stores 16 ids (16 bits each) ⇒ up to 128 ids total
- `topCount`: number of valid ids (stops at sentinel `0xFFFF`)
- `topCursor`: round-robin iterator index used by the Hook to cycle through applicants within an epoch
- `lastRequestId`: last Functions request id

### Fulfillment path
- `fulfillRequest(requestId, response, err)` (internal override):
  - If `err` is non-empty: mark request as not pending, advance `lastEpochStartBlock`, emit `TopRequestFailed`, and return (no revert)
  - Else: decode `response` as `uint256[8]`, write words into `topPacked`, recompute `topCount` until `0xFFFF` sentinel, reset `topCursor`, increment `topEpoch`, clear pending, and set `lastEpochStartBlock`

### Read/iteration APIs
- `topIdsAt(index) -> uint16`: fetch id at position (bounds-checked)
- `getCurrentTop() -> address`: convert current cursor id into a daemon address via `registry.getById`
- `iterNextTop()` (only hookAuthority): increment cursor (wraps around `topCount`)

### Permissions
- Owner-only: template/epoch setters, manual refresh, ownership transfer, hookAuthority setter
- Hook authority: `maybeRequestTopUpdate`, `iterNextTop`

### Events
- `TemplateUpdated(uint64 subscriptionId, uint32 callbackGasLimit)`
- `EpochDurationUpdated(uint256 blocks)`
- `TopRefreshRequested(uint64 epoch, uint256 atBlock)`
- `TopIdsUpdated(uint16 count)`
- `TopRequestFailed(bytes err)`
- `OwnerTransferred(address previousOwner, address newOwner)`
- `HookAuthoritySet(address hookAuthority)`
- `RegistryUpdated(address newRegistry)`

### Integration points
- Off-chain JS (Functions) source computes words for the top based on registry reads (range queries/aggregation)
- Hook uses `getCurrentTop` and `iterNextTop` to coordinate rebates across the current epoch
- Registry is read-only for the oracle; updates are done via Functions fulfill

### Failure modes & troubleshooting
- "tpl not set" revert:
  - Call `setRequestTemplate` first; on Sepolia wait for 1–2 confirmations before `refreshTopNow()`
- Request not received in Functions UI:
  - Ensure `TopOracle` is added as a consumer on the subscription and that the subscription has LINK
  - Verify DON-hosted secrets slot/version are valid and not expired; re-upload as needed
- Blocked resource errors in DON logs:
  - The Functions source must use `Functions.makeHttpRequest` for JSON-RPC; direct provider objects are not allowed
- No top entries after fulfill:
  - Ensure the registry has active daemons; review off-chain ranking logic for limits (start/count windows)

### Gas & packing rationale
- Packing 128 ids into 8 words minimizes storage and decode costs
- The sentinel `0xFFFF` avoids writing a separate length field inside the words
- Separate `topCount` is tracked for fast bounds checks and iteration in the Hook

### Compatibility
- Paris-compatible (no Cancun-only opcodes)
- Deploy with Hardhat alongside the registry; the Hook stays in the Foundry/Cancun track

### Typical lifecycle
1) Deploy `TopOracle` with router + donId + registry
2) `setHookAuthority` (temporary owner/deployer until the Hook is live)
3) Create/fund subscription; add consumer `TopOracle`
4) `setRequestTemplate` with current JS source + DON-hosted secrets + subscription id
5) `setEpochDuration` or `refreshTopNow()` to kick off the first request
6) Observe fulfill and `TopIdsUpdated`; then wire the Hook and delegate authority



## ConfluxHook (Rebate Logic)

This document summarizes when the hook pays a rebate during swaps and when it does not, plus key parameters and references to tests.

### Scope
- Contract: `src/ConfluxHook.sol`
- Integrations: `TopOracle` (epochs, top list), `DaemonRegistryModerated` (moderation), Uniswap v4 `IPoolManager`

### Pool setup
- On `afterInitialize`, the pool must contain the configured `rebateToken`; otherwise the initialization reverts.
- The initiator of pool initialization becomes the pool owner (`PoolOwnable`), who can toggle rebates per-pool.

### Rebate decision matrix (beforeSwap)

| Condition | Rebate? | Side effects |
| --- | --- | --- |
| Oracle epochs disabled (`epochDurationBlocks == 0`) | No | Return ZERO_DELTA |
| No available top (`topCount == 0`) or all processed in current epoch (`processedInTopEpoch >= topCount`) | No | Return ZERO_DELTA |
| Pool not configured for rebates (`isRebateEnabled[poolId] == false`) | No | Return ZERO_DELTA |
| Current top daemon is banned (`registry.banned(rebatePayer) == true`) | No | `processedInTopEpoch++`, `topOracle.iterNextTop()` |
| Daemon `getRebateAmount(block.number)` call fails or returns < 32 bytes | No | `registry.setActiveFromHook(rebatePayer,false)`, emit `RebateDisabled(..., "rebateAmount failed")`, advance to next |
| `getRebateAmount` returns `daemonRebateAmount <= 0` | No | `processedInTopEpoch++`, `topOracle.iterNextTop()` |
| ERC20 `transferFrom(rebatePayer → poolManager, required)` fails | No | `registry.setActiveFromHook(rebatePayer,false)`, emit `RebateDisabled(..., "transfer failed")`, advance to next |
| ERC20 `transferFrom` success but received < required | No | `registry.setActiveFromHook(rebatePayer,false)`, emit `RebateDisabled(..., "insufficient received")`, advance to next |
| All checks pass; transferFrom covers full amount | Yes | `poolManager.settle()`, emit `RebateExecuted(daemonId, amount)`, attempt `accomplishDaemonJob()` (best-effort), compute delta, advance to next |

Notes:
- After each decision (whether rebate paid or not), the hook advances the epoch cursor: `processedInTopEpoch++` and `topOracle.iterNextTop()`.
- On errors attributable to a daemon, the daemon is deactivated via the registry (`setActiveFromHook(false)`), preventing further waste.

### Rebate amount and direction
- Amount comes from the daemon: `int128 daemonRebateAmount` (must be > 0). The hook requires full coverage of the unsigned `required = uint256(uint128(daemonRebateAmount))`.
- Direction depends on swap side and token position:
  - `rebateTokenIs0 = isRebateToken0[poolId]`
  - `rebateOnSpecified = (params.zeroForOne && rebateTokenIs0) || (!params.zeroForOne && !rebateTokenIs0)`
  - BeforeSwapDelta:
    - specified token delta = `-daemonRebateAmount` if `rebateOnSpecified`, else `0`
    - unspecified token delta = `-daemonRebateAmount` if `!rebateOnSpecified`, else `0`

### Per‑pool controls
- Toggle: `toggleRebate(PoolKey)` (only pool owner)
- Read: `getRebateState(PoolKey)`

### Oracle interactions during swap
- If epochs are enabled, the hook calls `topOracle.maybeRequestTopUpdate()` to auto-trigger a refresh at epoch boundaries when no request is pending.
- The hook uses `topOracle.topCount()`, `getCurrentTop()`, and `iterNextTop()` to cycle through the ranked set within an epoch.

### Moderation hooks
- `registry.setActiveFromHook(rebatePayer, false)`: used when a daemon misbehaves (no response, short transfer, etc.).
- `registry.banned(rebatePayer)`: banned daemons are skipped entirely.

### Events
- Emits `RebateDisabled(daemonId, reason)` on daemon-related issues.
- Emits `RebateExecuted(daemonId, amount)` when a rebate is successfully paid.
- Emits `DaemonJobSuccess/Failure` for the best‑effort `accomplishDaemonJob` callback (rebate is paid regardless of job success).

### Reference tests
- See `test/ConfluxRebateTests.t.sol` for positive/negative cases covering the matrix above (activation toggles, banned flow, staticcall failures, transfer underpayment, directionality, and per‑pool enable/disable).

### Compatibility
- Cancun EVM target (Uniswap v4 Hooks). Deploy with Foundry; wire the hook as authority into the registry/oracle once live on Sepolia.



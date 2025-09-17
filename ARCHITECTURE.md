# 🏗️ Architecture Overview

This document captures the current Conflux architecture: a Uniswap v4 Hook integrating with Chainlink Functions to select and reward daemons during swaps.

## System Design

### High‑Level Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     Uniswap v4 Pool                           │
│  ┌─────────────────┐    ┌──────────────────────────────────┐ │
│  │   Swap Logic    │───▶│           ConfluxHook           │ │
│  └─────────────────┘    └──────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    │                 │                 │
                    ▼                 ▼                 ▼
         ┌────────────────────┐ ┌────────────────────┐ ┌────────────────┐
         │ DaemonRegistry     │ │     TopOracle      │ │   Daemons      │
         │ Moderated (Paris)  │ │ (Functions, Paris) │ │ (LinearDaemon) │
         │ • Add/Activate/Ban │ │ • Template/Epochs  │ │ • Rebate/Jobs  │
         └────────────────────┘ └────────────────────┘ └────────────────┘
```

## Component Breakdown

### 1) ConfluxHook (Uniswap v4 Hook)
Executes rebate logic on `beforeSwap`, coordinates with `TopOracle` for current top daemon, enforces safety (reentrancy, moderation), and supports per‑pool enable/disable.

Key points:
- Requires Cancun (Uniswap v4 hooks; EIP‑1153)
- Pays rebates in a fixed pool rebate token via `transferFrom(daemon → poolManager)`
- Calls daemon `accomplishDaemonJob()` after successful rebate (best‑effort)
- Advances oracle cursor each swap to distribute opportunities within an epoch

### 2) DaemonRegistryModerated
Owner‑managed registry with hook authority; stores daemon set, activation and ban state, ownership, and provides aggregation/read APIs for Functions.

Key points:
- Paris‑compatible
- Immutable id assignment; activation bitmap for O(1) toggles
- Hook can disable/ban misbehaving daemons during swaps

### 3) TopOracle (Chainlink Functions client)
Owns the Functions request template and processes DON fulfill to update a packed top list (up to 128 ids) on‑chain. Supports epoching and hook triggers.

Key points:
- Paris‑compatible; deployed via Hardhat
- Template includes JS source + secrets (DON‑hosted) + subscription
- `refreshTopNow()` (manual) and `maybeRequestTopUpdate()` (hook‑triggered) send requests

## Data Flows

### Rebate Flow (Swap‑time)
```
1. User swaps on a pool
2. ConfluxHook::_beforeSwap()
3. If epochs enabled → hook may trigger oracle update at boundaries
4. Hook obtains current top daemon from TopOracle
5. Hook validates daemon (not banned; positive rebate)
6. Hook pulls rebate tokens from daemon → poolManager; settles
7. Hook calls daemon.accomplishDaemonJob() (best‑effort)
8. Hook advances cursor to next daemon
9. Returns BeforeSwapDelta to Uniswap v4
```

### Oracle Update Flow (Functions)
```
1. Owner sets template (JS source, secrets, subscription)
2. Owner sets epoch duration or calls refreshTopNow()
3. TopOracle sends Functions request to DON
4. Off‑chain JS ranks daemons (via registry aggregation)
5. DON fulfill writes 8 words into on‑chain storage; recomputes topCount
6. Epoch increments; pending cleared; cursor reset
```

## Security Model

### Access Control
- **Registry Owner**: add/activate/ban daemons; set hook authority
- **Hook Authority**: disable/ban from swap context; iterate oracle cursor
- **Oracle Owner**: manage template/epochs; manual refresh
- **Pool Owner**: toggle rebates per pool

### Safety Mechanisms
- Reentrancy guard in hook
- Graceful failure (no swap reverts on daemon errors)
- Automatic moderation (disable/ban) from hook
- Template/epoch checks in oracle; DON error handling does not revert

### Validation Checks (Swap)
- Pool must contain rebate token (enforced on afterInitialize)
- Daemon must not be banned; must return positive rebate
- ERC20 transferFrom must succeed and cover full amount

## Compatibility

- Chainlink Functions: Paris (Hardhat)
- Uniswap v4 Hook: Cancun (Foundry)

## Docs Index

- Hook: `v4-template/HOOK.md`
- Registry: `v4-template/REGISTRY.md`
- Oracle: `v4-template/ORACLE.md`
- Sepolia concepts: `functions-hardhat-starter-kit/SEPOLIA_TESTING_OVERVIEW.md`
- Local concepts: `functions-hardhat-starter-kit/LOCAL_TESTING_OVERVIEW.md`

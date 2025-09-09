# 🏗️ Architecture Overview

## System Design

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Uniswap v4 Pool                          │
│                                                             │
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │   Swap Logic    │───▶│      ConfluxModular Hook       │ │
│  └─────────────────┘    └─────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    │                 │                 │
                    ▼                 ▼                 ▼
         ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
         │ DaemonManager   │ │ ChainlinkOracle │ │   Daemon Pool   │
         │                 │ │                 │ │                 │
         │ • Add/Remove    │ │ • Top Rankings  │ │ • Daemon A      │
         │ • Activate      │ │ • Epoch Mgmt    │ │ • Daemon B      │
         │ • Ban           │ │ • Oracle Calls  │ │ • Daemon C      │
         │ • Aggregation   │ │ • Automation    │ │ • ...           │
         └─────────────────┘ └─────────────────┘ └─────────────────┘
```

## Component Breakdown

### 1. ConfluxModular Hook (16,924 bytes)
**Main hook contract that integrates with Uniswap v4**

#### Responsibilities:
- ✅ Implement Uniswap v4 hook interface
- ✅ Handle swap interception and rebate logic
- ✅ Coordinate with DaemonManager and ChainlinkOracle
- ✅ Manage per-pool rebate settings
- ✅ Execute daemon jobs and handle failures

#### Key Functions:
```solidity
function _beforeSwap() -> (bytes4, BeforeSwapDelta, uint24)
function _afterSwap() -> (bytes4, int128)
function toggleRebate(PoolKey) // Pool owner only
```

### 2. DaemonManager (7,217 bytes)
**Manages daemon lifecycle and aggregation**

#### Responsibilities:
- ✅ Add/remove daemons with ownership tracking
- ✅ Activate/deactivate daemons
- ✅ Ban malicious daemons
- ✅ Aggregate rebate amounts from active daemons
- ✅ Provide daemon lookup by ID/address

#### Key Functions:
```solidity
function addDaemon(address daemon, address owner)
function activateDaemon(address daemon)
function banDaemon(address daemon)
function aggregateRebateAmounts(start, count, blockNumber) -> int128[]
```

### 3. ChainlinkOracle (8,819 bytes)
**Handles Chainlink Functions integration and top rankings**

#### Responsibilities:
- ✅ Manage epoch-based top daemon rankings
- ✅ Request updates from Chainlink Functions
- ✅ Process oracle responses and update top lists
- ✅ Provide current top daemon for rebates
- ✅ Handle epoch transitions and cursor management

#### Key Functions:
```solidity
function startRebateEpochs(...)
function maybeRequestTopUpdate()
function getCurrentTopDaemon() -> address
function iterateToNextTop()
```

## Data Flow

### Rebate Process Flow
```
1. User initiates swap on Uniswap v4 pool
2. ConfluxModular._beforeSwap() is called
3. Check if epochs are enabled (ChainlinkOracle)
4. Get current top daemon (ChainlinkOracle)
5. Validate daemon has positive rebate (DaemonManager)
6. Execute token transfer from daemon to pool
7. Call daemon.accomplishDaemonJob()
8. Update counters and iterate to next daemon
9. Return rebate delta to Uniswap v4
```

### Oracle Update Flow
```
1. Epoch duration expires
2. ChainlinkOracle.maybeRequestTopUpdate() called
3. Chainlink Functions request sent with daemon data
4. Off-chain computation ranks daemons by rebate amounts
5. Oracle response updates top rankings
6. New epoch begins with fresh top list
```

## Security Model

### Access Control
- **Hook Owner**: Can add daemons, set epochs, manage system
- **Pool Owner**: Can toggle rebates for their specific pool  
- **Daemon Owner**: Can activate/deactivate their own daemon
- **Anyone**: Can view public data and trigger swaps

### Safety Mechanisms
- ✅ Daemon ban system for malicious actors
- ✅ Per-pool rebate toggle for granular control
- ✅ Gas limits on daemon job execution (300k gas)
- ✅ Graceful failure handling for daemon errors
- ✅ Epoch exhaustion protection

### Validation Checks
- ✅ Pool must contain rebate token
- ✅ Daemon must be active and not banned
- ✅ Rebate amount must be positive
- ✅ Token transfer must succeed
- ✅ Hook address must match required permissions

## Gas Optimization

### Efficient Storage
- Packed top daemon IDs (128 daemons in 8 storage slots)
- Bitmap for daemon activation status
- Minimal state variables in main hook

### Call Optimization  
- External calls only when necessary
- Batch operations where possible
- Early returns for edge cases
- Gas stipend for daemon jobs

## Upgrade Strategy

### Immutable Core
- ConfluxModular hook cannot be upgraded (Uniswap v4 requirement)
- Core rebate logic is frozen once deployed

### Upgradeable Components
- DaemonManager can be replaced by deploying new version
- ChainlinkOracle can be replaced by deploying new version
- Daemon contracts can be updated by their owners

### Migration Process
1. Deploy new component versions
2. Update references in ConfluxModular (if possible)
3. Migrate daemon registrations
4. Update oracle configurations
5. Test thoroughly before switching

## Performance Characteristics

### Contract Sizes
| Component | Size | % of Limit | Status |
|-----------|------|------------|---------|
| ConfluxModular | 16,924 bytes | 68% | ✅ Optimal |
| DaemonManager | 7,217 bytes | 29% | ✅ Optimal |
| ChainlinkOracle | 8,819 bytes | 36% | ✅ Optimal |

### Gas Usage
- Swap with rebate: ~166k gas
- Daemon registration: ~150k gas
- Oracle update: ~200k gas
- Pool initialization: ~300k gas

### Scalability
- Supports up to 3,200 daemons
- Top list of 128 daemons per epoch
- Unlimited pools per hook instance
- Configurable epoch durations

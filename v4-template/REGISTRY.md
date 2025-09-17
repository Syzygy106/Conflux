## Daemon Registry (Design & Usage)

This document describes the on-chain registry used by the hook/oracle flow.

### Scope
- Contracts: `src/base/DaemonRegistry.sol` (core) and `src/DaemonRegistryModerated.sol` (owner + hook authority)
- Purpose: keep a list of daemon contracts, map addresses <-> ids, manage activation/ban state, provide read APIs for Functions/Hook

### Data model
- Address list `_daemonAddresses` where index is the daemon id (`uint16`)
- Mappings:
  - `exists[address] -> bool`
  - `addressToId[address] -> uint16`, `idToAddress[uint16] -> address`
  - `active[address] -> bool`
  - `daemonOwner[address] -> address` (who can toggle activation via public methods)
  - `banned[address] -> bool` (permanently excluded until unbanned by admin)
- Compact activation bitmap: `mapping(uint256 wordIndex => uint256 word)` to track active ids efficiently; `bitWordCount` tracks size

### Ids and packing
- Id assignment is sequential: `uint16 id = uint16(_daemonAddresses.length)` at add-time
  - Packed address list/hash:
    - `packedAll()` returns `abi.encodePacked(_daemonAddresses)`
    - `packedHash()` returns `keccak256(abi.encodePacked(_daemonAddresses))`
  - Packed (id,address) pairs:
    - `packedPairs()` returns `[id(2 bytes, big-endian) | address(20 bytes)] * N`
    - `packedPairsHash()` returns `keccak256(packedPairs())`

### Roles
- Owner (registry owner): can add/activate/deactivate/ban; can assign `hookAuthority`
- Hook authority (hook contract): limited moderation via hook-only endpoints

### Core admin (owner)
- `add(address daemon, address owner_)`
- `addMany(address[] daemonAddresses, address[] owners)`
- `activateMany(address[] daemonAddresses)` / `deactivateMany(address[] daemonAddresses)`
- `banDaemon(address daemon)` (also clears activation)
- `transferOwnership(address newOwner)` and `setHookAuthority(address hook)` (in `DaemonRegistryModerated`)

### Hook-side moderation (authority)
- `setActiveFromHook(address daemon, bool isActive)`
- `banFromHook(address daemon)`

### Public owner-facing toggles (per daemon owner)
- `setActive(address daemon, bool isActive)`
- `setActiveById(uint16 daemonId, bool isActive)`
- Both require `msg.sender == daemonOwner[daemon]`

### Read APIs (used by Functions and the Hook)
- Addressing:
  - `length() -> uint256`
  - `getAt(uint256 index) -> address`
  - `getAll() -> address[]`
  - `getById(uint16 daemonId) -> address`
- Aggregations for Functions off-chain JS:
  - `aggregatePointsRange(start, count, blockNumber) -> int128[]`
  - Overload: `aggregatePointsRange(start, count) -> uint128[]` (current block, non-negative clamp)
  - `aggregatePointsAll(blockNumber) -> int128[]`
  - `aggregatePointsMasked(blockNumber) -> int128[]` (inactive => 0)
  - All call `IDaemon(daemon).getRebateAmount(blockNumber) returns (int128)` safely (try/catch)
- Activation map utilities:
  - `activationBitmap() -> bytes`
  - `activationMeta() -> (uint256 total, bytes bitmap)`

### Integration points
- Chainlink Functions source reads registry state via the functions above to rank daemons
- `TopOracle` reads `length()` and `getById()` during request orchestration and result usage
- `ConfluxHook` uses `addressToId(address)` and moderation endpoints from `DaemonRegistryModerated`

### Events
- `Added(address target, uint16 id)`
- `ActivationChanged(address target, uint16 id, bool active)`
- `DaemonBanned(address target, uint16 id)`
- `OwnershipTransferred(address previousOwner, address newOwner)` (moderated)
- `HookAuthoritySet(address hook)` (moderated)

### Errors (selected)
- `ZeroAddress`, `DuplicateDaemon`, `CapacityExceeded`, `IdDoesNotExist`, `NotExist`, `DaemonIsBanned`, `NotDaemonOwner`, `LengthMismatch`, `NotOwner`, `NotAuthorized`

### Gas & storage notes
- Activation bitmap keeps toggles O(1) per daemon without scanning arrays
- Pair/address packing enables cheap hashing/snapshotting to detect registry changes off-chain
- Adds and bans are append/flag operations; no array compaction (ids remain stable)

### Safety & invariants
- `add*` rejects duplicates and zero addresses; max ~1200 daemons (fits `uint16` and internal limits)
- `ban*` immediately clears activation bit for the daemon
- Public toggles require daemon-specific ownership; owner/hook can still override via admin endpoints

### Compatibility
- Paris-compatible; does not rely on Cancun features. Can be deployed with Hardhat alongside `TopOracle`

### Typical lifecycle
1) Owner deploys `DaemonRegistryModerated`
2) Owner `addMany` with daemon owners; optionally `activateMany`
3) Hook gets assigned via `setHookAuthority` and may moderate misbehaving daemons during swaps
4) Functions/Oracle read registry to compute and store the ranked top

### Testing considerations
- Use example `LinearDaemon` for deterministic `getRebateAmount()`
- For Functions local tests, call aggregation views and ensure inactive/banned paths return 0



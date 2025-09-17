# The Daemon Registry

The **Daemon Registry** is the on-chain contract that manages the lifecycle of daemons in the Conflux system. It acts as the **source of truth** for which daemons exist, who controls them, and whether they are eligible to participate in rebate programs.

---

## Overview

The registry:

- Stores all registered daemon addresses with their owner associations.
- Maintains **status flags** for each daemon:
  - **Active** — eligible to be selected as a rebate provider.
  - **Inactive** — exists but not currently eligible.
  - **Banned** — permanently excluded for malicious or invalid behavior.
- Exposes controlled functions for:
  - Adding new daemons.
  - Activating / deactivating daemons.
  - Banning daemons.
  - Assigning hook authority.

The registry enforces **ownership-based permissions** and **authority constraints** to guarantee that only authorized actors can mutate daemon states.

---

## Contract: `DaemonRegistryModerated`

The implementation used in Conflux is `DaemonRegistryModerated`, which introduces strict moderation and role separation.

### Core Roles

- **Owner (admin):**
  - Can add, activate, deactivate, or ban daemons.
  - Can set hook authority (the hook contract that automates moderation).
- **Hook Authority:**
  - Special role assigned to the Conflux hook.
  - Can disable daemons automatically when they misbehave during swaps (e.g., failing to pay rebate, reverting, returning invalid data).
- **Daemon Owner:**
  - The account that owns a specific daemon.
  - Can voluntarily toggle its daemon’s activation (within allowed rules).

---

## State Variables

- `mapping(address => bool) active`  
  Tracks whether a daemon is currently active.

- `mapping(address => bool) banned`  
  Tracks whether a daemon has been banned.

- `mapping(address => address) owners`  
  Maps each daemon to its owner.

- `address hookAuthority`  
  The designated hook contract allowed to enforce moderation actions.

- `uint256 totalDaemons`  
  Count of all registered daemons.

---

## Key Functions

### Admin-only
- `add(address daemon, address owner)`  
  Registers a new daemon under an owner.

- `addMany(address[] daemons, address[] owners)`  
  Batch version of `add`.

- `setActive(address daemon, bool state)`  
  Enables or disables a daemon.

- `banDaemon(address daemon)`  
  Marks daemon as banned and disables it permanently.

- `setHookAuthority(address hook)`  
  Assigns the hook contract with moderation powers.

---

### Hook Authority-only
- `banFromHook(address daemon)`  
  Hook can immediately ban a daemon when it misbehaves.

- `setActiveFromHook(address daemon, bool state)`  
  Hook can toggle activity status automatically in response to runtime failures.

---

### Daemon Owner-only
- `setActive(address daemon, bool state)`  
  Daemon owner may voluntarily toggle its active status (cannot override bans).

---

## Lifecycle

1. **Registration**  
   Admin adds a daemon with an owner address.

2. **Activation**  
   Admin or daemon owner marks it active → daemon is eligible for selection by the oracle.

3. **Participation**  
   Active daemons may be selected in rebate epochs and pay rebates during swaps.

4. **Failure or Misbehavior**  
   - If daemon fails to pay rebate, reverts, or returns invalid data → hook disables it via `setActiveFromHook`.
   - If malicious, admin (or hook) calls `banDaemon`.

5. **Banned State**  
   - Irreversible.
   - Daemon is permanently excluded from participation.

---

## Invariants & Safety

- **Registry size limit:** capped (e.g., 1200 daemons) to prevent unbounded growth.
- **Top set size:** limited to 128 active IDs at a time.
- **Bans override everything:** banned daemons cannot be reactivated.
- **Hook moderation:** ensures runtime failures do not compromise swap execution.

---

## Integration With TopOracle

- The registry is the source of daemon IDs used by **TopOracle** to construct top sets for epochs.
- Oracle queries and Chainlink fulfillments reference daemon IDs as assigned in the registry.
- Misbehaving daemons are automatically deactivated by the hook → registry state is updated → Oracle will skip them in future top sets.

---

## Testing Scenarios

The following behaviors are tested in the suite:

- **Successful lifecycle:** add → activate → participate → rebate.  
- **Admin controls:** only registry owner can add/ban/set authority.  
- **Hook moderation:** hook disables or bans failing daemons.  
- **Edge cases:** exceeding cap, banning already banned, toggling active state by non-owner, etc.  

---

## Summary

The registry enforces a **secure and moderated marketplace of daemons**:
- Owners can contribute daemons.  
- The system (hook + oracle) enforces correctness.  
- Bad actors are isolated quickly.  

It is the backbone of daemon trust management in the Conflux rebate mechanism.

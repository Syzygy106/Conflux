# The TopOracle

The **TopOracle** is the contract responsible for maintaining the **active set of top daemons** in the Conflux system.  
It integrates with Chainlink Functions (DON) to periodically fetch and update which daemons should be selected to pay rebates during swaps.

---

## Overview

The oracle:

- Coordinates **rebate epochs** (time windows in blocks where specific daemons are responsible for rebates).
- Requests updated **top sets** of daemon IDs from an off-chain oracle (Chainlink Functions).
- Provides the hook with the **current top daemon(s)** during swaps.
- Ensures misbehaving daemons are skipped and replaced by others.

It acts as the **bridge between the Registry (all daemons)** and the **Hook (rebates in pools)**.

---

## Key Responsibilities

1. **Epoch Management**
   - Defines and enforces rebate epochs, each lasting `epochDurationBlocks`.
   - Advances epochs automatically once the current block exceeds the epoch boundary.
   - Resets daemon participation counters each epoch.

2. **Oracle Requests**
   - Sends requests to the Chainlink Functions DON at epoch boundaries or when explicitly refreshed.
   - Uses a stored **request template** (source, secrets, args, subscription ID, gas limit).
   - Receives asynchronous responses with the top N daemons (up to 128).

3. **Fulfillment**
   - Decodes oracle responses (array of daemon IDs).
   - Updates the `topIds` buffer.
   - Ensures results are bounded by:
     - End marker `0xffff` for termination.
     - Maximum cap of 128 IDs.

4. **Integration With Hook**
   - Exposes functions for the Conflux hook to:
     - Read the current top daemon.
     - Advance through top daemons as they are consumed.
   - Hook calls `maybeRequestTopUpdate` during swaps if an epoch expired.

---

## Contract: `TopOracle`

### Core Roles

- **Owner (admin):**
  - Sets the request template (Chainlink parameters).
  - Starts and configures rebate epochs.
  - Changes registry and hook authority addresses.

- **Hook Authority:**
  - Typically the Conflux Hook.
  - Allowed to call:
    - `maybeRequestTopUpdate()` → triggers new oracle request if epoch expired.
    - `iterNextTop()` → advances the current top pointer after daemons are exhausted.

- **Chainlink DON:**
  - Responds to oracle requests by calling `fulfillRequest` with encoded daemon IDs.
  - May also return an error (on failure).

---

## State Variables

- `uint64 epochDurationBlocks`  
  Number of blocks per epoch (0 means epochs disabled).

- `uint256 currentEpoch`  
  Current epoch index.

- `uint256 epochEndBlock`  
  Block number at which the current epoch ends.

- `uint16[] topIds`  
  Current list of top daemon IDs (packed, max 128).

- `uint256 topPointer`  
  Index of the next daemon in `topIds` to be used.

- `bytes32 lastRequestId`  
  ID of the most recent Chainlink Functions request.

- `address registry`  
  Reference to the `DaemonRegistryModerated`.

- `address hookAuthority`  
  Contract authorized to consume the oracle results.

---

## Key Functions

### Owner-only
- `setRequestTemplate(...)`  
  Defines the Chainlink request template.

- `startRebateEpochs(uint64 duration)`  
  Enables epoch logic with the given block duration.

- `setRegistry(address)`  
  Updates registry reference.

- `setHookAuthority(address)`  
  Updates hook authority.

---

### Hook Authority-only
- `maybeRequestTopUpdate()`  
  If epoch ended, send a new request to Chainlink.

- `iterNextTop()`  
  Advance to the next top daemon in the list.

- `getCurrentTop()`  
  Returns the daemon ID currently responsible for rebate.

---

### Chainlink-only
- `fulfillRequest(bytes32 requestId, bytes response, bytes err)`  
  Internal callback from DON. Updates `topIds` or clears pending state on error.

---

## Lifecycle

1. **Initialization**  
   - Owner sets request template.  
   - Owner starts rebate epochs.

2. **Epoch Progression**  
   - Hook calls `maybeRequestTopUpdate`.  
   - Oracle sends a request to DON.  
   - DON fulfills with new top IDs.

3. **Swap Execution**  
   - Hook queries `getCurrentTop`.  
   - Selected daemon pays rebate.  
   - Pointer advances (`iterNextTop`).  

4. **Exhaustion**  
   - If all daemons in `topIds` are consumed → no more rebates until next epoch refresh.

5. **Failure Modes**  
   - If DON returns error → epoch progresses but no rebates.  
   - If top set is empty → swaps proceed with no rebates.  

---

## Invariants & Safety

- **Cap on top set:** max 128 daemons per epoch.  
- **End marker:** `0xffff` signals end of array.  
- **One request at a time:** only one pending Chainlink request allowed.  
- **Disabled epochs:** if `epochDurationBlocks == 0`, no rebates occur.  

---

## Integration With Registry

- Oracle resolves daemon IDs against the Registry.  
- Only **active, non-banned** daemons are included in top sets.  
- Hook deactivations (from misbehavior) ensure Oracle won’t reuse bad daemons in future epochs.  

---

## Testing Scenarios

The test suite covers:

- **Disabled epochs:** no rebate logic.  
- **No top daemons:** swaps without rebates.  
- **Multiple top daemons:** rotation across swaps until exhausted.  
- **Error fulfillment:** clearing pending state on DON failure.  
- **Invalid data:** daemons disabled via hook.  
- **Exhaustion:** no rebates once all top daemons are consumed.  

---

## Summary

The TopOracle is the **heartbeat of rebate distribution**:  
- It orchestrates epochs.  
- Fetches and updates the top daemons via Chainlink.  
- Provides the hook with correct rebate participants.  

Together with the Registry and the Hook, it ensures **fair, safe, and automated rebate assignment**.


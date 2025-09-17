# The Conflux Hook

The **ConfluxHook** is a Uniswap v4 hook contract that integrates **rebate logic** into pool swaps.  
It acts as the runtime enforcer of the Conflux rebate mechanism by deciding whether daemons should pay rebates to traders, and by executing their jobs when swaps occur.

---

## Overview

The hook:

- Runs on **`beforeSwap`** and **`afterInitialize`** events in Uniswap v4.
- Interacts with the **TopOracle** to determine which daemon is responsible for rebates in the current epoch.
- Pulls rebate tokens directly from daemon balances when conditions are met.
- Executes daemon jobs after successful rebate payment.
- Enforces **safety checks** (reentrancy, banned daemons, failed transfers).

The hook ensures that **rebates are only paid under valid conditions**, and that misbehaving daemons are automatically deactivated.

---

## Core Responsibilities

1. **Rebate Execution**
   - When a swap happens, the hook determines if rebates should apply.
   - Rebates are denominated in the **rebate token**, fixed at pool creation.

2. **Job Execution**
   - After paying rebate, the daemon’s `accomplishDaemonJob()` is called.
   - Failures in job execution do not affect the swap outcome, but are recorded.

3. **Enforcement**
   - Reentrancy protection ensures swaps cannot be re-entered by malicious daemons.
   - Misbehaving daemons are deactivated via the Registry.

---

## Rebate Conditions (Comprehensive Table)

| Condition                           | Rebate Paid? | Iteration Proceeds? | Daemon Disabled? | Daemon Banned? | Notes                                                                 |
|-------------------------------------|--------------|----------------------|------------------|----------------|-----------------------------------------------------------------------|
| **Epochs disabled** (`duration=0`)  | No           | No                   | No               | No             | System-wide off switch.                                               |
| **No top daemons** (`topCount=0`)   | No           | No                   | No               | No             | Nothing to select.                                                    |
| **All daemons exhausted**           | No           | No                   | No               | No             | End of epoch set reached.                                             |
| **Banned daemon**                   | No           | Yes                  | Already banned   | Yes            | Skipped immediately.                                                  |
| **Pool lacks rebate token**         | N/A (init revert) | N/A               | N/A              | N/A            | Hook initialization fails, not swap-time.                             |
| **Rebates disabled on pool**        | No           | No                   | No               | No             | Pool owner toggled rebate off.                                        |
| **Daemon rebateAmount call fails**  | No           | Yes                  | Yes              | No             | Marked inactive.                                                       |
| **Daemon returns invalid data**     | No           | Yes                  | Yes              | No             | E.g., bad ABI decode.                                                 |
| **Daemon returns ≤ 0 amount**       | No           | Yes                  | No               | No             | Simply skipped.                                                       |
| **TransferFrom fails**              | No           | Yes                  | Yes              | No             | Daemon cannot pay. Disabled.                                          |
| **Transfer amount < required**      | No           | Yes                  | Yes              | No             | Fee-on-transfer or shortfall. Disabled.                               |
| **Successful rebate**               | Yes          | Yes                  | No               | No             | Job executed after transfer.                                          |
| **Job execution fails**             | Yes          | Yes                  | No               | No             | Rebate still credited; job failure logged.                            |
| **Reentrancy attempt**              | Yes (outer call only) | Yes           | No               | No             | Outer call proceeds; nested reentry blocked by guard.                 |

---

## Invariants & Safety

- **Swap safety:** swaps always succeed regardless of daemon failures.  
- **Isolation:** misbehaving daemons are automatically disabled by the hook.  
- **Reentrancy guard:** prevents malicious daemons from recursive swaps.  
- **Banned state finality:** once banned, daemons cannot return.  
- **Pool integrity:** only pools containing the rebate token can initialize with the hook.

---

## Lifecycle During Swap

1. **Swap initiated.**  
2. Hook queries Oracle for the current top daemon.  
3. Checks all rebate conditions in order.  
4. If valid:
   - Daemon pays rebate in rebate token.  
   - Daemon executes its job.  
5. If invalid:
   - No rebate occurs.  
   - Daemon may be deactivated if faulty.  
6. Oracle pointer advances to next daemon in top set (except in system-wide skips).

---

## Summary

The Conflux Hook is the **execution engine** of the rebate system:  
- It ensures only **valid daemons** pay rebates.  
- Protects swaps from disruption by daemon misbehavior.  
- Enforces **all rebate conditions** consistently, with clear secondary actions.  

It is the final guardrail connecting **swaps, the Oracle, and the Registry** into a secure rebate ecosystem.

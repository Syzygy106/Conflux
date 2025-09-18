
#### Introduction

In practice, blockchains often require the creation of recurring chains of actions. For example, suppose you are a large project with an NFT token that grants special rights to its holders — such as access to a collector’s edition of your video game. You may want a new NFT to be minted and raffled among your fans every month. And you want this to happen reliably: even if you forget, the NFT must be created and raffled at the exact right time. However, doing this reliably and in a decentralized manner is quite difficult.

Today, I will share my approach to solving the problem of recurring operations in EVM-compatible blockchains.  

The inspiration came from a concept that has long been left unrealized in the Uniswap v4 ideas list:  
(Original concept:  
https://hackmd.io/@kames/unibrain-hook#:~:text=UniBrain%20hook%20turns%20UniswapV4%20into,onchain%20function%20by%20executing%20a  
)

I explored both this problem and the proposed concept. I went further than the initial idea and implemented the best variant I currently see as possible.

---

#### The Problem of Recurring Operations in EVM Blockchains

When studying the ideas on which Ethereum is built, we inevitably encounter a fundamental fact: it is impossible to schedule an onchain task for automatic execution. In other words, recurring or delayed actions cannot be performed without an external trigger. The Solidity documentation even explicitly states: *“There is no ‘cron’ concept in Ethereum to call a function at a particular event automatically.”*

It may be tempting to solve this problem with smart contracts. But in practice, the EVM has no opcodes that would allow deferred execution. At first glance, this seems like a dead end — but let’s think about what we *can* do.

Instead of direct scheduling, we can consider another approach: **what if we create profitable conditions for external triggers?**

Choosing this path, we arrive at two options:  
1. Create a contract that directly rewards actors for triggering execution of a useful task.  
2. Attach useful tasks to other calls that already happen frequently onchain.  

The second option is more efficient, because in the first case we would need to promote our “action hub,” drive traffic to it, and ensure high call frequency. In the second case, by attaching tasks to frequently occurring calls, we do not have to worry about traffic at all.

What are the most frequent actions on blockchains? Transfers of the native currency, ERC20 token transfers, and swaps in liquidity pools. Let’s examine each separately.

- **Native currency transfers.** We cannot attach our logic here without modifying the EVM, and the value per transfer is generally too small to be useful.  
- **ERC20 transfers.** More flexible since tokens are contracts, but here we lose in frequency and stability compared to native transfers. To sustain traffic, we’d need extreme token popularity — practically infeasible.  
- **Liquidity pool swaps.** Here traffic is smaller in volume, but we gain a critical advantage: we can attach our task execution to swaps by creating **arbitrage opportunities**. Arbitrage ensures steady user activity, at times favorable to us. We can scale the size of the attached workload as long as the arbitrage profit covers execution costs. Best of all, Uniswap v4 hooks let us attach payloads directly to swaps.

---

#### Returning to the Initial Idea

The Unibrain concept proposed:

...The UniBrain hook is designed to automate any onchain action at a predetermined time by using an automated Dutch Auction to incentivize "rational economic actors" to periodically swap via the pool and automatically trigger an onchain function call...

For example, consider a Uniswap v4 DAI/USDC pool with $1,000 liquidity. We want an onchain function to be called every 30 minutes. Executing a transaction costs $0.03. The UniBrain hook starts a Dutch auction every 30 minutes, where the price advantage grows until execution becomes profitable. Eventually, someone swaps and triggers the function.

**The main issue with this design:**  
Each actor (I call them *daemons*, borrowing terminology from low-level programming) may have different requirements for execution frequency and priority. Thus:
- We cannot use a single auction for all daemons.  
- Each daemon needs its own model of execution timing and incentives.  
- With one auction, throughput collapses: for most of its duration, tasks sit idle, and when execution becomes profitable, only a limited number of tasks can be run.

Therefore, instead of one auction, we need a **complex ensemble of auctions**. This allows continuous creation of arbitrage opportunities — even within a single block — and enables regular execution of useful tasks.

---

#### Evolving the Unibrain Idea

I call the new concept **Conflux**. Each daemon can define its own pricing model — by time, by size, or both.

How do we create profit in the pool? There are many options. For example, we could use ERC1155 tokens to directly manage liquidity and pricing. But in fact, the simplest and most effective approach is **rebates**. Therefore, in my reference hook, I attach tasks to **_afterSwap** with a rebate mechanism.

Concretely, we can just increase the amount of tokens a trader receives after a swap. For example, if the hook is set to rebate only in USDT, and the rebate amount is 5 USDT, then regardless of swap direction, the trader receives an additional ~5 USDT. If buying USDT, they get 5 more. If selling USDT, they receive proceeds as if they had sold 5 USDT more.

Each daemon contract must implement the `IDaemon` interface, with methods for reporting rebate amount and performing its job. In the reference hook, these are executed with try/catch and gas limits (50,000 and 300,000 respectively), but these parameters can be adjusted.

Daemons are stored in a special Registry. In the reference implementation, daemons are added with hook owner approval. However, daemons are controlled by their own owners, who can later activate or deactivate them in the Registry.

A key challenge: daemons may provide different rebate values depending on block number, so we need onchain sorting at swap time. This is infeasible fully onchain. Therefore, we move the computation offchain, while preserving decentralization and trust. The solution: **Chainlink Functions**. A decentralized oracle network computes rebate scores, sorts daemons, and returns the top set to the blockchain.

---

#### Chainlink Functions

To support Chainlink Functions (and to provide simple access for users and arbitrageurs), I designed Registry and Top contracts:
- The Registry stores all daemons.  
- The TopOracle stores the current epoch’s top set.

Chainlink Functions has strict limits on return data size. A batching approach would be inefficient. Instead, my design returns the top 128 daemon IDs (2 bytes each), sorted by rebate value at epoch start.

Epochs are defined in blocks and can be configured by the hook owner. Epoch updates are automatically requested, creating reliable and continuous rotation of the top set. The design accounts for:
- Chainlink callback size limits,  
- HTTP call restrictions,  
- Execution time,  
- Onchain data size.  

---

### Results

Within these constraints, I achieved:
- Registry capacity of ~1000–1400 daemons.  
- Top set capacity of 128 daemons per epoch.  

This is a very strong result. The hook can support multiple pools simultaneously, allowing pool owners to enable or disable rebates at will. The only requirement: the pool must include the rebate token (ideally a stablecoin).

I built a convenient interface that allows both Chainlink Functions and any external user to easily compute their expected rebate for a swap.  

Tests were written covering not only the hook logic but also the Chainlink Functions integration.  

Finally, the Unibrain concept has been extended and brought to life. I hope the original author will appreciate this implementation.

---

#### Key Challenges

- The official Uniswap v4 hook template is based on **Foundry**, which supports EVM Cancun.  
- The official Chainlink Functions template is based on **Hardhat**, with ethers v5, supporting only EVM Paris (Cancun not yet supported).  

Therefore:  
- Hook testing was primarily done in Foundry, thanks to its developer-friendly environment.  
- Chainlink Functions with a local DON was tested in Hardhat.  
- Deployment pipeline was tested on ETH Sepolia, where end-to-end rebate execution with Chainlink Functions was confirmed in practice.

---

## Future of the Project

I believe I have pushed this concept to its current technical maximum. The only possible further development is to move computation logic into Ethereum execution clients (e.g., node-level modifications). This could bring even higher reliability and may lead to advancing Ethereum infrastructure itself.  

My next steps: contributing to **RETH** (the Rust execution layer client), with the possibility of drafting an **EIP** and implementing this concept directly in RETH in the future.

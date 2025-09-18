#### Introduction:

The fact is that in blockchain practice, there's often a need to create chains of recurring actions. For example, you're a large project with an NFT token that provides special rights to its holders, say, the right to receive a collectible edition of your video game. At the same time, you want a new NFT to be minted and raffled among your list of fans every month. And you want to do this reliably, so that even if you forget, the NFT is created exactly at the right time and raffled off. However, doing this reliably and in a decentralized manner is quite difficult.

Today I'll tell you about my journey in solving the problems of recurrent operations in EVM-like blockchains.

My inspiration came from a concept that has been gathering dust in Uniswap V4's list of unrealized ideas.
(
Original proposed concept:
https://hackmd.io/@kames/unibrain-hook#:~:text=UniBrain%20hook%20turns%20UniswapV4%20into,onchain%20function%20by%20executing%20a
)

I researched this problem as well as the proposed concept. I went further than the original idea and implemented the best solution I see as possible.

#### About the Problem of Recurrent Operations in EVM Blockchains:

Upon familiarizing ourselves with the ideas underlying Ethereum, we'll inevitably encounter one foundational fact - you cannot schedule a task for auto-execution on-chain. That is, it's impossible to perform recurrent/delayed actions without an external trigger. The Solidity documentation even has the line "There is no 'cron' concept in Ethereum to call a function at a particular event automatically."

There's a desire to solve this problem using smart contracts, but in reality, there are no opcodes in EVM that would allow delaying an action for the future. It seems we've hit a dead end, but let's think about what we can do.

Based on the definition given above, we can think about the solution differently - what if we can create favorable conditions for external triggers?

Choosing this option, we come to the fact that we must either create a contract where we'll directly issue rewards for calling the payload execution, or we must attach the payload to frequently occurring calls. Choosing between these two options, the second would be more advantageous, because with the first option we're obliged to intentionally advertise our action hub, drive traffic there, and be confident in the frequency of calls. In the case of attaching our actions to other frequently-occurring ones - we won't have to worry about traffic.

What are the most frequent actions that occur on the blockchain? Of course, these are native currency transfers, ERC20 token transfers, and swaps in liquidity pools. Let's deal with each specific action separately.

In the case of native currency transfer - we won't be able to attach our action without modifying EVM, moreover, this is far from the most pleasant and convenient option, as the cost of native currency transfer itself is extremely small.

In the case of an ERC20 token, it's much more convenient, as it has its own smart contract. However, here we completely lose in terms of frequency and traffic stability compared to native currency transfers. We're obliged to maintain phenomenal activity, ensuring the popularity of our token, which is extremely difficult and expensive. In practice, this will be practically inapplicable.

But in the case of liquidity pools, we have even less nominal traffic size, but there's an important tool for attracting triggers for our actions - creating arbitrage profit. Arbitrage profit allows us to steadily attract users at times that are convenient specifically for us. We can scale the size of our payload that we attach - the main thing is that the arbitrage profit we create covers the execution costs. And the most pleasant thing - using Uniswap V4, we can attach payload to the actions that interest us!

#### Returning to the Initial Idea

The idea that the author proposed in the Unibrain concept:

```
...The UniBrain hook is designed to automate any onchain action at a predetermined time by using an automated Dutch Auction to incentivize "rational economic actors" to periodically swap via the pool and **automatically triggering on onchain function call**...


...For example let's imagine we have a UniswapV4 DAI/USDC pool with a $1,000 worth of liquidity. And we want an onchain function to be called every 30 minutes.

There is a cost to executing the onchain transaction.

Let's assume it costs $0.03 to execute the onchain transaction.

The UniBrain hook will automatically start a Dutch Auction every 30 minutes. And during this period the cost of purchasing USDC with DAI will decrease by $0.01 every 10 seconds.

At a certain point in time it becomes profitable to execute a swap via the DAI/USDC pool.

- 10 seconds = $-0.02 profit
- 20 seconds = $-0.01 profit
- 30 seconds = $0.00 profit
- 40 seconds = $0.01 profit
- 50 seconds = $0.02 profit

In-turn automatically executing the onchain function call at a competitive price.
```

What's the main problem with the concept? The thing is that each specific actor (I'll call them daemons in my project, as a term known in low-level programming) may have a need to execute their payload with a specific periodicity they need, as well as priority. From this follows the fact that we cannot use one auction for all daemons at once; each daemon needs its own execution period and its own user reward model (for example, someone is willing to pay a lot to definitely execute in a certain time frame). Also, with one auction, we immediately fall into the bandwidth problem, because for most of the auction duration - calls are idle and the payload is not executed, and when the profit moment occurs, only a limited amount of useful work can be performed.

Therefore, we'll move away from the initial concept proposed by the author and choose a more complex and powerful ensemble auction model. This will allow us to regularly (even within one block!) create profit for profit seekers and perform payload.

#### Development of the Unibrain Idea

I'm giving the new concept the name Conflux. Now each daemon has the right to determine its own pricing model, both in terms of time and size.

How do we create profit in the pool? The fact is that there are many options. For example, you could go with a complex option using ERC1155 tokens for a direct liquidity management model, pricing, and provide such profit. But in fact, there's no point in such complications, because profit for the user can be created in the simplest way - rebate. That's exactly why we'll attach our payload specifically to _afterSwap.

We can simply increase the amount of tokens received after a swap. Looking ahead - I implemented this in a convenient way, allowing you to set the rebate in a specific single token. That is, for example, if the hook is configured to make rebates only in USDT and the rebate size at the moment will be 5 USDT, then regardless of the swap direction, the user's profit will be around 5 USDT. This is expressed in the fact that when a user buys USDT - they simply get 5 more. And when selling USDT - they receive as many tokens as if they had initially sold 5 USDT more.

Each daemon contract must inherit the IDaemon interface and have methods for getting the price and performing useful work. In the reference hook, they are executed with exception catching and limits of 50,000 and 300,000 gas respectively, but if desired, you can change these values in your version of the hook.

Daemons themselves are stored in a special registry and in the reference hook are added with the permission of the hook owner. However, the daemons are already owned by their owner, so after adding it to the registry, the owner can activate and deactivate their daemon.

Now the most interesting moment - each specific pricing model can provide different values at different block numbers, so we need to somehow sort them on-chain at the moment of swap. And here we encounter the fact that this idea cannot be fully implemented on-chain. But in that case, we must move the side calculations outside. However, we need to maintain the reliability and decentralization of our calculations. We'll do this using Chainlink Functions - which, thanks to the decentralized oracle network DON, will receive values, sort by score value, and return back to the blockchain.

#### Chainlink Functions

For Chainlink Functions (and for the simplicity of obtaining information about daemons by regular users and profit seekers), I defined complex contracts for storing all demons, as well as a contract for storing the local top. The thing is that Chainlink Functions has a limit on the size of the returned value (and the batch approach in our concept would be inconvenient). Therefore, we return 128 two-byte IDs, sorted by the size of the rebate they're willing to issue at the moment of the epoch start. The rotations of tops themselves are divided into these same epochs, which can be configured by duration in blocks by the hook owner. Epoch updates will be automatically requested, creating reliable and constant top rotation. Many aspects are taken into account here, from the callback size that Chainlink Functions limits per call, as well as the limit on HTTP calls themselves, execution time, size of data returned to the blockchain, etc.

### Results

Given the limitations we have - I managed in practice to have a registry size of up to 1000-1400 daemons, and the size of the current top in an epoch - 128 daemons, which is a very decent result. This hook can support multiple pools simultaneously, allowing the pool owner to enable and disable this functionality at will, as long as the pool has the token in which the rebate is made, which is easy if you choose a stablecoin as the rebate token.

A convenient interface was created that allows not only the Chainlink Functions script to efficiently obtain information, but also anyone who wants to calculate the profit for themselves in an upcoming swap.

Tests were written covering not only the hook functionality but also the Chainlink Functions part.

And finally, the Unibrain concept was developed, which hadn't gained traction before. I hope the author of the original idea will like my solution and appreciate it properly.

#### Main Challenges

The official Uniswap V4 hook template repository is written based on Foundry, which is good practice and should be used. It supports EVM Version Cancun.

But the official Chainlink Functions template repository is written based on Hardhat and supports ethers V5 and EVM Version Paris (Cancun support couldn't be achieved).

Therefore, it was decided to conduct hook testing mainly in Foundry due to the convenience of the environment and libraries. But local testing of Chainlink Functions with local DON was conducted in the Hardhat environment.

However, a deployment pipeline for the hook on ETH Sepolia was also provided and tested in practice, where the production version of interaction with Chainlink Functions was tested and rebate issuance was verified in practice.

## Future of the Project

I think I've brought the concept to its technical maximum. The only possible development is to transfer the calculation logic to the nodes themselves as a modification. This will allow achieving an even greater degree of calculation reliability and may become a step for developing the Ethereum infrastructure directly. Therefore, I'll now spend more time supporting RETH (Execution layer nodes written in Rust) and over time may begin work on an EIP and practical implementation of this concept on RETH.
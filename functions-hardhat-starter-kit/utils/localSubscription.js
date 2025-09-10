const { SubscriptionManager } = require("@chainlink/functions-toolkit")
const { ethers, network } = require("hardhat")
const { networks } = require("../networks")

async function createAndFundSubscription(consumer) {
  const signer = await ethers.getSigner()
  const ncfg = networks[network.name]
  if (!ncfg) throw new Error(`No network config for ${network.name}`)
  const functionsRouterAddress = ncfg.functionsRouter
  const linkTokenAddress = ncfg.linkToken

  const sm = new SubscriptionManager({ signer, linkTokenAddress, functionsRouterAddress })
  await sm.initialize()

  const txOptions = { confirmations: 1, overrides: { gasPrice: ncfg.gasPrice } }
  const subscriptionId = await sm.createSubscription({ consumerAddress: consumer, txOptions })

  const juelsAmount = ethers.utils.parseUnits("25", 18).toString()
  await sm.fundSubscription({ juelsAmount, subscriptionId, txOptions })

  return BigInt(subscriptionId)
}

module.exports = { createAndFundSubscription }

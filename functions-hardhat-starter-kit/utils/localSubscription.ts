// Мини-хелпер для локальной сети: создать и пополнить подписку для Functions
// через SubscriptionManager из @chainlink/functions-toolkit, используя адреса
// из обновлённого networks.js (перезаписывается startLocalFunctionsTestnet).

import { ethers, network } from "hardhat"
import { SubscriptionManager } from "@chainlink/functions-toolkit"
// eslint-disable-next-line @typescript-eslint/no-var-requires
const { networks } = require("../networks")

export async function createAndFundSubscription(consumer: string): Promise<bigint> {
  const signer = await ethers.getSigner()
  const ncfg = networks[network.name]
  if (!ncfg) throw new Error(`No network config for ${network.name}`)
  const functionsRouterAddress = ncfg.functionsRouter
  const linkTokenAddress = ncfg.linkToken

  const sm = new SubscriptionManager({ signer, linkTokenAddress, functionsRouterAddress })
  await sm.initialize()

  const txOptions = { confirmations: 1, overrides: { gasPrice: ncfg.gasPrice } }

  const subscriptionId = await sm.createSubscription({ consumerAddress: consumer, txOptions })

  const juelsAmount = ethers.utils.parseUnits("1000", 18).toString()
  await sm.fundSubscription({ juelsAmount, subscriptionId, txOptions })

  return BigInt(subscriptionId)
}



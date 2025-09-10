import { ethers, network } from "hardhat"
import fs from "fs"
import path from "path"

// Эти утилиты завезены стартером (локальный роутер/реестр, создание подписки и т.п.)
// Мы используем адрес роутера из переменной окружения стартера для локалки.

async function main() {
  // Read router and DON id from networks.js updated by startLocalFunctionsTestnet
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { networks } = require("../networks")
  const routerAddr = networks[network.name].functionsRouter
  const donId = networks[network.name].donId

  // Load registry address for constructor
  const fs = await import("fs")
  const path = await import("path")
  const dir = path.join(__dirname, "../deploy-artifacts")
  const reg = JSON.parse(fs.readFileSync(path.join(dir, "PointsRegistry.json"), "utf8"))

  const Consumer = await ethers.getContractFactory("Top3Consumer")
  const consumer = await Consumer.deploy(routerAddr, ethers.utils.formatBytes32String(donId), reg.address)
  await consumer.deployed()
  console.log("Top3Consumer:", consumer.address)

  // Создаём и пополняем подписку через лок. менеджер Functions (хелперы стартера)
  // Use JS helper for compatibility
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { createAndFundSubscription } = require("../utils/localSubscription.js")
  const subId = await createAndFundSubscription(consumer.address)
  console.log("Subscription:", subId.toString())

  writeArtifact("Top3Consumer", { address: consumer.address, subscriptionId: Number(subId) })
}

function writeArtifact(name: string, data: any) {
  const dir = path.join(__dirname, "../deploy-artifacts")
  if (!fs.existsSync(dir)) fs.mkdirSync(dir)
  fs.writeFileSync(path.join(dir, `${name}.json`), JSON.stringify(data, null, 2))
}

main().catch((e) => { console.error(e); process.exit(1) })



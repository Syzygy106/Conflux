// Local-only TopOracle deploy: also creates and funds a local Functions subscription
// eslint-disable-next-line @typescript-eslint/no-var-requires
const { ethers, network } = require("hardhat")
import fs from "fs"
import path from "path"

async function main() {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { networks } = require("../../networks")
  const routerAddr = networks[network.name].functionsRouter
  const donId = networks[network.name].donId

  const dir = path.join(__dirname, "../../deploy-artifacts")
  const registry = JSON.parse(fs.readFileSync(path.join(dir, "DaemonRegistryModerated.json"), "utf8"))

  const TopOracle = await ethers.getContractFactory("TopOracle")
  const topOracle = await TopOracle.deploy(routerAddr, ethers.utils.formatBytes32String(donId), registry.address, ethers.constants.AddressZero)
  await topOracle.deployed()
  console.log("TopOracle:", topOracle.address)

  const [deployer] = await ethers.getSigners()
  await topOracle.setHookAuthority(deployer.address)
  console.log("Hook authority set to:", deployer.address)

  // Create and fund subscription on localFunctionsTestnet
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { createAndFundSubscription } = require("../../utils/localSubscription.js")
  const subId = await createAndFundSubscription(topOracle.address)
  console.log("Local subscription:", subId.toString())

  writeArtifact("TopOracle", {
    address: topOracle.address,
    subscriptionId: Number(subId),
    hookAuthority: deployer.address,
  })
}

function writeArtifact(name: string, data: any) {
  const dir = path.join(__dirname, "../../deploy-artifacts")
  if (!fs.existsSync(dir)) fs.mkdirSync(dir)
  fs.writeFileSync(path.join(dir, `${name}.json`), JSON.stringify(data, null, 2))
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})



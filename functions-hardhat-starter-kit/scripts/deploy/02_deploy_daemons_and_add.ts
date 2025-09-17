import fs from "fs"
import path from "path"
// eslint-disable-next-line @typescript-eslint/no-var-requires
const { ethers } = require("hardhat")

async function main() {
  const registryAddress: string | undefined = process.env.REGISTRY
  if (!registryAddress) throw new Error("Set REGISTRY env to existing DaemonRegistryModerated address")

  const [deployer] = await ethers.getSigners()
  console.log("Deployer:", deployer.address)
  console.log("Registry:", registryAddress)

  // Deploy 5 LinearDaemon with varied parameters
  const LinearDaemon = await ethers.getContractFactory("contracts/v4/examples/LinearDaemon.sol:LinearDaemon")

  const params: Array<[number, number, number, number, number]> = [
    [1000, 6000, 50, 20, 0],
    [1500, 8000, 80, 15, 0],
    [2000, 9000, 120, 12, 0],
    [2500, 12000, 150, 10, 0],
    [3000, 15000, 200, 8, 0],
  ]

  const daemonAddrs: string[] = []
  for (let i = 0; i < params.length; i++) {
    const [startPrice, endPrice, priceInterest, growPeriod, startBlock] = params[i]
    const d = await LinearDaemon.deploy(startPrice, endPrice, priceInterest, growPeriod, startBlock)
    await d.deployed()
    daemonAddrs.push(d.address)
    console.log(`Daemon ${i + 1}:`, d.address)
  }

  // Attach to existing registry and add/activate
  const Registry = await ethers.getContractFactory("DaemonRegistryModerated")
  const registry = Registry.attach(registryAddress)

  const owners = new Array(daemonAddrs.length).fill(deployer.address)
  console.log("Adding daemons to registry...")
  const txAdd = await registry.addMany(daemonAddrs, owners)
  await txAdd.wait()
  console.log("Activating daemons...")
  const txAct = await registry.activateMany(daemonAddrs)
  await txAct.wait()

  writeArtifact("DaemonSet", { addresses: daemonAddrs })
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



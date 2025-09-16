import fs from "fs"
import path from "path"
// eslint-disable-next-line @typescript-eslint/no-var-requires
const { ethers } = require("hardhat")

async function main() {
  const [deployer] = await ethers.getSigners()
  console.log("Deployer:", deployer.address)

  const Registry = await ethers.getContractFactory("DaemonRegistryModerated")
  const registry = await Registry.deploy()
  await registry.deployed()
  console.log("DaemonRegistryModerated:", registry.address)

  writeArtifact("DaemonRegistryModerated", { address: registry.address })
}

function writeArtifact(name: string, data: any) {
  const dir = path.join(__dirname, "../deploy-artifacts")
  if (!fs.existsSync(dir)) fs.mkdirSync(dir)
  fs.writeFileSync(path.join(dir, `${name}.json`), JSON.stringify(data, null, 2))
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})



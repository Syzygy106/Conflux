// eslint-disable-next-line @typescript-eslint/no-var-requires
const { ethers, network } = require("hardhat")
import fs from "fs"
import path from "path"

async function main() {
  // Read router and DON id from networks.js updated by startLocalFunctionsTestnet
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { networks } = require("../../networks")
  const routerAddr = networks[network.name].functionsRouter
  const donId = networks[network.name].donId

  // Load registry address for constructor
  const fs = await import("fs")
  const path = await import("path")
  const dir = path.join(__dirname, "../../deploy-artifacts")
  const registry = JSON.parse(fs.readFileSync(path.join(dir, "DaemonRegistryModerated.json"), "utf8"))

  // Deploy TopOracle
  const TopOracle = await ethers.getContractFactory("TopOracle")
  const topOracle = await TopOracle.deploy(routerAddr, ethers.utils.formatBytes32String(donId), registry.address, ethers.constants.AddressZero)
  await topOracle.deployed()
  console.log("TopOracle:", topOracle.address)

  // Set hook authority (will be set later when hook is deployed)
  // For now, we'll use the deployer address as a placeholder
  const [deployer] = await ethers.getSigners()
  await topOracle.setHookAuthority(deployer.address)
  console.log("Hook authority set to:", deployer.address)

  writeArtifact("TopOracle", {
    address: topOracle.address,
    hookAuthority: deployer.address,
  })
}

function writeArtifact(name: string, data: any) {
  const dir = path.join(__dirname, "../../deploy-artifacts")
  if (!fs.existsSync(dir)) fs.mkdirSync(dir)
  fs.writeFileSync(path.join(dir, `${name}.json`), JSON.stringify(data, null, 2))
}

main().catch((e) => { 
  console.error(e); 
  process.exit(1) 
})

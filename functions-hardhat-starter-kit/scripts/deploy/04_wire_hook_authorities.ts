import fs from "fs"
import path from "path"
// eslint-disable-next-line @typescript-eslint/no-var-requires
const { ethers } = require("hardhat")

async function main() {
  const hookAddress: string | undefined = process.env.HOOK
  if (!hookAddress) throw new Error("Set HOOK env to deployed ConfluxHook address")

  const artifactsDir = path.join(__dirname, "../../deploy-artifacts")
  const topOracleJson = JSON.parse(fs.readFileSync(path.join(artifactsDir, "TopOracle.json"), "utf8"))
  const registryJson = JSON.parse(fs.readFileSync(path.join(artifactsDir, "DaemonRegistryModerated.json"), "utf8"))

  const topOracleAddr: string = process.env.TOP_ORACLE || topOracleJson.address
  const registryAddr: string = registryJson.address

  const [deployer] = await ethers.getSigners()
  console.log("Deployer:", deployer.address)
  console.log("Hook:", hookAddress)
  console.log("TopOracle:", topOracleAddr)
  console.log("Registry:", registryAddr)

  const TopOracle = await ethers.getContractFactory("TopOracle")
  const top = await TopOracle.attach(topOracleAddr)
  const tx1 = await top.setHookAuthority(hookAddress)
  await tx1.wait()
  console.log("TopOracle hookAuthority set")

  const Registry = await ethers.getContractFactory("DaemonRegistryModerated")
  const reg = await Registry.attach(registryAddr)
  const tx2 = await reg.setHookAuthority(hookAddress)
  await tx2.wait()
  console.log("Registry hookAuthority set")
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})



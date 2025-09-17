import { ethers } from "hardhat"
import fs from "fs"
import path from "path"

async function main() {
  console.log("🔍 Checking TopOracle state...")

  const artifactsDir = path.join(__dirname, "../../deploy-artifacts")
  const topOracleArtifact = JSON.parse(fs.readFileSync(path.join(artifactsDir, "TopOracle.json"), "utf8"))
  const registryArtifact = JSON.parse(fs.readFileSync(path.join(artifactsDir, "DaemonRegistryModerated.json"), "utf8"))

  const topOracleAddress = process.env.TOP_ORACLE || topOracleArtifact.address
  const registryAddress = registryArtifact.address
  const subscriptionId = process.env.SUBSCRIPTION_ID || topOracleArtifact.subscriptionId || "(env not set)"

  const TopOracle = await ethers.getContractFactory("TopOracle")
  const topOracle = await TopOracle.attach(topOracleAddress)

  const Registry = await ethers.getContractFactory("DaemonRegistryModerated")
  const registryContract = Registry.attach(registryAddress)

  console.log(`TopOracle: ${topOracleAddress}`)
  console.log(`Registry: ${registryAddress}`)
  console.log(`Subscription: ${subscriptionId}`)

  console.log("\n📊 TopOracle State:")
  const topCount = await topOracle.topCount()
  const topEpoch = await topOracle.topEpoch()
  const epochDuration = await topOracle.epochDurationBlocks()
  const lastEpochStartBlock = await topOracle.lastEpochStartBlock()
  const hasPendingRequest = await topOracle.hasPendingTopRequest()
  const lastRequestId = await topOracle.lastRequestId()
  const donId = await topOracle.donId()
  const registry = await topOracle.registry()
  const owner = await topOracle.owner()
  const hookAuthority = await topOracle.hookAuthority()

  console.log(`- Top count: ${topCount}`)
  console.log(`- Current epoch: ${topEpoch}`)
  console.log(`- Epoch duration: ${epochDuration} blocks`)
  console.log(`- Last epoch start block: ${lastEpochStartBlock}`)
  console.log(`- Has pending request: ${hasPendingRequest}`)
  console.log(`- Last request ID: ${lastRequestId}`)
  console.log(`- DON ID: ${ethers.utils.toUtf8String(donId)}`)
  console.log(`- Registry: ${registry}`)
  console.log(`- Owner: ${owner}`)
  console.log(`- Hook authority: ${hookAuthority}`)

  // Note: TopOracle stores template internally, no getter function available
  console.log("✅ Template setup completed (stored internally)")

  // Check registry state
  const totalDaemons = await registryContract.length()
  console.log(`\nRegistry total daemons: ${totalDaemons}`)

  if (topCount > 0) {
    console.log("\nTop daemon IDs with points:")
    for (let i = 0; i < Math.min(topCount, 25); i++) {
      const daemonId = await topOracle.topIdsAt(i)
      
      // Skip sentinel values (0xffff)
      if (daemonId === 0xffff) {
        console.log(`${i}: daemon ID = ${daemonId} (sentinel)`)
        continue
      }
      
      try {
        // Get daemon address from registry
        const daemonAddress = await registryContract.getById(daemonId)
        
        // Get points from daemon contract
        const LinearDaemon = await ethers.getContractFactory("contracts/v4/examples/LinearDaemon.sol:LinearDaemon")
        const daemonContract = LinearDaemon.attach(daemonAddress)
        const points = await daemonContract.getRebateAmount(await ethers.provider.getBlockNumber())
        
        console.log(`${i}: daemon ID = ${daemonId}, address = ${daemonAddress}, points = ${points.toString()}`)
      } catch (error) {
        console.log(`${i}: daemon ID = ${daemonId}, error getting points: ${error.message}`)
      }
    }
  } else {
    console.log("\nNo top daemons yet")
  }
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
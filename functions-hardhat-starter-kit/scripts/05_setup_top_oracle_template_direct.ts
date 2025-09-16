import { ethers } from "hardhat"
import fs from "fs"
import path from "path"

async function main() {
  console.log("🔧 Setting up TopOracle request template with direct parameters...")

  const artifactsDir = path.join(__dirname, "../deploy-artifacts")
  const topOracleArtifact = JSON.parse(fs.readFileSync(path.join(artifactsDir, "TopOracle.json"), "utf8"))
  const registryArtifact = JSON.parse(fs.readFileSync(path.join(artifactsDir, "DaemonRegistryModerated.json"), "utf8"))

  const topOracleAddress = topOracleArtifact.address
  const registryAddress = registryArtifact.address
  const subscriptionId = topOracleArtifact.subscriptionId

  const TopOracle = await ethers.getContractFactory("TopOracle")
  const topOracle = await TopOracle.attach(topOracleAddress)

  console.log(`TopOracle: ${topOracleAddress}`)
  console.log(`Registry: ${registryAddress}`)
  console.log(`Subscription: ${subscriptionId}`)

  // Read the Functions source
  const functionsRequestSource = fs.readFileSync(
    path.join(__dirname, "../functions/source/topDaemonsFromRegistry.js"),
    "utf8"
  )

  // Set request template with direct parameters (no CBOR encoding!)
  const secretsLocation = 2 // Location.DONHosted
  const encryptedSecretsReference = "0x" // Empty for DONHosted
  const args = [registryAddress] // Registry address
  const bytesArgs = [] // Empty
  const callbackGasLimit = 300000

  console.log("Setting request template with direct parameters...")
  
  await topOracle.setRequestTemplate(
    functionsRequestSource,
    secretsLocation,
    encryptedSecretsReference,
    args,
    bytesArgs,
    subscriptionId,
    callbackGasLimit
  )
  
  console.log("✅ TopOracle request template set successfully!")
  
  // Also set epoch duration
  console.log("Setting epoch duration to 10 blocks for testing...")
  await topOracle.setEpochDuration(10)
  
  console.log("✅ TopOracle setup completed!")
  
  // Now trigger the first request with proper gas limit
  console.log("🚀 Triggering first Functions request via refreshTopNow()...")
  try {
    const gasEstimate = await topOracle.estimateGas.refreshTopNow()
    const tx = await topOracle.refreshTopNow({ gasLimit: gasEstimate.mul(2) })
    console.log(`✅ Functions request triggered! Transaction: ${tx.hash}`)
    const receipt = await tx.wait()
    console.log(`✅ Transaction mined! Status: ${receipt.status}`)
    
    if (receipt.status === 1) {
      const hasPending = await topOracle.hasPendingTopRequest()
      const lastRequestId = await topOracle.lastRequestId()
      console.log(`✅ Request sent successfully! Pending: ${hasPending}`)
      console.log(`✅ Request ID: ${lastRequestId}`)
    }
  } catch (error) {
    console.log(`❌ Error triggering request: ${error.message}`)
  }
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})

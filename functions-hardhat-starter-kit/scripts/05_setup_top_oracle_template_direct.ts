import { SecretsManager } from "@chainlink/functions-toolkit"
import fs from "fs"
import path from "path"

async function main() {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { ethers, network } = require("hardhat")
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

  // Use empty reference on local; build DON-hosted reference on live networks
  let encryptedSecretsReference = "0x"
  if (network.name !== "localFunctionsTestnet") {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { networks } = require("../networks")
    const functionsRouterAddress = networks[network.name].functionsRouter
    const donId = networks[network.name].donId

    const slotIdStr = process.env.DON_SECRETS_SLOT_ID
    const versionStr = process.env.DON_SECRETS_VERSION
    if (!slotIdStr || !versionStr) {
      throw new Error(
        "Missing DON secrets reference. Set DON_SECRETS_SLOT_ID and DON_SECRETS_VERSION environment variables."
      )
    }

    const [signer] = await ethers.getSigners()
    const secretsManager = new SecretsManager({ signer, functionsRouterAddress, donId })
    await secretsManager.initialize()
    encryptedSecretsReference = secretsManager.buildDONHostedEncryptedSecretsReference({
      slotId: parseInt(slotIdStr),
      version: parseInt(versionStr),
    })
    console.log(
      `Using DON-hosted secrets reference (slotId=${slotIdStr}, version=${versionStr}) for network ${network.name}`
    )
  } else {
    console.log("Local network detected: using inline secrets from local Functions runner")
  }
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

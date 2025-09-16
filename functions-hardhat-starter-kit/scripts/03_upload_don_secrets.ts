import { SecretsManager } from "@chainlink/functions-toolkit"
// eslint-disable-next-line @typescript-eslint/no-var-requires
const { ethers, network } = require("hardhat")
import { networks } from "../networks"

/**
 * Uploads DON-hosted secrets for Chainlink Functions and prints slot/version.
 * Expects env vars for your HTTP node key (and optional RPC URL/chainId override).
 *
 * Env:
 * - HTTP_NODE_KEY: your private API key or bearer token (required)
 * - RPC_URL (optional): override RPC URL used by offchain source
 * - CHAIN_ID (optional): override chain id used by offchain source
 * - SLOT_ID (optional): integer slot to write to (default: 1)
 * - TTL_MIN (optional): minutes to live (min 5, default: 60)
 */
async function main() {
  const signer = await ethers.getSigner()
  const cfg = networks[network.name]
  if (!cfg) throw new Error(`No networks config for ${network.name}`)

  const functionsRouterAddress = cfg.functionsRouter
  const donId = cfg.donId
  const gatewayUrls = cfg.gatewayUrls

  const rpcUrl = process.env.RPC_URL || cfg.url
  const chainId = parseInt(process.env.CHAIN_ID || String(cfg.chainId || 11155111))

  const slotId = parseInt(process.env.SLOT_ID || "1")
  const minutesUntilExpiration = parseInt(process.env.TTL_MIN || "60")

  const secretsManager = new SecretsManager({ signer, functionsRouterAddress, donId })
  await secretsManager.initialize()

  // Secrets object must be a flat key/value map
  const secrets: Record<string, string> = {
    rpcUrl,
    chainId: String(chainId),
  }
  if (process.env.HTTP_NODE_KEY) {
    secrets.httpNodeKey = String(process.env.HTTP_NODE_KEY)
  }

  console.log("Encrypting secrets and uploading to DON...")
  const encryptedSecretsObj = await secretsManager.encryptSecrets(secrets)

  const { version, success } = await secretsManager.uploadEncryptedSecretsToDON({
    encryptedSecretsHexstring: encryptedSecretsObj.encryptedSecrets,
    gatewayUrls,
    slotId,
    minutesUntilExpiration,
  })

  if (!success) console.warn("Warning: Not all DON nodes acknowledged the upload.")
  console.log(`\nDON secrets uploaded.`)
  console.log(`Slot ID: ${slotId}`)
  console.log(`Version: ${version}`)
  console.log(`\nExport and use these values in setup script:`)
  console.log(`export DON_SECRETS_SLOT_ID=${slotId}`)
  console.log(`export DON_SECRETS_VERSION=${version}`)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})



const fs = require("fs")
const path = require("path")

function readJson(p) {
  return JSON.parse(fs.readFileSync(p, "utf8"))
}

const artifactsDir = path.join(__dirname, "../deploy-artifacts")

// Load V4 contract addresses from deployment artifacts
const registry = readJson(path.join(artifactsDir, "DaemonRegistryModerated.json"))
const topOracle = readJson(path.join(artifactsDir, "TopOracle.json"))

module.exports = {
  codeLocation: 0, // Inline
  source: fs.readFileSync(path.join(__dirname, "source/topDaemonsFromRegistry.js"), "utf8"),
  donId: "local-functions-testnet",
  subscriptionId: topOracle.subscriptionId,
  callbackGasLimit: 300000,
  secretsLocation: 2, // Location.DONHosted
  secrets: {
    rpcUrl: "http://localhost:8545",
    chainId: "1337",
  },
  args: [registry.address], // Pass registry address only (like working config)
  expectedReturnType: "bytes",
}
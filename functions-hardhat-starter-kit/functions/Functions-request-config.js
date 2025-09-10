// Config for `npx hardhat functions-request --network localhost --configpath functions/Functions-request-config.js`
// Автоматически подхватывает адреса из артефактов деплоя и собирает запрос.

const fs = require("fs")
const path = require("path")

function readJson(p) {
  return JSON.parse(fs.readFileSync(p, "utf8"))
}
const artifactsDir = path.join(__dirname, "../deploy-artifacts")

const reg = readJson(path.join(artifactsDir, "PointsRegistry.json"))
const consumer = readJson(path.join(artifactsDir, "Top3Consumer.json"))

module.exports = {
  // Inline JS source
  codeLocation: 0, // Inline
  source: fs.readFileSync(path.join(__dirname, "source/top3FromRegistry.js"), "utf8"),

  // Don / billing
  donId: "local-functions-testnet",
  subscriptionId: consumer.subscriptionId, // создано скриптом деплоя
  callbackGasLimit: 300000,

  // Secrets & args
  secretsLocation: 1, // Remote by default for toolkit; we use no secrets on local
  // Args: registry only (registry provides compact aggregation APIs)
  args: [reg.address],
  expectedReturnType: "bytes",

  // Target consumer (если скрипт functions-request попросит)
  // consumerAddress: consumer.address,
}

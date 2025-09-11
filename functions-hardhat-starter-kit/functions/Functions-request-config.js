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
  secretsLocation: 2, // Location.DONHosted for production-like setup
  secrets: {
    // Пример секретов для продакшена (API ключи, RPC URLs и т.д.)
    rpcUrl: "http://localhost:8545",
    chainId: "1337",
    // apiKey: "your-api-key-here", // раскомментировать при необходимости
  },
  // Args: registry only (registry provides compact aggregation APIs)
  args: [reg.address],
  expectedReturnType: "bytes",

  // Target consumer (если скрипт functions-request попросит)
  // consumerAddress: consumer.address,
}

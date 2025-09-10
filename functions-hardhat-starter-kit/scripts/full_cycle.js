const { execSync } = require("child_process")
const fs = require("fs")
const path = require("path")

function sh(cmd, extraEnv = {}) {
  execSync(cmd, {
    stdio: "inherit",
    env: { ...process.env, ...extraEnv },
  })
}

async function main() {
  const DEFAULT_PK = "0x59c6995e998f97a5a0044966f094538cfd0b0b7a7f7a5d3bdc0b6d1d5a0b7a5c"
  const PK = process.env.PRIVATE_KEY || DEFAULT_PK

  // 1) Compile
  sh(`npx hardhat compile`, { PRIVATE_KEY: PK })

  // 2) Deploy Points + Registry
  sh(`npx hardhat run scripts/00_deploy_points_and_registry.ts --network localFunctionsTestnet`, { PRIVATE_KEY: PK })

  // 3) Deploy Multicall
  sh(`npx hardhat run scripts/01b_deploy_multicall.ts --network localFunctionsTestnet`, { PRIVATE_KEY: PK })

  // 4) Optional sanity test for multicall
  sh(`npx hardhat run scripts/99_test_multicall.ts --network localFunctionsTestnet`, { PRIVATE_KEY: PK })

  // 5) Deploy Consumer (creates+funds subscription)
  sh(`npx hardhat run scripts/02_deploy_consumer.ts --network localFunctionsTestnet`, { PRIVATE_KEY: PK })

  // 6) Read consumer & subId
  const artifactsDir = path.join(__dirname, "../deploy-artifacts")
  const consumer = JSON.parse(fs.readFileSync(path.join(artifactsDir, "Top3Consumer.json"), "utf8"))
  const consumerAddr = consumer.address
  const subId = consumer.subscriptionId

  // 7) Send Functions request
  sh(
    `SKIP_PROMPTS=1 npx hardhat functions-request --network localFunctionsTestnet --configpath functions/Functions-request-config.js --contract ${consumerAddr} --subid ${subId} --simulate false --callbackgaslimit 300000`,
    { PRIVATE_KEY: PK }
  )

  // 8) Verify consumer state
  sh(`npx hardhat run scripts/03_check_consumer_state.ts --network localFunctionsTestnet`, { PRIVATE_KEY: PK })
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})

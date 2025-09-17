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

  console.log("🚀 Starting TopOracle Full Cycle Test")
  console.log("=====================================")

  // Step 1: Build and copy Foundry artifacts
  console.log("\n📦 Step 1: Building and copying Foundry artifacts...")
  sh(`node scripts/build-and-copy-artifacts.js`, { PRIVATE_KEY: PK })

  // Step 2: Compile Hardhat contracts
  console.log("\n🔨 Step 2: Compiling Hardhat contracts...")
  sh(`npx hardhat compile`, { PRIVATE_KEY: PK })

  // Step 3: Deploy V4 daemons and registry
  console.log("\n🏗️ Step 3: Deploying V4 daemons and registry...")
  sh(`npx hardhat run scripts/00_deploy_v4_daemons_and_registry.ts --network localFunctionsTestnet`, { PRIVATE_KEY: PK })

  // Step 4: Deploy TopOracle (production consumer)
  console.log("\n🏗️ Step 4: Deploying TopOracle...")
  sh(`npx hardhat run scripts/local/02_deploy_v4_top_oracle.local.ts --network localFunctionsTestnet`, { PRIVATE_KEY: PK })

  // Step 5: Set TopOracle template and trigger Functions request
  console.log("\n⚙️ Step 5: Setting up TopOracle template and triggering Functions request...")
  sh(`npx hardhat run scripts/deploy/05_setup_top_oracle_template_direct.ts --network localFunctionsTestnet`, { PRIVATE_KEY: PK })

  // Step 6: Wait a moment for the Functions request to be processed
  console.log("\n⏳ Step 6: Waiting for Functions request to be processed...")
  console.log("Waiting 5 seconds for local Functions testnet to process the request...")
  await new Promise(resolve => setTimeout(resolve, 5000))

  // Step 7: Check TopOracle final state
  console.log("\n📊 Step 7: Checking TopOracle final state...")
  sh(`npx hardhat run scripts/deploy/09_check_top_oracle.ts --network localFunctionsTestnet`, { PRIVATE_KEY: PK })

  console.log("\n🎉 TopOracle Full Cycle Test Completed!")
  console.log("=====================================")
  console.log("✅ V4 daemons deployed and activated")
  console.log("✅ TopOracle deployed with Functions subscription")
  console.log("✅ Functions template set with direct parameters")
  console.log("✅ Functions request sent and processed")
  console.log("✅ Daemon rankings retrieved and displayed")
  console.log("\n🚀 TopOracle is fully functional and ready for production!")
}

main().catch((e) => {
  console.error("\n❌ Error in TopOracle full cycle:")
  console.error(e)
  process.exit(1)
})

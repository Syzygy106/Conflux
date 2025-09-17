const process = require("process")
const path = require("path")
const fs = require("fs")
const { startLocalFunctionsTestnet } = require("@chainlink/functions-toolkit")
const { utils, Wallet } = require("ethers")

// Loads environment variables from .env.enc file (if it exists)
require("@chainlink/env-enc").config("../.env.enc")

;(async () => {
  try {
    console.log("🚀 Starting Local Functions Testnet for V4 Architecture...")
    
    // Use the V4 request config
    const requestConfigPath = path.join(process.cwd(), "functions/Functions-request-config-v4.js")
    console.log(`Using Functions request config file: ${requestConfigPath}\n`)

    const localFunctionsTestnetInfo = await startLocalFunctionsTestnet(
      requestConfigPath,
      {
        logging: {
          debug: false,
          verbose: false,
          quiet: false, // Set to false to see logs
        },
        // Ganache chain options
        chain: {
          // Set block gas limit to 50,000,000 as per testing plan
          blockGasLimit: 50_000_000,
          // Add more funding options
          accounts: {
            mnemonic: "test test test test test test test test test test test junk",
            count: 20,
            initialIndex: 0,
            path: "m/44'/60'/0'/0",
            accountsBalance: "10000000000000000000000", // 10000 ETH per account
          }
        },
      }
    )

    console.log("\n✅ Local Functions Testnet Started Successfully!")
    console.table({
      "FunctionsRouter Contract Address": localFunctionsTestnetInfo.functionsRouterContract.address,
      "DON ID": localFunctionsTestnetInfo.donId,
      "Mock LINK Token Contract Address": localFunctionsTestnetInfo.linkTokenContract.address,
    })

    // Fund wallets with ETH and LINK
    const addressToFund = new Wallet(process.env["PRIVATE_KEY"]).address
    console.log(`\n💰 Funding wallet: ${addressToFund}`)
    
    await localFunctionsTestnetInfo.getFunds(addressToFund, {
      weiAmount: utils.parseEther("100").toString(), // 100 ETH
      juelsAmount: utils.parseEther("100000").toString(), // 100,000 LINK
    })
    
    console.log("✅ Wallet funded with 100 ETH and 100,000 LINK")

    if (process.env["SECOND_PRIVATE_KEY"]) {
      const secondAddressToFund = new Wallet(process.env["SECOND_PRIVATE_KEY"]).address
      console.log(`💰 Funding second wallet: ${secondAddressToFund}`)
      
      await localFunctionsTestnetInfo.getFunds(secondAddressToFund, {
        weiAmount: utils.parseEther("100").toString(), // 100 ETH
        juelsAmount: utils.parseEther("100000").toString(), // 100,000 LINK
      })
      
      console.log("✅ Second wallet funded")
    }

    // Update values in networks.js
    let networksConfig = fs.readFileSync(path.join(process.cwd(), "networks.js")).toString()
    const regex = /localFunctionsTestnet:\s*{\s*([^{}]*)\s*}/s
    const newContent = `localFunctionsTestnet: {
    url: "http://localhost:8545/",
    accounts,
    confirmations: 1,
    nativeCurrencySymbol: "ETH",
    linkToken: "${localFunctionsTestnetInfo.linkTokenContract.address}",
    functionsRouter: "${localFunctionsTestnetInfo.functionsRouterContract.address}",
    donId: "${localFunctionsTestnetInfo.donId}",
  }`
    networksConfig = networksConfig.replace(regex, newContent)
    fs.writeFileSync(path.join(process.cwd(), "networks.js"), networksConfig)
    
    console.log("✅ Networks.js updated with testnet addresses")
    console.log("\n🎉 Local Functions Testnet is ready!")
    console.log("You can now run your V4 tests in another terminal.")
    
  } catch (error) {
    console.error("❌ Error starting local testnet:", error.message)
    console.error("Full error:", error)
    process.exit(1)
  }
})()

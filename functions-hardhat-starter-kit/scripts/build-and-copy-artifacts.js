const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

async function main() {
  const v4TemplatePath = path.join(__dirname, "../../v4-template");
  const hardhatArtifactsPath = path.join(__dirname, "../build/artifacts");
  const hardhatContractsPath = path.join(__dirname, "../contracts/v4");

  console.log("🔨 Building Foundry contracts...");
  
  // Build Foundry contracts (best-effort). If it fails (e.g., optional scripts), continue to copy sources.
  try {
    execSync("forge build", { 
      cwd: v4TemplatePath,
      stdio: "inherit" 
    });
  } catch (e) {
    console.warn("⚠️  forge build failed — continuing with source copy and Hardhat compile only.");
  }

  console.log("📁 Creating v4 contracts directory in Hardhat...");
  
  // Create v4 directory in Hardhat contracts
  if (!fs.existsSync(hardhatContractsPath)) {
    fs.mkdirSync(hardhatContractsPath, { recursive: true });
  }

  // Copy key contracts to Hardhat (skip ConfluxHook.sol as it has Uniswap dependencies)
  const contractsToCopy = [
    // "ConfluxHook.sol", // Skip - has Uniswap dependencies, use ConfluxHookSimple.sol instead
    "TopOracle.sol", 
    "DaemonRegistryModerated.sol",
    "base/DaemonRegistry.sol",
    "base/Errors.sol",
    "base/HookOwnable.sol",
    // "base/PoolOwnable.sol", // Skip - has Uniswap dependencies, use our mock instead
    "interfaces/IDaemon.sol",
    "examples/LinearDaemon.sol"
  ];

  for (const contract of contractsToCopy) {
    const srcPath = path.join(v4TemplatePath, "src", contract);
    const destPath = path.join(hardhatContractsPath, contract);
    const destDir = path.dirname(destPath);
    
    if (!fs.existsSync(destDir)) {
      fs.mkdirSync(destDir, { recursive: true });
    }
    
    if (fs.existsSync(srcPath)) {
      fs.copyFileSync(srcPath, destPath);
      console.log(`✅ Copied ${contract}`);
    } else {
      console.log(`⚠️  Contract not found: ${contract}`);
    }
  }

  console.log("📋 Copying Foundry artifacts to Hardhat...");
  
  // Copy Foundry artifacts to Hardhat build directory
  const foundryArtifactsPath = path.join(v4TemplatePath, "out");
  const foundryArtifacts = [
    // "ConfluxHook.sol/ConfluxHook.json", // Skip - has Uniswap dependencies
    "TopOracle.sol/TopOracle.json", 
    "DaemonRegistryModerated.sol/DaemonRegistryModerated.json",
    "base/DaemonRegistry.sol/DaemonRegistry.json",
    "interfaces/IDaemon.sol/IDaemon.json",
    "examples/LinearDaemon.sol/LinearDaemon.json"
  ];

  for (const artifact of foundryArtifacts) {
    const srcPath = path.join(foundryArtifactsPath, artifact);
    const destPath = path.join(hardhatArtifactsPath, artifact);
    const destDir = path.dirname(destPath);
    
    if (!fs.existsSync(destDir)) {
      fs.mkdirSync(destDir, { recursive: true });
    }
    
    if (fs.existsSync(srcPath)) {
      fs.copyFileSync(srcPath, destPath);
      console.log(`✅ Copied artifact ${artifact}`);
    } else {
      console.log(`⚠️  Artifact not found: ${artifact}`);
    }
  }

  console.log("🎉 Build and copy completed!");
  console.log("Next steps:");
  console.log("1. Run: npx hardhat compile");
  console.log("2. Update your Functions request config");
  console.log("3. Run your Chainlink Functions tests");
}

main().catch((error) => {
  console.error("❌ Error:", error);
  process.exit(1);
});

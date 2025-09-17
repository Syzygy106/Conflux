import fs from "fs"
import path from "path"
// eslint-disable-next-line @typescript-eslint/no-var-requires
const { ethers, network } = require("hardhat")

const LINK_SEPOLIA = "0x779877A7B0D9E8603169DdbD7836e478b4624789"
const POOL_MANAGER_BY_CHAIN: Record<number, string> = {
  11155111: "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543", // Sepolia
}

async function main() {
  const chainId: number = network.config.chainId || (await ethers.provider.getNetwork()).chainId
  const poolManager: string | undefined = process.env.POOL_MANAGER || POOL_MANAGER_BY_CHAIN[chainId]
  if (!poolManager) throw new Error(`POOL_MANAGER address not set for chainId ${chainId}`)

  const linkToken = process.env.REBATE_TOKEN || LINK_SEPOLIA
  const linkAmount = ethers.utils.parseUnits(process.env.REBATE_AMOUNT || "1", 18) // 1 LINK per daemon
  const ethAmount = ethers.utils.parseEther(process.env.REBATE_ETH || "0.05")

  const artifactsDir = path.join(__dirname, "../../deploy-artifacts")
  const setPath = path.join(artifactsDir, "DaemonSet.json")
  if (!fs.existsSync(setPath)) throw new Error("DaemonSet.json not found. Run 02_deploy_daemons_and_add first.")
  const { addresses } = JSON.parse(fs.readFileSync(setPath, "utf8")) as { addresses: string[] }

  const [deployer] = await ethers.getSigners()
  console.log("Deployer:", deployer.address)
  console.log("PoolManager:", poolManager)
  console.log("LINK token:", linkToken)

  const LinearDaemon = await ethers.getContractFactory("contracts/v4/examples/LinearDaemon.sol:LinearDaemon")
  // Use minimal ERC20 ABI to avoid relying on local LinkToken artifact
  const erc20Abi = [
    "function balanceOf(address) view returns (uint256)",
    "function transfer(address,uint256) returns (bool)",
  ]
  const Link = new ethers.Contract(linkToken, erc20Abi, deployer)

  // Check deployer LINK balance
  const bal = await Link.balanceOf(deployer.address)
  const need = linkAmount.mul(addresses.length)
  if (bal.lt(need)) {
    console.warn(`Warning: deployer has ${ethers.utils.formatUnits(bal, 18)} LINK, needs ${ethers.utils.formatUnits(need, 18)} LINK`)
  }

  for (let i = 0; i < addresses.length; i++) {
    const addr = addresses[i]
    const d = await LinearDaemon.attach(addr)
    console.log(`\nConfiguring daemon ${i + 1}: ${addr}`)

    // 1) Set rebate token
    const tx1 = await d.setRebateToken(linkToken)
    await tx1.wait()

    // 2) Fund LINK to the daemon
    const tx2 = await Link.transfer(addr, linkAmount)
    await tx2.wait()

    // 3) Approve PoolManager to pull LINK from the daemon
    const tx3 = await d.approveRebateSpender(poolManager, linkAmount)
    await tx3.wait()

    // 4) Send a bit of ETH (default 0.05); guarded with try/catch
    if (ethAmount.gt(0)) {
      try {
        const tx4 = await deployer.sendTransaction({ to: addr, value: ethAmount, gasLimit: 100000 })
        await tx4.wait()
        console.log(`ETH sent: ${ethers.utils.formatEther(ethAmount)} to ${addr}`)
      } catch (e) {
        console.warn(`ETH send failed to ${addr}, continuing.`)
      }
    }

    console.log(`Done: token set, ${ethers.utils.formatUnits(linkAmount, 18)} LINK sent, approval set, ETH handled`)
  }
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})



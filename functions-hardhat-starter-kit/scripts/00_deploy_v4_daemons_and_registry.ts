import { ethers } from "hardhat"
import crypto from "crypto"
import fs from "fs"
import path from "path"

async function main() {
  const [deployer] = await ethers.getSigners()
  console.log("Deployer:", deployer.address)

  // Deploy LinearDaemon contracts (example daemons)
  const LinearDaemon = await ethers.getContractFactory("contracts/v4/examples/LinearDaemon.sol:LinearDaemon")
  const daemonAddrs: string[] = []

  const totalEnv = process.env.TOTAL_DAEMONS
  const activeEnv = process.env.ACTIVE_DAEMONS
  const total = Math.max(0, Math.min(1200, totalEnv ? parseInt(totalEnv) : 50))
  const activeTarget = Math.max(0, Math.min(total, activeEnv ? parseInt(activeEnv) : Math.floor(total / 2)))

  // Optional seed for reproducibility
  const seed = process.env.SEED ? parseInt(process.env.SEED) : Date.now()
  const rng = crypto.createHash("sha256").update(seed.toString()).digest()
  let rngIdx = 0
  function randInt(maxExclusive: number): number {
    const v = rng[rngIdx % rng.length]
    rngIdx++
    return v % maxExclusive
  }

  console.log(`Deploying ${total} LinearDaemon contracts...`)

  // Deploy LinearDaemon contracts with varied parameters
  for (let i = 0; i < total; i++) {
    // Create varied parameters for each daemon
    const startPrice = 1000 + randInt(9000) // 1000-10000
    const endPrice = startPrice + 5000 + randInt(10000) // 5000-15000 above start
    const priceInterest = 10 + randInt(90) // 10-100
    const growPeriod = 10 + randInt(40) // 10-50 blocks
    const startBlock = 0 // Start immediately

    const daemon = await LinearDaemon.deploy(
      startPrice,
      endPrice, 
      priceInterest,
      growPeriod,
      startBlock
    )
    await daemon.deployed()
    daemonAddrs.push(daemon.address)
    
    if (i % 10 === 0) {
      console.log(`Deployed daemon ${i + 1}/${total}: ${daemon.address}`)
    }
  }

  console.log("Daemon count:", daemonAddrs.length)

  // Deploy DaemonRegistryModerated
  const Registry = await ethers.getContractFactory("DaemonRegistryModerated")
  const registry = await Registry.deploy()
  await registry.deployed()
  console.log("Registry:", registry.address)

  // Add daemons to registry with deployer as owner
  const CHUNK = 50
  const owners = new Array(daemonAddrs.length).fill(deployer.address)
  
  for (let i = 0; i < daemonAddrs.length; i += CHUNK) {
    const chunk = daemonAddrs.slice(i, i + CHUNK)
    const ownerChunk = owners.slice(i, i + CHUNK)
    const tx = await registry.addMany(chunk, ownerChunk)
    await tx.wait()
    console.log(`Added daemons ${i + 1}-${Math.min(i + CHUNK, daemonAddrs.length)} to registry`)
  }

  // Decide which daemons to activate
  const toActivate: string[] = []
  if (activeTarget > 0) {
    // Pick first N for determinism, then shuffle mildly
    const idxs = [...Array(daemonAddrs.length).keys()]
    // Simple Fisher-Yates using rng
    for (let i = idxs.length - 1; i > 0; i--) {
      const j = randInt(i + 1)
      ;[idxs[i], idxs[j]] = [idxs[j], idxs[i]]
    }
    for (let i = 0; i < activeTarget; i++) toActivate.push(daemonAddrs[idxs[i]])
  }

  // Activate daemons in chunks
  for (let i = 0; i < toActivate.length; i += CHUNK) {
    const chunk = toActivate.slice(i, i + CHUNK)
    const tx = await registry.activateMany(chunk)
    await tx.wait()
  }
  console.log("Activated daemon count:", toActivate.length)

  writeArtifact("DaemonRegistryModerated", { address: registry.address })
  writeArtifact("DaemonSet", { addresses: daemonAddrs })
}

function writeArtifact(name: string, data: any) {
  const dir = path.join(__dirname, "../deploy-artifacts")
  if (!fs.existsSync(dir)) fs.mkdirSync(dir)
  fs.writeFileSync(path.join(dir, `${name}.json`), JSON.stringify(data, null, 2))
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})

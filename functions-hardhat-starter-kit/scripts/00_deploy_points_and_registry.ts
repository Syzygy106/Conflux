import { ethers } from "hardhat"
import crypto from "crypto"
import fs from "fs"
import path from "path"

async function main() {
  const [deployer] = await ethers.getSigners()
  console.log("Deployer:", deployer.address)

  const Points = await ethers.getContractFactory("Points")
  const pointsAddrs: string[] = []

  const totalEnv = process.env.TOTAL_POINTS
  const activeEnv = process.env.ACTIVE_POINTS
  const total = Math.max(0, Math.min(3200, totalEnv ? parseInt(totalEnv) : 100))
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

  // Deploy Points contracts
  for (let i = 0; i < total; i++) {
    // Fixed tops for visibility
    let score: number
    if (i === 10) score = 999
    else if (i === 6) score = 888
    else if (i === 69) score = 777
    else score = 1 + randInt(100)
    const c = await Points.deploy(score)
    await c.deployed()
    pointsAddrs.push(c.address)
  }
  console.log("Points count:", pointsAddrs.length)

  const Registry = await ethers.getContractFactory("PointsRegistry")
  const reg = await Registry.deploy()
  await reg.deployed()

  // Chunked addMany to avoid huge tx data
  const CHUNK = 100
  for (let i = 0; i < pointsAddrs.length; i += CHUNK) {
    const chunk = pointsAddrs.slice(i, i + CHUNK)
    const tx = await reg.addMany(chunk)
    await tx.wait()
  }
  console.log("Registry:", reg.address)

  // Decide which addresses to activate
  const toActivate: string[] = []
  if (activeTarget > 0) {
    // pick first N for determinism, then shuffle mildly
    const idxs = [...Array(pointsAddrs.length).keys()]
    // simple Fisher-Yates using rng
    for (let i = idxs.length - 1; i > 0; i--) {
      const j = randInt(i + 1)
      ;[idxs[i], idxs[j]] = [idxs[j], idxs[i]]
    }
    for (let i = 0; i < activeTarget; i++) toActivate.push(pointsAddrs[idxs[i]])
  }

  // Chunked activateMany
  for (let i = 0; i < toActivate.length; i += CHUNK) {
    const chunk = toActivate.slice(i, i + CHUNK)
    const tx = await reg.activateMany(chunk)
    await tx.wait()
  }
  console.log("Activated count:", toActivate.length)

  writeArtifact("PointsRegistry", { address: reg.address })
  writeArtifact("PointsSet", { addresses: pointsAddrs })
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



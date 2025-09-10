import { ethers } from "hardhat"
import fs from "fs"
import path from "path"

async function main() {
  const dir = path.join(__dirname, "../deploy-artifacts")
  const consumer = JSON.parse(fs.readFileSync(path.join(dir, "Top3Consumer.json"), "utf8"))
  const registry = JSON.parse(fs.readFileSync(path.join(dir, "PointsRegistry.json"), "utf8"))

  const consumerAbi = [
    "function topIdsAt(uint256) view returns (uint16)",
    "function topCount() view returns (uint16)",
  ]
  const registryAbi = [
    "function length() view returns (uint256)",
    "function getById(uint16) view returns (address)",
  ]
  const pointsAbi = ["function getPoints() view returns (uint256)"]

  const c = await ethers.getContractAt(consumerAbi as any, consumer.address)
  const r = await ethers.getContractAt(registryAbi as any, registry.address)

  const total: number = (await r.length()).toNumber ? (await r.length()).toNumber() : Number(await r.length())
  const cnt: number = await c.topCount()
  const show = Math.min(128, 10)

  console.log("Registry total:", total)
  console.log("Top count (upper bound):", cnt)
  if (total === 0 || show === 0) {
    console.log("Nothing to show")
    return
  }

  const ids: number[] = []
  for (let i = 0; i < show; i++) {
    const id: number = await (c as any).topIdsAt(i)
    if (id === 0xffff) break // sentinel means no more ids
    ids.push(id)
  }
  console.log("First IDs:", ids.join(", "))

  for (let i = 0; i < show; i++) {
    const id = ids[i]
    if (id >= total) {
      console.log(`${i}: id=${id} out of range (total=${total})`)
      continue
    }
    try {
      const addr = await r.getById(id)
      const pts = await (await ethers.getContractAt(pointsAbi as any, addr)).getPoints()
      console.log(`${i}: id=${id} addr=${addr} points=${pts.toString()}`)
    } catch (e) {
      console.log(`${i}: id=${id} getById/points failed`)
    }
  }
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})



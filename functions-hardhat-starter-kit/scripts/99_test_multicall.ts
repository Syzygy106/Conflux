import { ethers } from "hardhat"
import fs from "fs"
import path from "path"

async function main() {
  const dir = path.join(__dirname, "../deploy-artifacts")
  const mc = JSON.parse(fs.readFileSync(path.join(dir, "GasCappedMulticall.json"), "utf8")).address
  const reg = JSON.parse(fs.readFileSync(path.join(dir, "PointsRegistry.json"), "utf8")).address

  const regAbi = ["function getAll() view returns (address[])"]
  const pointsAbi = ["function getPoints() view returns (uint256)"]

  const regC = await ethers.getContractAt(regAbi, reg)
  const addrs: string[] = await regC.getAll()
  console.log("addresses:", addrs.length)

  const mcAbi = [
    "function aggregateGasLimited((address target, bytes callData)[] calls, uint64 perCallGas, bool allowFailure) view returns (uint256, (bool success, bytes returnData)[])",
  ]
  const mcC = await ethers.getContractAt(mcAbi, mc)

  const pointsIface = new ethers.utils.Interface(pointsAbi as any)
  const calls = addrs.map((a) => ({ target: a, callData: pointsIface.encodeFunctionData("getPoints", []) }))
  const perCallGas = 200000
  const [, results] = await mcC.aggregateGasLimited(calls, perCallGas, true)
  console.log("results len:", results.length)
  const pts = results.map((r: any) => (r.success ? ethers.BigNumber.from(r.returnData).toString() : "0"))
  console.log("first few:", pts.slice(0, 5))
}

main().catch((e) => { console.error(e); process.exit(1) })



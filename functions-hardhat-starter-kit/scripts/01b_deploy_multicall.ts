import { ethers } from "hardhat"
import fs from "fs"
import path from "path"

async function main() {
  const F = await ethers.getContractFactory("GasCappedMulticall")
  const mc = await F.deploy()
  await mc.deployed()
  console.log("GasCappedMulticall:", mc.address)
  writeArtifact("GasCappedMulticall", { address: mc.address })
}

function writeArtifact(name: string, data: any) {
  const dir = path.join(__dirname, "../deploy-artifacts")
  if (!fs.existsSync(dir)) fs.mkdirSync(dir)
  fs.writeFileSync(path.join(dir, `${name}.json`), JSON.stringify(data, null, 2))
}

main().catch((e) => { console.error(e); process.exit(1) })



// eslint-disable-next-line @typescript-eslint/no-var-requires
const { ethers } = require("hardhat")

async function main() {
  const addr: string | undefined = process.env.TOP_ORACLE
  if (!addr) throw new Error("Set TOP_ORACLE env to the TopOracle address")

  const TopOracle = await ethers.getContractFactory("TopOracle")
  const o = await TopOracle.attach(addr)

  try {
    const est = await o.estimateGas.refreshTopNow()
    const tx = await o.refreshTopNow({ gasLimit: est.mul(2) })
    console.log("refreshTopNow sent:", tx.hash)
    const rc = await tx.wait()
    console.log("mined, status:", rc.status)
  } catch (e) {
    console.log("estimate failed, sending with fixed gasLimit=300000")
    const tx = await o.refreshTopNow({ gasLimit: 300000 })
    console.log("refreshTopNow sent:", tx.hash)
    const rc = await tx.wait()
    console.log("mined, status:", rc.status)
  }
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})



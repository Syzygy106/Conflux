// Runs inside Chainlink Functions (Deno runtime)
// Uses secrets from DON for production-like setup
// New Args: [registryAddress]

if (!args || args.length < 1) {
  throw Error("Expected args: [registryAddress]")
}

const REGISTRY = args[0]

const { ethers } = await import("npm:ethers@6.9.0")

// Use secrets from DON for RPC configuration (must be HTTPS on live DON)
const rpcUrl = secrets.rpcUrl
if (!rpcUrl || !rpcUrl.startsWith("http")) throw Error("Missing valid secrets.rpcUrl")

// Minimal interface and ABI coder
const regIface = new ethers.Interface([
  "function length() view returns (uint256)",
  "function aggregatePointsRange(uint256 start, uint256 count) view returns (uint128[])",
])

async function ethCall(to, data) {
  const body = {
    jsonrpc: "2.0",
    id: 1,
    method: "eth_call",
    params: [{ to, data }, "latest"],
  }
  const resp = await Functions.makeHttpRequest({
    url: rpcUrl,
    method: "POST",
    headers: { "content-type": "application/json" },
    data: body,
    timeout: 15000,
  })
  if (!resp || resp.error) throw Error(`RPC error: ${resp?.error || "unknown"}`)
  const result = resp.data && resp.data.result
  if (!result || typeof result !== "string" || !result.startsWith("0x")) throw Error("Bad eth_call result")
  return result
}

// 1) Fetch total
const lenData = regIface.encodeFunctionData("length")
const lenHex = await ethCall(REGISTRY, lenData)
const total = BigInt(lenHex)
if (total === 0n) {
  // Return 128 sentinels (0xFFFF) → words are all 1s (16×16-bit segments)
  const allOnes = (1n << 256n) - 1n
  const words = new Array(8).fill(allOnes)
  const encEmpty = new ethers.AbiCoder().encode(["uint256[8]"], [words])
  return (await import("npm:ethers@6.9.0")).ethers.getBytes(encEmpty)
}

// 2) Up to 4 range calls of 800
const BATCH = 800n
const maxBatches = 4n
const neededBatches = (total + BATCH - 1n) / BATCH
const batches = neededBatches > maxBatches ? maxBatches : neededBatches
const allPairs = [] // [id:number, points:bigint]
for (let b = 0n; b < batches; b++) {
  const start = b * BATCH
  const left = total > start ? total - start : 0n
  const take = left < BATCH ? left : BATCH
  if (take === 0n) break
  const dataAgg = regIface.encodeFunctionData("aggregatePointsRange", [start, take])
  const aggHex = await ethCall(REGISTRY, dataAgg)
  const arr = regIface.decodeFunctionResult("aggregatePointsRange", aggHex)[0]
  for (let i = 0n; i < take; i++) {
    const id = Number(start + i) // uint16 range
    const p = BigInt(arr[Number(i)].toString())
    if (p > 0n) allPairs.push([id, p])
  }
}

// 3) Sort by points desc, tie by lower id
allPairs.sort((a, b) => {
  if (a[1] > b[1]) return -1
  if (a[1] < b[1]) return 1
  return a[0] - b[0]
})

// 4) Take up to 128 ids and pack into uint256[8] (16 ids per word, 16 bits each)
let takeIds = allPairs.slice(0, 128).map((x) => x[0])
// Pad with sentinel 0xFFFF for empty slots to avoid ambiguous id=0
while (takeIds.length < 128) takeIds.push(0xffff)
const words = new Array(8).fill(0n)
for (let i = 0; i < takeIds.length; i++) {
  const wordIndex = Math.floor(i / 16)
  const slot = i % 16
  const shift = BigInt(slot * 16)
  words[wordIndex] |= (BigInt(takeIds[i]) & 0xffffn) << shift
}

const enc = new ethers.AbiCoder().encode(["uint256[8]"], [words])
return (await import("npm:ethers@6.9.0")).ethers.getBytes(enc)
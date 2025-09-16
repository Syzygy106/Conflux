const { expect } = require("chai")
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers")
const { ethers } = require("hardhat")

describe("V4 Architecture Integration Tests", function () {
  // We define a fixture to reuse the same setup in every test.
  async function deployV4Fixture() {
    const [owner, daemonOwner1, daemonOwner2] = await ethers.getSigners()

    // Deploy MockERC20 for rebate token
    const MockERC20 = await ethers.getContractFactory("MockERC20")
    const rebateToken = await MockERC20.deploy("Test Token", "TEST", ethers.utils.parseEther("1000000"))

    // Deploy DaemonRegistryModerated
    const DaemonRegistryModerated = await ethers.getContractFactory("DaemonRegistryModerated")
    const registry = await DaemonRegistryModerated.deploy()

  // Deploy LinearDaemon contracts
  const LinearDaemon = await ethers.getContractFactory("contracts/v4/examples/LinearDaemon.sol:LinearDaemon")
    const daemon1 = await LinearDaemon.deploy(1000, 5000, 100, 10, 0) // startPrice, endPrice, priceInterest, growPeriod, startBlock
    const daemon2 = await LinearDaemon.deploy(2000, 6000, 50, 20, 0)

    // Add daemons to registry
    await registry.addMany([daemon1.address, daemon2.address], [daemonOwner1.address, daemonOwner2.address])
    await registry.activateMany([daemon1.address, daemon2.address])

    // Deploy TopOracle (with mock router and DON ID)
    const mockRouter = ethers.constants.AddressZero
    const mockDonId = ethers.utils.formatBytes32String("test-don")
    const TopOracle = await ethers.getContractFactory("TopOracle")
    const topOracle = await TopOracle.deploy(mockRouter, mockDonId, registry.address, owner.address)

    // Deploy ConfluxHook (with mock PoolManager)
    const mockPoolManager = ethers.constants.AddressZero
    const ConfluxHook = await ethers.getContractFactory("ConfluxHookSimple")
    const confluxHook = await ConfluxHook.deploy(mockPoolManager, topOracle.address, registry.address, rebateToken.address)

    // Set hook authorities
    await topOracle.setHookAuthority(confluxHook.address)
    await registry.setHookAuthority(confluxHook.address)

    return {
      owner,
      daemonOwner1,
      daemonOwner2,
      rebateToken,
      registry,
      topOracle,
      confluxHook,
      daemon1,
      daemon2
    }
  }

  describe("DaemonRegistryModerated", function () {
    it("Should add daemons correctly", async function () {
      const { registry, daemon1, daemon2, daemonOwner1, daemonOwner2 } = await loadFixture(deployV4Fixture)

      expect(await registry.length()).to.equal(2)
      expect(await registry.getById(0)).to.equal(daemon1.address)
      expect(await registry.getById(1)).to.equal(daemon2.address)
      expect(await registry.addressToId(daemon1.address)).to.equal(0)
      expect(await registry.addressToId(daemon2.address)).to.equal(1)
    })

    it("Should activate daemons correctly", async function () {
      const { registry, daemon1, daemon2 } = await loadFixture(deployV4Fixture)

      expect(await registry.active(daemon1.address)).to.be.true
      expect(await registry.active(daemon2.address)).to.be.true
    })

    it("Should allow hook to moderate daemons", async function () {
      const { registry, confluxHook, daemon1 } = await loadFixture(deployV4Fixture)

      // Hook should be able to deactivate daemon (call directly, not through connect)
      await confluxHook.setActiveFromHook(daemon1.address, false)
      expect(await registry.active(daemon1.address)).to.be.false

      // Hook should be able to ban daemon (call directly, not through connect)
      await confluxHook.banFromHook(daemon1.address)
      expect(await registry.banned(daemon1.address)).to.be.true
    })
  })

  describe("LinearDaemon", function () {
    it("Should calculate rebate amounts correctly", async function () {
      const { daemon1 } = await loadFixture(deployV4Fixture)

      // At block 0, should return startPrice
      expect(await daemon1.getRebateAmount(0)).to.equal(1000)

      // After 10 blocks (1 period), should increase by priceInterest
      expect(await daemon1.getRebateAmount(10)).to.equal(1100)

      // After 20 blocks (2 periods), should increase by 2 * priceInterest
      expect(await daemon1.getRebateAmount(20)).to.equal(1200)
    })

    it("Should execute jobs correctly", async function () {
      const { daemon1 } = await loadFixture(deployV4Fixture)

      expect(await daemon1.jobsExecuted()).to.equal(0)
      await daemon1.accomplishDaemonJob()
      expect(await daemon1.jobsExecuted()).to.equal(1)
    })
  })

  describe("TopOracle", function () {
    it("Should initialize correctly", async function () {
      const { topOracle, registry, confluxHook } = await loadFixture(deployV4Fixture)

      expect(await topOracle.registry()).to.equal(registry.address)
      expect(await topOracle.hookAuthority()).to.equal(confluxHook.address)
      expect(await topOracle.topCount()).to.equal(0)
      expect(await topOracle.topEpoch()).to.equal(0)
    })

    it("Should set epoch duration correctly", async function () {
      const { topOracle } = await loadFixture(deployV4Fixture)

      await topOracle.setEpochDuration(100)
      expect(await topOracle.epochDurationBlocks()).to.equal(100)
    })

    it("Should only allow hook authority to call restricted functions", async function () {
      const { topOracle, confluxHook, owner } = await loadFixture(deployV4Fixture)

      // Only hook authority should be able to call maybeRequestTopUpdate
      // Call through the hook contract, not by connecting the hook as a signer
      await expect(confluxHook.maybeRequestTopUpdate()).to.not.be.reverted
      await expect(topOracle.connect(owner).maybeRequestTopUpdate()).to.be.revertedWith("only hook authority")
    })
  })

  describe("ConfluxHook", function () {
    it("Should initialize correctly", async function () {
      const { confluxHook, topOracle, registry, rebateToken } = await loadFixture(deployV4Fixture)

      expect(await confluxHook.topOracle()).to.equal(topOracle.address)
      expect(await confluxHook.registry()).to.equal(registry.address)
      expect(await confluxHook.rebateToken()).to.equal(rebateToken.address)
    })

    it("Should have correct hook permissions", async function () {
      const { confluxHook } = await loadFixture(deployV4Fixture)

      const permissions = await confluxHook.getHookPermissions()
      expect(permissions.beforeSwap).to.be.true
      expect(permissions.beforeSwapReturnDelta).to.be.true
      expect(permissions.afterInitialize).to.be.true
    })
  })

  describe("Integration", function () {
    it("Should work end-to-end with mock data", async function () {
      const { registry, topOracle, daemon1, daemon2 } = await loadFixture(deployV4Fixture)

      // Verify daemons are registered and active
      expect(await registry.length()).to.equal(2)
      expect(await registry.active(daemon1.address)).to.be.true
      expect(await registry.active(daemon2.address)).to.be.true

      // Verify daemons can calculate rebate amounts
      const rebate1 = await daemon1.getRebateAmount(0)
      const rebate2 = await daemon2.getRebateAmount(0)
      expect(rebate1).to.be.gt(0)
      expect(rebate2).to.be.gt(0)

      // Verify top oracle is ready for Functions integration
      expect(await topOracle.registry()).to.equal(registry.address)
      expect(await topOracle.hookAuthority()).to.not.equal(ethers.constants.AddressZero)
    })
  })
})

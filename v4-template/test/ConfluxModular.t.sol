// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {Deployers} from "./utils/Deployers.sol";

import {ConfluxModular} from "../src/ConfluxModular.sol";
import {DaemonManager} from "../src/DaemonManager.sol";
import {ChainlinkOracle} from "../src/ChainlinkOracle.sol";
import {IDaemon} from "../src/interfaces/IDaemon.sol";

contract MockDaemonForModular is IDaemon {
    int128 public rebateAmount;
    bool public shouldRevert;
    bool public jobCalled;
    
    function setRebateAmount(int128 amount) external {
        rebateAmount = amount;
    }
    
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }
    
    function getRebateAmount(uint256) external view returns (int128) {
        if (shouldRevert) revert("MockDaemon: getRebateAmount reverted");
        return rebateAmount;
    }
    
    function accomplishDaemonJob() external {
        jobCalled = true;
        if (shouldRevert) revert("MockDaemon: job failed");
    }
    
    function resetJobCalled() external {
        jobCalled = false;
    }
}

contract ConfluxModularTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;

    ConfluxModular hook;
    DaemonManager daemonManager;
    ChainlinkOracle chainlinkOracle;
    
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    MockDaemonForModular daemon1;
    MockERC20 rebateToken;

    function setUp() public {
        deployArtifacts();
        (currency0, currency1) = deployCurrencyPair();
        rebateToken = MockERC20(Currency.unwrap(currency0));

        // Deploy modular components
        daemonManager = new DaemonManager(address(this));
        chainlinkOracle = new ChainlinkOracle(
            address(0), // router (mock)
            bytes32("TEST_DON"),
            address(daemonManager),
            address(this)
        );

        // Deploy hook with correct flags
        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (uint160(0x4450) << 144)
        );

        bytes memory constructorArgs = abi.encode(
            poolManager, 
            address(daemonManager), 
            address(chainlinkOracle),
            address(rebateToken)
        );
        deployCodeTo("ConfluxModular.sol:ConfluxModular", constructorArgs, flags);
        hook = ConfluxModular(flags);

        console.log("=== MODULAR CONFLUX DEPLOYMENT ===");
        console.log("Hook address:", address(hook));
        console.log("Hook code size:", address(hook).code.length);
        console.log("DaemonManager address:", address(daemonManager));
        console.log("DaemonManager code size:", address(daemonManager).code.length);
        console.log("ChainlinkOracle address:", address(chainlinkOracle));
        console.log("ChainlinkOracle code size:", address(chainlinkOracle).code.length);

        // Create pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Setup liquidity
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 100e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        // Setup daemon
        daemon1 = new MockDaemonForModular();
        rebateToken.approve(address(poolManager), type(uint256).max);
    }

    function testModularDeploymentSizes() public {
        console.log("=== CONTRACT SIZE COMPARISON ===");
        
        uint256 hookSize = address(hook).code.length;
        uint256 daemonManagerSize = address(daemonManager).code.length;
        uint256 oracleSize = address(chainlinkOracle).code.length;
        uint256 totalSize = hookSize + daemonManagerSize + oracleSize;
        
        console.log("ConfluxModular hook:", hookSize, "bytes");
        console.log("DaemonManager:", daemonManagerSize, "bytes");
        console.log("ChainlinkOracle:", oracleSize, "bytes");
        console.log("Total modular size:", totalSize, "bytes");
        console.log("Hook size as % of 24KB limit:", (hookSize * 100) / 24576, "%");
        
        // Hook should be under 24KB limit
        assertTrue(hookSize < 24576, "Hook should be under 24KB limit");
        assertTrue(daemonManagerSize < 24576, "DaemonManager should be under 24KB limit");
        assertTrue(oracleSize < 24576, "ChainlinkOracle should be under 24KB limit");
    }

    function testBasicFunctionality() public {
        // Test initial state
        assertEq(hook.hookOwner(), address(this));
        assertTrue(hook.getRebateState(poolKey));
        assertEq(daemonManager.getTotalDaemons(), 0);
        assertEq(chainlinkOracle.getTopCount(), 0);

        // Add daemon
        daemonManager.addDaemon(address(daemon1), address(this));
        assertEq(daemonManager.getTotalDaemons(), 1);
        assertTrue(daemonManager.exists(address(daemon1)));
        assertFalse(daemonManager.active(address(daemon1)));

        // Activate daemon
        daemonManager.activateDaemon(address(daemon1));
        assertTrue(daemonManager.active(address(daemon1)));
    }

    function testSwapWithoutEpochs() public {
        // Add and activate daemon
        daemonManager.addDaemon(address(daemon1), address(this));
        daemonManager.activateDaemon(address(daemon1));
        daemon1.setRebateAmount(int128(1e18));

        uint256 balanceBefore = rebateToken.balanceOf(address(this));

        // Perform swap (should not rebate because epochs are not started)
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 balanceAfter = rebateToken.balanceOf(address(this));
        
        // Swap should consume 1e18 tokens but no rebate should occur
        assertEq(balanceAfter, balanceBefore - 1e18);
        assertFalse(daemon1.jobCalled());
        assertEq(hook.beforeSwapCount(poolId), 0); // beforeSwapCount is NOT incremented in Conflux
        assertEq(hook.afterSwapCount(poolId), 1);
    }

    function testModularInteraction() public {
        // Test that all components work together
        daemonManager.addDaemon(address(daemon1), address(this));
        daemonManager.activateDaemon(address(daemon1));
        
        // Check cross-contract calls work
        assertEq(daemonManager.getDaemonId(address(daemon1)), 0);
        assertEq(daemonManager.getDaemonById(0), address(daemon1));
        
        // Test oracle functions
        assertEq(chainlinkOracle.getEpochDurationBlocks(), 0);
        assertEq(chainlinkOracle.getTopCount(), 0);
        
        console.log("All modular interactions working correctly");
    }

    function testGasEfficiency() public {
        // Test that modular design doesn't significantly impact gas
        uint256 gasBefore = gasleft();
        
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Gas used for modular swap:", gasUsed);
        
        // Should be reasonable
        assertLt(gasUsed, 500_000);
    }
}

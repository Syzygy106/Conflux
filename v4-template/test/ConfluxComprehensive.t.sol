// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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

import {TestConflux} from "../src/TestConflux.sol";
import {IDaemon} from "../src/interfaces/IDaemon.sol";

contract MockDaemon is IDaemon {
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

contract ConfluxComprehensiveTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;

    TestConflux hook;
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    MockDaemon daemon1;
    MockDaemon daemon2;
    MockERC20 rebateToken;
    
    address hookOwner = address(0x1234);
    address daemonOwner1 = address(0x5678);
    address daemonOwner2 = address(0x9ABC);

    function setUp() public {
        deployArtifacts();
        (currency0, currency1) = deployCurrencyPair();
        rebateToken = MockERC20(Currency.unwrap(currency0));

        // Deploy hook with correct flags
        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4446 << 144) // Different salt from simple test
        );

        bytes32 donId = bytes32("TEST_DON");
        bytes memory constructorArgs = abi.encode(poolManager, address(0), donId, address(rebateToken));
        deployCodeTo("TestConflux.sol:TestConflux", constructorArgs, flags);
        hook = TestConflux(flags);
        
        console.log("Hook deployed at:", address(hook));
        console.log("Hook code size:", address(hook).code.length);

        // Transfer hook ownership
        hook.transferHookOwnership(hookOwner);

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

        // Setup daemons
        daemon1 = new MockDaemon();
        daemon2 = new MockDaemon();
        
        console.log("Daemon1 deployed at:", address(daemon1));
        console.log("Daemon2 deployed at:", address(daemon2));
        
        rebateToken.approve(address(poolManager), type(uint256).max);
    }

    function testInitialState() public {
        assertEq(hook.hookOwner(), hookOwner);
        assertEq(hook.rebateToken(), address(rebateToken));
        assertTrue(hook.getRebateState(poolKey));
        assertEq(hook.length(), 0);
        assertEq(hook.topCount(), 0);
    }

    function testHookCounters() public {
        // Initial state after setup (liquidity was added)
        assertEq(hook.beforeAddLiquidityCount(poolId), 1);
        assertEq(hook.beforeRemoveLiquidityCount(poolId), 0);
        assertEq(hook.beforeSwapCount(poolId), 0);
        assertEq(hook.afterSwapCount(poolId), 0);

        // Perform swap
        uint256 amountIn = 1e18;
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Check counters updated
        assertEq(hook.beforeSwapCount(poolId), 1);
        assertEq(hook.afterSwapCount(poolId), 1);

        // Test liquidity removal
        uint256 liquidityToRemove = 1e18;
        positionManager.decreaseLiquidity(
            tokenId,
            liquidityToRemove,
            0,
            0,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        assertEq(hook.beforeRemoveLiquidityCount(poolId), 1);
    }

    function testDaemonManagement() public {
        // Test adding daemons
        address[] memory daemons = new address[](2);
        address[] memory owners = new address[](2);
        daemons[0] = address(daemon1);
        daemons[1] = address(daemon2);
        owners[0] = daemonOwner1;
        owners[1] = daemonOwner2;

        vm.prank(hookOwner);
        hook.addMany(daemons, owners);

        assertEq(hook.length(), 2);
        assertEq(hook.getAt(0), address(daemon1));
        assertEq(hook.getAt(1), address(daemon2));
        assertEq(hook.addressToId(address(daemon1)), 0);
        assertEq(hook.addressToId(address(daemon2)), 1);
        assertTrue(hook.exists(address(daemon1)));
        assertTrue(hook.exists(address(daemon2)));
        assertEq(hook.daemonOwner(address(daemon1)), daemonOwner1);
        assertEq(hook.daemonOwner(address(daemon2)), daemonOwner2);
    }

    function testDaemonActivation() public {
        // Add daemons first
        address[] memory daemons = new address[](2);
        address[] memory owners = new address[](2);
        daemons[0] = address(daemon1);
        daemons[1] = address(daemon2);
        owners[0] = daemonOwner1;
        owners[1] = daemonOwner2;

        vm.prank(hookOwner);
        hook.addMany(daemons, owners);

        // Test activation by hook owner
        vm.prank(hookOwner);
        hook.activateMany(daemons);

        assertTrue(hook.active(address(daemon1)));
        assertTrue(hook.active(address(daemon2)));

        // Test deactivation by hook owner
        vm.prank(hookOwner);
        hook.deactivateMany(daemons);

        assertFalse(hook.active(address(daemon1)));
        assertFalse(hook.active(address(daemon2)));

        // Test individual activation by daemon owner
        vm.prank(daemonOwner1);
        hook.setActive(address(daemon1), true);

        assertTrue(hook.active(address(daemon1)));
        assertFalse(hook.active(address(daemon2)));
    }

    function testRebateWithPositiveDaemon() public {
        // Setup daemons
        address[] memory daemons = new address[](1);
        address[] memory owners = new address[](1);
        daemons[0] = address(daemon1);
        owners[0] = daemonOwner1;

        vm.prank(hookOwner);
        hook.addMany(daemons, owners);

        vm.prank(hookOwner);
        hook.activateMany(daemons);

        // Configure epoch and top list
        hook.__setEpochDuration(100);
        hook.__setTopSimple(0, 1); // daemon1 is id 0

        // Setup daemon with positive rebate
        daemon1.setRebateAmount(int128(5e17)); // 0.5 tokens
        rebateToken.mint(address(daemon1), 10e18);
        vm.prank(address(daemon1));
        rebateToken.approve(address(poolManager), type(uint256).max);

        uint256 balanceBefore = rebateToken.balanceOf(address(this));

        // Perform swap
        uint256 amountIn = 1e18;
        BalanceDelta delta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 balanceAfter = rebateToken.balanceOf(address(this));
        
        // Check rebate was received
        assertGt(balanceAfter, balanceBefore);
        assertTrue(daemon1.jobCalled());
        
        console.log("Rebate received:", balanceAfter - balanceBefore);
    }

    function testRebateWithZeroDaemon() public {
        // Setup daemon with zero rebate
        address[] memory daemons = new address[](1);
        address[] memory owners = new address[](1);
        daemons[0] = address(daemon1);
        owners[0] = daemonOwner1;

        vm.prank(hookOwner);
        hook.addMany(daemons, owners);

        vm.prank(hookOwner);
        hook.activateMany(daemons);

        hook.__setEpochDuration(100);
        hook.__setTopSimple(0, 1);

        daemon1.setRebateAmount(0); // Zero rebate

        uint256 balanceBefore = rebateToken.balanceOf(address(this));

        // Perform swap
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
        
        // No rebate should be received
        assertEq(balanceAfter, balanceBefore);
        assertFalse(daemon1.jobCalled());
    }

    function testRebateWithFailingDaemon() public {
        // Setup daemon that will fail getRebateAmount
        address[] memory daemons = new address[](1);
        address[] memory owners = new address[](1);
        daemons[0] = address(daemon1);
        owners[0] = daemonOwner1;

        vm.prank(hookOwner);
        hook.addMany(daemons, owners);

        vm.prank(hookOwner);
        hook.activateMany(daemons);

        hook.__setEpochDuration(100);
        hook.__setTopSimple(0, 1);

        daemon1.setShouldRevert(true);

        assertTrue(hook.active(address(daemon1)));

        // Perform swap
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Daemon should be deactivated after failure
        assertFalse(hook.active(address(daemon1)));
    }

    function testPoolRebateToggle() public {
        assertTrue(hook.getRebateState(poolKey));

        // Toggle rebate off
        hook.toggleRebate(poolKey);
        assertFalse(hook.getRebateState(poolKey));

        // Toggle rebate on
        hook.toggleRebate(poolKey);
        assertTrue(hook.getRebateState(poolKey));
    }

    function testBanDaemon() public {
        // Add and activate daemon
        address[] memory daemons = new address[](1);
        address[] memory owners = new address[](1);
        daemons[0] = address(daemon1);
        owners[0] = daemonOwner1;

        vm.prank(hookOwner);
        hook.addMany(daemons, owners);

        vm.prank(hookOwner);
        hook.activateMany(daemons);

        assertTrue(hook.active(address(daemon1)));
        assertFalse(hook.banned(address(daemon1)));

        // Ban daemon
        vm.prank(hookOwner);
        hook.banDaemon(address(daemon1));

        assertFalse(hook.active(address(daemon1)));
        assertTrue(hook.banned(address(daemon1)));

        // Try to reactivate banned daemon - should fail
        vm.prank(daemonOwner1);
        vm.expectRevert();
        hook.setActive(address(daemon1), true);
    }

    function testEpochManagement() public {
        assertEq(hook.epochDurationBlocks(), 0);

        vm.prank(hookOwner);
        hook.setEpochLength(200);

        assertEq(hook.epochDurationBlocks(), 200);
    }

    function testAggregatePoints() public {
        // Add daemons
        address[] memory daemons = new address[](2);
        address[] memory owners = new address[](2);
        daemons[0] = address(daemon1);
        daemons[1] = address(daemon2);
        owners[0] = daemonOwner1;
        owners[1] = daemonOwner2;

        vm.prank(hookOwner);
        hook.addMany(daemons, owners);

        vm.prank(hookOwner);
        hook.activateMany(daemons);

        // Set different rebate amounts
        daemon1.setRebateAmount(int128(1e18));
        daemon2.setRebateAmount(int128(2e18));

        // Test aggregatePointsAll
        int128[] memory points = hook.aggregatePointsAll(block.number);
        assertEq(points.length, 2);
        assertEq(points[0], int128(1e18));
        assertEq(points[1], int128(2e18));

        // Test aggregatePointsMasked
        int128[] memory maskedPoints = hook.aggregatePointsMasked(block.number);
        assertEq(maskedPoints.length, 2);
        assertEq(maskedPoints[0], int128(1e18));
        assertEq(maskedPoints[1], int128(2e18));

        // Deactivate one daemon and test masked again
        vm.prank(daemonOwner1);
        hook.setActive(address(daemon1), false);

        maskedPoints = hook.aggregatePointsMasked(block.number);
        assertEq(maskedPoints[0], 0); // Inactive daemon should return 0
        assertEq(maskedPoints[1], int128(2e18));
    }

    function testNoRebateWhenEpochDisabled() public {
        // Setup daemon but don't set epoch duration
        address[] memory daemons = new address[](1);
        address[] memory owners = new address[](1);
        daemons[0] = address(daemon1);
        owners[0] = daemonOwner1;

        vm.prank(hookOwner);
        hook.addMany(daemons, owners);

        vm.prank(hookOwner);
        hook.activateMany(daemons);

        daemon1.setRebateAmount(int128(1e18));
        rebateToken.mint(address(daemon1), 10e18);
        vm.prank(address(daemon1));
        rebateToken.approve(address(poolManager), type(uint256).max);

        uint256 balanceBefore = rebateToken.balanceOf(address(this));

        // Perform swap
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
        
        // No rebate should be received when epochs are disabled
        assertEq(balanceAfter, balanceBefore);
        assertFalse(daemon1.jobCalled());
    }

    function testRebateOnlyWithCorrectToken() public {
        // Create pool with different tokens (not including rebateToken)
        (Currency otherCurrency0, Currency otherCurrency1) = deployCurrencyPair();
        
        PoolKey memory otherPoolKey = PoolKey(otherCurrency0, otherCurrency1, 3000, 60, IHooks(hook));
        poolManager.initialize(otherPoolKey, Constants.SQRT_PRICE_1_1);

        // Add liquidity to other pool
        uint128 liquidityAmount = 100e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            otherPoolKey,
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
        address[] memory daemons = new address[](1);
        address[] memory owners = new address[](1);
        daemons[0] = address(daemon1);
        owners[0] = daemonOwner1;

        vm.prank(hookOwner);
        hook.addMany(daemons, owners);

        vm.prank(hookOwner);
        hook.activateMany(daemons);

        hook.__setEpochDuration(100);
        hook.__setTopSimple(0, 1);

        daemon1.setRebateAmount(int128(1e18));

        uint256 balanceBefore = rebateToken.balanceOf(address(this));

        // Perform swap on pool without rebateToken
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: otherPoolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 balanceAfter = rebateToken.balanceOf(address(this));
        
        // No rebate should be received on pool without rebateToken
        assertEq(balanceAfter, balanceBefore);
        assertFalse(daemon1.jobCalled());
    }

    function testGasUsage() public {
        // Setup for gas measurement
        address[] memory daemons = new address[](1);
        address[] memory owners = new address[](1);
        daemons[0] = address(daemon1);
        owners[0] = daemonOwner1;

        vm.prank(hookOwner);
        hook.addMany(daemons, owners);

        vm.prank(hookOwner);
        hook.activateMany(daemons);

        hook.__setEpochDuration(100);
        hook.__setTopSimple(0, 1);

        daemon1.setRebateAmount(int128(1e18));
        rebateToken.mint(address(daemon1), 10e18);
        vm.prank(address(daemon1));
        rebateToken.approve(address(poolManager), type(uint256).max);

        uint256 gasBefore = gasleft();
        
        // Perform swap and measure gas
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 gasAfter = gasleft();
        uint256 gasUsed = gasBefore - gasAfter;
        
        console.log("Gas used for swap with rebate:", gasUsed);
        
        // Gas should be reasonable (less than 1M gas)
        assertLt(gasUsed, 1_000_000);
    }
}

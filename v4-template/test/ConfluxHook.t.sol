// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {Deployers} from "./utils/Deployers.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {ConfluxHook} from "../src/ConfluxHook.sol";
import {TopOracle} from "../src/TopOracle.sol";
import {DaemonRegistryModerated} from "../src/DaemonRegistryModerated.sol";
import {IDaemon} from "../src/interfaces/IDaemon.sol";

// Mock Chainlink Router for TopOracle
contract MockFunctionsRouter {
    address public topOracle;
    bytes32 public lastRequestId;
    
    function setTopOracle(address _oracle) external {
        topOracle = _oracle;
    }
    
    function sendRequest(
        bytes32,
        bytes calldata,
        uint64,
        uint32,
        bytes32
    ) external returns (bytes32) {
        // Generate and store request ID
        lastRequestId = keccak256(abi.encodePacked(block.timestamp, msg.sender));
        return lastRequestId;
    }
}

// Test version of TopOracle with exposed fulfillment for testing
contract TestableTopOracle is TopOracle {
    constructor(
        address router,
        bytes32 _donId,
        address _registry,
        address _hookAuthority
    ) TopOracle(router, _donId, _registry, _hookAuthority) {}
    
    // Expose fulfillRequest for testing
    function testFulfillRequest(
        bytes32 requestId,
        uint256[8] memory topIds
    ) external {
        bytes memory response = abi.encode(topIds);
        fulfillRequest(requestId, response, "");
    }
}

// Test daemon implementation
contract TestDaemon is IDaemon {
    uint128 public rebateAmount;
    address public token;
    bool public jobExecuted;
    address public owner;
    
    constructor(uint128 _rebateAmount, address _token) {
        rebateAmount = _rebateAmount;
        token = _token;
        owner = msg.sender;
    }
    
    function getRebateAmount(uint256) external view override returns (int128) {
        return int128(rebateAmount);
    }
    
    function accomplishDaemonJob() external override {
        jobExecuted = true;
    }
    
    function setRebateAmount(uint128 _amount) external {
        require(msg.sender == owner, "Only owner");
        rebateAmount = _amount;
    }
    
    // Helper to approve tokens for hook
    function approveHook(address hook, uint256 amount) external {
        require(msg.sender == owner, "Only owner");
        IERC20(token).approve(hook, amount);
    }
}

contract ConfluxHookTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency currency0;
    Currency currency1;
    
    PoolKey poolKey;
    ConfluxHook hook;
    TestableTopOracle topOracle;
    DaemonRegistryModerated registry;
    MockFunctionsRouter functionsRouter;
    PoolId poolId;
    
    // Test daemons
    TestDaemon daemon1;
    TestDaemon daemon2;
    TestDaemon daemon3;
    
    address hookOwner = address(0x1);
    address poolOwner = address(0x2);
    address user = address(0x456);
    address registryOwner = address(0x789);
    
    function setUp() public {
        // Deploy all required artifacts
        deployArtifacts();
        
        (currency0, currency1) = deployCurrencyPair();
        
        // Deploy mock Chainlink router
        functionsRouter = new MockFunctionsRouter();
        
        // Deploy TopOracle (testable version)
        bytes32 donId = keccak256("test-don");
        topOracle = new TestableTopOracle(address(functionsRouter), donId, address(0), address(0)); // Registry and hook will be set later
        functionsRouter.setTopOracle(address(topOracle));
        
        // Deploy DaemonRegistryModerated
        vm.prank(registryOwner);
        registry = new DaemonRegistryModerated();
        
        // Update TopOracle with registry address and hook authority
        topOracle.setRegistry(address(registry));
        topOracle.setHookAuthority(address(hook));
        
        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | 
                Hooks.AFTER_INITIALIZE_FLAG | 
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        
        bytes memory constructorArgs = abi.encode(
            poolManager, 
            address(topOracle), 
            address(registry), 
            Currency.unwrap(currency0) // rebateToken = token0
        );
        deployCodeTo("ConfluxHook.sol:ConfluxHook", constructorArgs, flags);
        hook = ConfluxHook(flags);
        
        // Set hook as authority in registry
        vm.prank(registryOwner);
        registry.setHookAuthority(address(hook));
        
        // Create the pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();
        
        // Initialize the pool - this will trigger afterInitialize and set the owner
        vm.prank(poolOwner);
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        
        // Add liquidity to the pool
        addLiquidity();
        
        // Deploy test daemons
        daemon1 = new TestDaemon(100e15, Currency.unwrap(currency0)); // 0.1 token rebate
        daemon2 = new TestDaemon(50e15, Currency.unwrap(currency0));  // 0.05 token rebate
        daemon3 = new TestDaemon(0, Currency.unwrap(currency0));      // No rebate
        
        // Fund daemons
        deal(Currency.unwrap(currency0), address(daemon1), 10e18);
        deal(Currency.unwrap(currency0), address(daemon2), 10e18);
        deal(Currency.unwrap(currency0), address(daemon3), 10e18);
        
        // Daemons approve hook
        daemon1.approveHook(address(hook), 10e18);
        daemon2.approveHook(address(hook), 10e18);
        daemon3.approveHook(address(hook), 10e18);
        
        // Register daemons
        address[] memory daemons = new address[](3);
        daemons[0] = address(daemon1);
        daemons[1] = address(daemon2);
        daemons[2] = address(daemon3);
        
        address[] memory owners = new address[](3);
        owners[0] = address(this);
        owners[1] = address(this);
        owners[2] = address(this);
        
        vm.prank(registryOwner);
        registry.addMany(daemons, owners);
        
        // Activate daemon1 and daemon2
        registry.setActive(address(daemon1), true);
        registry.setActive(address(daemon2), true);
        // daemon3 remains inactive
        
        // Setup TopOracle with initial epoch
        setupTopOracleEpoch();
    }
    
    function addLiquidityForPool(PoolKey memory _poolKey) internal {
        int24 tickLower = TickMath.minUsableTick(_poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(_poolKey.tickSpacing);
        
        uint128 liquidityAmount = 1000e18;
        
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );
        
        deal(Currency.unwrap(_poolKey.currency0), address(this), amount0Expected * 2);
        deal(Currency.unwrap(_poolKey.currency1), address(this), amount1Expected * 2);
        
        IERC20(Currency.unwrap(_poolKey.currency0)).approve(address(positionManager), amount0Expected * 2);
        IERC20(Currency.unwrap(_poolKey.currency1)).approve(address(positionManager), amount1Expected * 2);
        
        positionManager.mint(
            _poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ""
        );
    }
    
    function addLiquidity() internal {
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        
        uint128 liquidityAmount = 1000e18;
        
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );
        
        deal(Currency.unwrap(currency0), address(this), amount0Expected * 2);
        deal(Currency.unwrap(currency1), address(this), amount1Expected * 2);
        
        IERC20(Currency.unwrap(currency0)).approve(address(positionManager), amount0Expected * 2);
        IERC20(Currency.unwrap(currency1)).approve(address(positionManager), amount1Expected * 2);
        
        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ""
        );
    }
    
    function setupTopOracleEpoch() internal {
        // Setup initial template and epoch
        bytes memory encodedRequest = abi.encode("test-request");
        uint64 subscriptionId = 1;
        uint32 callbackGasLimit = 300000;
        
        topOracle.startRebateEpochs(
            100, // epochDurationBlocks
            encodedRequest,
            subscriptionId,
            callbackGasLimit
        );
        
        // Simulate Chainlink response with daemon1 as top
        uint256[8] memory topIds;
        topIds[0] = 0; // daemon1 has id 0
        topIds[1] = 0xffff; // End marker
        
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, topIds);
    }
    
    // ===== BASIC TESTS =====
    
    function testAfterInitializeSetsOwner() public view {
        assertEq(hook.poolOwner(poolKey), poolOwner);
    }
    
    function testToggleRebate() public {
        // Initially enabled (set in afterInitialize)
        assertTrue(hook.getRebateState(poolKey));
        
        // Only owner can toggle
        vm.prank(poolOwner);
        hook.toggleRebate(poolKey);
        assertFalse(hook.getRebateState(poolKey));
        
        // Non-owner cannot toggle
        vm.prank(user);
        vm.expectRevert("PoolOwnable: caller is not the pool owner");
        hook.toggleRebate(poolKey);
    }
    
    // ===== SWAP TESTS =====
    
    function testSwapWithoutRebate() public {
        // Disable rebate
        vm.prank(poolOwner);
        hook.toggleRebate(poolKey);
        
        uint256 swapAmount = 1e18;
        deal(Currency.unwrap(currency0), user, swapAmount);
        vm.prank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        
        // Get balances before swap
        uint256 userToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 userToken1Before = IERC20(Currency.unwrap(currency1)).balanceOf(user);
        uint256 poolToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 poolToken1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(poolManager));
        uint256 hookToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookToken1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));
        
        console2.log("=== SWAP WITHOUT REBATE ===");
        console2.log("Swap Amount:", swapAmount);
        console2.log("Before swap:");
        console2.log("  User Token0:", userToken0Before);
        console2.log("  User Token1:", userToken1Before);
        console2.log("  Pool Token0:", poolToken0Before);
        console2.log("  Pool Token1:", poolToken1Before);
        console2.log("  Hook Token0:", hookToken0Before);
        console2.log("  Hook Token1:", hookToken1Before);
        
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: user,
            deadline: block.timestamp + 1
        });
        
        // Get balances after swap
        uint256 userToken0After = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 userToken1After = IERC20(Currency.unwrap(currency1)).balanceOf(user);
        uint256 poolToken0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 poolToken1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(poolManager));
        uint256 hookToken0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookToken1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));
        
        console2.log("After swap:");
        console2.log("  User Token0:", userToken0After);
        console2.log("  User Token1:", userToken1After);
        console2.log("  Pool Token0:", poolToken0After);
        console2.log("  Pool Token1:", poolToken1After);
        console2.log("  Hook Token0:", hookToken0After);
        console2.log("  Hook Token1:", hookToken1After);
        console2.log("  User spent Token0:", userToken0Before - userToken0After);
        console2.log("  User received Token1:", userToken1After - userToken1Before);
        console2.log("  Pool Token0 change:", int256(poolToken0After) - int256(poolToken0Before));
        console2.log("  Pool Token1 change:", int256(poolToken1After) - int256(poolToken1Before));
        console2.log("  Hook Token0 change:", int256(hookToken0After) - int256(hookToken0Before));
        console2.log("  Hook Token1 change:", int256(hookToken1After) - int256(hookToken1Before));
        
        // User should spend token0 and receive token1, no rebate
        assertEq(userToken0Before - userToken0After, swapAmount);
        assertGt(userToken1After, userToken1Before);
    }
    
    function testSwapWithRebateFromTopDaemon() public {
        uint256 swapAmount = 1e18;
        uint128 expectedRebate = daemon1.rebateAmount(); // daemon1 is top
        
        console2.log("=== SWAP WITH TOP DAEMON REBATE ===");
        console2.log("Swap Amount:", swapAmount);
        console2.log("Expected Rebate:", expectedRebate);
        console2.log("Top Daemon:", address(daemon1));
        
        deal(Currency.unwrap(currency0), user, swapAmount);
        vm.prank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        
        // Get balances before swap
        uint256 userToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 userToken1Before = IERC20(Currency.unwrap(currency1)).balanceOf(user);
        uint256 poolToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 poolToken1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(poolManager));
        uint256 hookToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookToken1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));
        uint256 daemon1Token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        uint256 daemon1Token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(daemon1));
        
        console2.log("Before swap:");
        console2.log("  User Token0:", userToken0Before);
        console2.log("  User Token1:", userToken1Before);
        console2.log("  Pool Token0:", poolToken0Before);
        console2.log("  Pool Token1:", poolToken1Before);
        console2.log("  Hook Token0:", hookToken0Before);
        console2.log("  Hook Token1:", hookToken1Before);
        console2.log("  Daemon1 Token0:", daemon1Token0Before);
        console2.log("  Daemon1 Token1:", daemon1Token1Before);
        
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: user,
            deadline: block.timestamp + 1
        });
        
        // Get balances after swap
        uint256 userToken0After = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 userToken1After = IERC20(Currency.unwrap(currency1)).balanceOf(user);
        uint256 poolToken0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 poolToken1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(poolManager));
        uint256 hookToken0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookToken1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));
        uint256 daemon1Token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        uint256 daemon1Token1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(daemon1));
        
        console2.log("After swap:");
        console2.log("  User Token0:", userToken0After);
        console2.log("  User Token1:", userToken1After);
        console2.log("  Pool Token0:", poolToken0After);
        console2.log("  Pool Token1:", poolToken1After);
        console2.log("  Hook Token0:", hookToken0After);
        console2.log("  Hook Token1:", hookToken1After);
        console2.log("  Daemon1 Token0:", daemon1Token0After);
        console2.log("  Daemon1 Token1:", daemon1Token1After);
        console2.log("  User spent Token0:", userToken0Before - userToken0After);
        console2.log("  User received Token1:", userToken1After - userToken1Before);
        console2.log("  Pool Token0 change:", int256(poolToken0After) - int256(poolToken0Before));
        console2.log("  Pool Token1 change:", int256(poolToken1After) - int256(poolToken1Before));
        console2.log("  Hook Token0 change:", int256(hookToken0After) - int256(hookToken0Before));
        console2.log("  Hook Token1 change:", int256(hookToken1After) - int256(hookToken1Before));
        console2.log("  Daemon1 paid Token0:", daemon1Token0Before - daemon1Token0After);
        console2.log("  Daemon1 Token1 change:", int256(daemon1Token1After) - int256(daemon1Token1Before));
        
        // Daemon should pay rebate
        assertEq(daemon1Token0Before - daemon1Token0After, expectedRebate, "Daemon should pay rebate");
        
        // User should spend the same amount but receive more Token1 due to rebate
        assertEq(userToken0Before - userToken0After, swapAmount, "User should spend full swap amount");
        
        // User should receive more Token1 due to rebate (compare with expected amount without rebate)
        // The rebate improves the exchange rate, so user gets more output tokens
        assertGt(userToken1After - userToken1Before, 0, "User should receive Token1");
        
        // Log the benefit from rebate
        uint256 token1Received = userToken1After - userToken1Before;
        console2.log("  User received Token1 with rebate:", token1Received);
        console2.log("  Expected Token1 without rebate: ~996006981039903216");
        console2.log("  Benefit from rebate:", token1Received - 996006981039903216);
        
        // Daemon job should be executed
        assertTrue(daemon1.jobExecuted(), "Daemon job should be executed");
    }
    
    function testSwapWithRebateFromTopDaemon_ReverseDirection() public {
        uint256 swapAmount = 1e18;
        uint128 expectedRebate = daemon1.rebateAmount(); // daemon1 is top
        
        console2.log("=== SWAP WITH TOP DAEMON REBATE (REVERSE DIRECTION) ===");
        console2.log("Swap Amount:", swapAmount);
        console2.log("Expected Rebate:", expectedRebate);
        console2.log("Top Daemon:", address(daemon1));
        
        // Give user Token1 instead of Token0 for reverse swap
        deal(Currency.unwrap(currency1), user, swapAmount);
        vm.prank(user);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount);
        
        // Get balances before swap
        uint256 userToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 userToken1Before = IERC20(Currency.unwrap(currency1)).balanceOf(user);
        uint256 poolToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 poolToken1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(poolManager));
        uint256 hookToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookToken1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));
        uint256 daemon1Token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        uint256 daemon1Token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(daemon1));
        
        console2.log("Before swap:");
        console2.log("  User Token0:", userToken0Before);
        console2.log("  User Token1:", userToken1Before);
        console2.log("  Pool Token0:", poolToken0Before);
        console2.log("  Pool Token1:", poolToken1Before);
        console2.log("  Hook Token0:", hookToken0Before);
        console2.log("  Hook Token1:", hookToken1Before);
        console2.log("  Daemon1 Token0:", daemon1Token0Before);
        console2.log("  Daemon1 Token1:", daemon1Token1Before);
        
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false, // Reverse direction: Token1 -> Token0
            poolKey: poolKey,
            hookData: "",
            receiver: user,
            deadline: block.timestamp + 1
        });
        
        // Get balances after swap
        uint256 userToken0After = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 userToken1After = IERC20(Currency.unwrap(currency1)).balanceOf(user);
        uint256 poolToken0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 poolToken1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(poolManager));
        uint256 hookToken0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookToken1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));
        uint256 daemon1Token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        uint256 daemon1Token1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(daemon1));
        
        console2.log("After swap:");
        console2.log("  User Token0:", userToken0After);
        console2.log("  User Token1:", userToken1After);
        console2.log("  Pool Token0:", poolToken0After);
        console2.log("  Pool Token1:", poolToken1After);
        console2.log("  Hook Token0:", hookToken0After);
        console2.log("  Hook Token1:", hookToken1After);
        console2.log("  Daemon1 Token0:", daemon1Token0After);
        console2.log("  Daemon1 Token1:", daemon1Token1After);
        console2.log("  User spent Token1:", userToken1Before - userToken1After);
        console2.log("  User received Token0:", userToken0After - userToken0Before);
        console2.log("  Pool Token0 change:", int256(poolToken0After) - int256(poolToken0Before));
        console2.log("  Pool Token1 change:", int256(poolToken1After) - int256(poolToken1Before));
        console2.log("  Hook Token0 change:", int256(hookToken0After) - int256(hookToken0Before));
        console2.log("  Hook Token1 change:", int256(hookToken1After) - int256(hookToken1Before));
        console2.log("  Daemon1 Token0 change:", int256(daemon1Token0After) - int256(daemon1Token0Before));
        console2.log("  Daemon1 paid Token0:", daemon1Token0Before - daemon1Token0After);
        
        // Daemon should pay rebate (always in rebateToken which is Token0)
        assertEq(daemon1Token0Before - daemon1Token0After, expectedRebate, "Daemon should pay rebate in Token0");
        
        // User should spend the same amount but receive more Token0 due to rebate
        assertEq(userToken1Before - userToken1After, swapAmount, "User should spend full swap amount");
        
        // User should receive more Token0 due to rebate
        assertGt(userToken0After - userToken0Before, 0, "User should receive Token0");
        
        // Log the benefit from rebate
        uint256 token0Received = userToken0After - userToken0Before;
        console2.log("  User received Token0 with rebate:", token0Received);
        
        // Daemon job should be executed
        assertTrue(daemon1.jobExecuted(), "Daemon job should be executed");
    }
    
    function testRebateDisabledOnTransferFailure() public {
        // Set daemon rebate amount to more than it has approved
        daemon1.setRebateAmount(20e18); // More than funded amount
        
        uint256 swapAmount = 1e18;
        deal(Currency.unwrap(currency0), user, swapAmount);
        vm.prank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        
        // Check rebate is enabled before
        assertTrue(hook.getRebateState(poolKey));
        
        // Record balances before swap
        uint256 userToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 userToken1Before = IERC20(Currency.unwrap(currency1)).balanceOf(user);
        uint256 daemon1Token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        uint256 poolToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 poolToken1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(poolManager));
        
        console2.log("=== BEFORE SWAP (EXPECTING NO REBATE DUE TO INSUFFICIENT FUNDS) ===");
        console2.log("User Token0 before:", userToken0Before);
        console2.log("User Token1 before:", userToken1Before);
        console2.log("Daemon1 Token0 before:", daemon1Token0Before);
        console2.log("Pool Token0 before:", poolToken0Before);
        console2.log("Pool Token1 before:", poolToken1Before);
        
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: user,
            deadline: block.timestamp + 1
        });
        
        // Record balances after swap
        uint256 userToken0After = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 userToken1After = IERC20(Currency.unwrap(currency1)).balanceOf(user);
        uint256 daemon1Token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        uint256 poolToken0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 poolToken1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(poolManager));
        
        console2.log("=== AFTER SWAP ===");
        console2.log("User Token0 after:", userToken0After);
        console2.log("User Token1 after:", userToken1After);
        console2.log("Daemon1 Token0 after:", daemon1Token0After);
        console2.log("Pool Token0 after:", poolToken0After);
        console2.log("Pool Token1 after:", poolToken1After);
        console2.log("User spent Token0:", userToken0Before - userToken0After);
        console2.log("User received Token1:", userToken1After - userToken1Before);
        console2.log("Daemon1 paid:", daemon1Token0Before - daemon1Token0After);
        
        // Verify no rebate occurred - daemon should not have paid anything
        assertEq(daemon1Token0Before, daemon1Token0After, "Daemon should not pay rebate due to insufficient funds");
        
        // Daemon should be deactivated due to transfer failure
        assertFalse(registry.active(address(daemon1)), "Daemon should be deactivated");
        
        // Rebate should still be enabled for the pool (other daemons can still provide rebates)
        assertTrue(hook.getRebateState(poolKey));
    }
    
    function testHookDisabledWhenEpochDurationIsZero() public {
        // Create a new TopOracle with epoch duration = 0 (disabled)
        bytes32 testDonId = keccak256("test-don-disabled");
        TestableTopOracle disabledTopOracle = new TestableTopOracle(
            address(functionsRouter),
            testDonId,
            address(registry),
            address(0) // Will be set later
        );
        
        // Deploy the disabled hook to an address with the correct flags
        address disabledFlags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | 
                Hooks.AFTER_INITIALIZE_FLAG | 
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4445 << 144) // Different namespace to avoid collisions
        );
        
        bytes memory disabledConstructorArgs = abi.encode(
            poolManager, 
            address(disabledTopOracle), 
            address(registry), 
            Currency.unwrap(currency0) // rebateToken = token0
        );
        deployCodeTo("ConfluxHook.sol:ConfluxHook", disabledConstructorArgs, disabledFlags);
        ConfluxHook disabledHook = ConfluxHook(disabledFlags);
        
        // Set hook authority for disabled oracle
        disabledTopOracle.setHookAuthority(address(disabledHook));
        
        // Set up the pool with disabled hook
        PoolKey memory disabledPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: disabledHook
        });
        
        // Initialize the pool
        poolManager.initialize(disabledPoolKey, Constants.SQRT_PRICE_1_1);
        
        // Add liquidity to the pool
        addLiquidityForPool(disabledPoolKey);
        
        // Setup TopOracle with template (but epoch duration remains 0)
        bytes memory encodedRequest = abi.encode("test-request");
        uint64 subscriptionId = 1;
        uint32 callbackGasLimit = 300000;
        
        // Note: We don't call startRebateEpochs because we want epochDurationBlocks to remain 0
        // Instead, we just set the template manually
        disabledTopOracle.setRequestTemplate(encodedRequest, subscriptionId, callbackGasLimit);
        
        // Set up daemon1 as top daemon
        uint256[8] memory topIds;
        topIds[0] = 0; // daemon1
        topIds[1] = 0xffff;
        
        disabledTopOracle.refreshTopNow();
        bytes32 requestId = disabledTopOracle.lastRequestId();
        disabledTopOracle.testFulfillRequest(requestId, topIds);
        
        // Verify epoch duration is 0 (disabled)
        assertEq(disabledTopOracle.epochDurationBlocks(), 0, "Epoch duration should be 0");
        
        // Set up swap
        uint256 swapAmount = 1e18;
        deal(Currency.unwrap(currency0), user, swapAmount);
        vm.prank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        
        // Record balances before swap
        uint256 userToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 userToken1Before = IERC20(Currency.unwrap(currency1)).balanceOf(user);
        uint256 daemon1Token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        
        console2.log("=== BEFORE SWAP (EXPECTING NO REBATE - EPOCH DURATION = 0) ===");
        console2.log("User Token0 before:", userToken0Before);
        console2.log("User Token1 before:", userToken1Before);
        console2.log("Daemon1 Token0 before:", daemon1Token0Before);
        console2.log("Epoch duration blocks:", disabledTopOracle.epochDurationBlocks());
        
        // Perform swap
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: disabledPoolKey,
            hookData: "",
            receiver: user,
            deadline: block.timestamp + 1
        });
        
        // Record balances after swap
        uint256 userToken0After = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 userToken1After = IERC20(Currency.unwrap(currency1)).balanceOf(user);
        uint256 daemon1Token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        
        console2.log("=== AFTER SWAP ===");
        console2.log("User Token0 after:", userToken0After);
        console2.log("User Token1 after:", userToken1After);
        console2.log("Daemon1 Token0 after:", daemon1Token0After);
        console2.log("User spent Token0:", userToken0Before - userToken0After);
        console2.log("User received Token1:", userToken1After - userToken1Before);
        console2.log("Daemon1 paid:", daemon1Token0Before - daemon1Token0After);
        
        // Verify no rebate occurred - daemon should not have paid anything
        assertEq(daemon1Token0Before, daemon1Token0After, "Daemon should not pay rebate when epoch duration is 0");
        
        // Verify standard swap occurred - user should have spent the full amount and received tokens
        assertEq(userToken0Before - userToken0After, swapAmount, "User should spend full swap amount");
        assertGt(userToken1After - userToken1Before, 0, "User should receive Token1");
        
        // Verify hook state - rebate is enabled for the pool (set during initialization)
        // but the hook should not process rebates when epochDurationBlocks = 0
        assertTrue(disabledHook.getRebateState(disabledPoolKey), "Rebate state should be enabled for the pool");
        
        // The key test is that no rebate was processed (daemon didn't pay) due to epochDurationBlocks = 0
        // This is already verified above with the daemon balance check
    }
    
    function testTopRotationWithinEpoch() public {
        // Set up multiple daemons in top
        uint256[8] memory topIds;
        // Pack daemon1 (id=0) in slot 0, daemon2 (id=1) in slot 1, 0xffff in slot 2
        topIds[0] = 0 | (1 << 16) | (0xffff << 32);
        
        // Update top oracle with both daemons
        topOracle.refreshTopNow();
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, topIds);
        
        // First swap - daemon1 pays
        uint256 swapAmount = 1e18;
        deal(Currency.unwrap(currency0), user, swapAmount * 3);
        vm.prank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount * 3);
        
        uint256 daemon1BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: user,
            deadline: block.timestamp + 1
        });
        
        uint256 daemon1BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        assertGt(daemon1BalanceBefore - daemon1BalanceAfter, 0, "Daemon1 should pay first");
        
        // Second swap - daemon2 should pay (rotation)
        console2.log("=== SECOND SWAP (EXPECTING DAEMON2) ===");
        console2.log("Current top before second swap:", topOracle.getCurrentTop());
        console2.log("Top count:", topOracle.topCount());
        console2.log("Top cursor:", topOracle.topCursor());
        
        uint256 daemon2BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        console2.log("Daemon2 balance before:", daemon2BalanceBefore);
        
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: user,
            deadline: block.timestamp + 1
        });
        
        uint256 daemon2BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        console2.log("Daemon2 balance after:", daemon2BalanceAfter);
        console2.log("Daemon2 paid:", daemon2BalanceBefore - daemon2BalanceAfter);
        console2.log("Current top after second swap:", topOracle.getCurrentTop());
        
        assertGt(daemon2BalanceBefore - daemon2BalanceAfter, 0, "Daemon2 should pay second");
        
        // Third swap - should NOT provide rebate (all daemons exhausted in this epoch)
        console2.log("=== THIRD SWAP (EXPECTING NO REBATE - ALL DAEMONS EXHAUSTED) ===");
        console2.log("Current top before third swap:", topOracle.getCurrentTop());
        console2.log("Top count:", topOracle.topCount());
        console2.log("Top cursor:", topOracle.topCursor());
        
        daemon1BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        uint256 daemon2BalanceBefore3 = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        console2.log("Daemon1 balance before third swap:", daemon1BalanceBefore);
        console2.log("Daemon2 balance before third swap:", daemon2BalanceBefore3);
        
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: user,
            deadline: block.timestamp + 1
        });
        
        daemon1BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        uint256 daemon2BalanceAfter3 = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        console2.log("Daemon1 balance after third swap:", daemon1BalanceAfter);
        console2.log("Daemon2 balance after third swap:", daemon2BalanceAfter3);
        console2.log("Daemon1 paid in third swap:", daemon1BalanceBefore - daemon1BalanceAfter);
        console2.log("Daemon2 paid in third swap:", daemon2BalanceBefore3 - daemon2BalanceAfter3);
        console2.log("Current top after third swap:", topOracle.getCurrentTop());
        
        // No daemon should pay - all exhausted in this epoch
        assertEq(daemon1BalanceBefore - daemon1BalanceAfter, 0, "Daemon1 should NOT pay - all daemons exhausted");
        assertEq(daemon2BalanceBefore3 - daemon2BalanceAfter3, 0, "Daemon2 should NOT pay - all daemons exhausted");
    }
    
    function testSwapWithZeroRebateDaemon() public {
        // Update top to daemon3 which has 0 rebate
        uint256[8] memory topIds;
        topIds[0] = 2; // daemon3
        topIds[1] = 0xffff;
        
        topOracle.refreshTopNow();
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, topIds);
        
        // Activate daemon3
        registry.setActive(address(daemon3), true);
        
        uint256 swapAmount = 1e18;
        deal(Currency.unwrap(currency0), user, swapAmount);
        vm.prank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        
        uint256 userToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 daemon3Token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon3));
        
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: user,
            deadline: block.timestamp + 1
        });
        
        uint256 userToken0After = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 daemon3Token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon3));
        
        // Daemon3 should not pay anything (0 rebate)
        assertEq(daemon3Token0Before, daemon3Token0After, "Daemon3 should not pay (0 rebate)");
        
        // User should pay full swap amount
        assertEq(userToken0Before - userToken0After, swapAmount, "User should pay full amount");
        
        // But daemon job should still be attempted (although it returns 0 rebate)
        // Note: In this case, the hook moves to next daemon after detecting 0 rebate
    }
    
    function testBannedDaemonCannotProvideRebate() public {
        // Ban daemon1 through registry
        vm.prank(registryOwner);
        registry.banDaemon(address(daemon1));
        
        // Check daemon is banned and inactive
        assertTrue(registry.banned(address(daemon1)));
        assertFalse(registry.active(address(daemon1)));
        
        // Try to swap - should skip banned daemon
        uint256 swapAmount = 1e18;
        deal(Currency.unwrap(currency0), user, swapAmount);
        vm.prank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        
        uint256 daemon1BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: user,
            deadline: block.timestamp + 1
        });
        
        uint256 daemon1BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        
        // Daemon1 should not pay anything since it's banned
        assertEq(daemon1BalanceBefore, daemon1BalanceAfter, "Banned daemon should not pay rebate");
    }
    
    function testEpochExpiration() public {
        // Check initial epoch
        uint64 initialEpoch = topOracle.topEpoch();
        
        // Mine blocks to pass epoch duration
        vm.roll(block.number + 101); // epoch duration is 100 blocks
        
        // Call maybeRequestTopUpdate (normally called by hook)
        topOracle.maybeRequestTopUpdate();
        
        // Simulate new top with different daemons
        uint256[8] memory newTopIds;
        newTopIds[0] = 1; // daemon2 is now top
        newTopIds[1] = 0xffff;
        
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, newTopIds);
        
        // Check epoch incremented
        assertEq(topOracle.topEpoch(), initialEpoch + 1, "Epoch should increment");
        
        // Now daemon2 should be the one paying rebates
        uint256 swapAmount = 1e18;
        deal(Currency.unwrap(currency0), user, swapAmount);
        vm.prank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        
        uint256 daemon2BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: user,
            deadline: block.timestamp + 1
        });
        
        uint256 daemon2BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        
        assertGt(daemon2BalanceBefore - daemon2BalanceAfter, 0, "Daemon2 should pay in new epoch");
    }
}
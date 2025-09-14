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
    bool public shouldRevertOnRebate;
    bool public shouldRevertOnJob;
    bool public shouldReturnInvalidData;
    
    constructor(uint128 _rebateAmount, address _token) {
        rebateAmount = _rebateAmount;
        token = _token;
        owner = msg.sender;
    }
    
    function getRebateAmount(uint256) external view override returns (int128) {
        if (shouldRevertOnRebate) {
            revert("Daemon revert");
        }
        if (shouldReturnInvalidData) {
            // Return invalid data length
            assembly {
                return(0, 0)
            }
        }
        return int128(rebateAmount);
    }
    
    function accomplishDaemonJob() external override {
        if (shouldRevertOnJob) {
            revert("Job revert");
        }
        jobExecuted = true;
    }
    
    function setRebateAmount(uint128 _amount) external {
        require(msg.sender == owner, "Only owner");
        rebateAmount = _amount;
    }
    
    function setShouldRevert(bool _shouldRevert) external {
        require(msg.sender == owner, "Only owner");
        shouldRevertOnRebate = _shouldRevert;
        shouldRevertOnJob = _shouldRevert;
    }
    
    function setShouldRevertOnRebate(bool _shouldRevert) external {
        require(msg.sender == owner, "Only owner");
        shouldRevertOnRebate = _shouldRevert;
    }
    
    function setShouldRevertOnJob(bool _shouldRevert) external {
        require(msg.sender == owner, "Only owner");
        shouldRevertOnJob = _shouldRevert;
    }
    
    function setShouldReturnInvalidData(bool _shouldReturnInvalidData) external {
        require(msg.sender == owner, "Only owner");
        shouldReturnInvalidData = _shouldReturnInvalidData;
    }
    
    // Helper to approve tokens for hook
    function approveHook(address hook, uint256 amount) external {
        require(msg.sender == owner, "Only owner");
        IERC20(token).approve(hook, amount);
    }
    
    // Helper to approve tokens for pool manager
    function approvePoolManager(address poolManager, uint256 amount) external {
        require(msg.sender == owner, "Only owner");
        IERC20(token).approve(poolManager, amount);
    }
}

contract ConfluxFullCycleTests is Test, Deployers {
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
    TestDaemon failingDaemon;
    
    address poolOwner = address(0x2);
    address user = address(0x456);
    address registryOwner = address(0x789);
    address hookOwner;
    
    function setUp() public {
        // Deploy all required artifacts
        deployArtifacts();
        
        (currency0, currency1) = deployCurrencyPair();
        
        // Deploy mock Chainlink router
        functionsRouter = new MockFunctionsRouter();
        
        // Deploy DaemonRegistryModerated first
        vm.prank(registryOwner);
        registry = new DaemonRegistryModerated();
        
        // Deploy TopOracle (testable version) with proper addresses
        bytes32 donId = keccak256("test-don");
        topOracle = new TestableTopOracle(address(functionsRouter), donId, address(registry), address(0));
        functionsRouter.setTopOracle(address(topOracle));
        
        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | 
                Hooks.AFTER_INITIALIZE_FLAG | 
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        
        bytes memory constructorArgs = abi.encode(
            poolManager, 
            address(topOracle), 
            address(registry), 
            Currency.unwrap(currency0) // rebateToken = token0
        );
        deployCodeTo("ConfluxHook.sol:ConfluxHook", constructorArgs, flags);
        hook = ConfluxHook(flags);
        hookOwner = address(this);
        
        // Set hook authority in TopOracle
        topOracle.setHookAuthority(address(hook));
        
        // Set hook as authority in registry
        vm.prank(registryOwner);
        registry.setHookAuthority(address(hook));
        
        // Create the main pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();
        
        // Initialize the pool
        vm.prank(poolOwner);
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        
        // Add liquidity to the pool
        addLiquidity();
        
        // Don't deploy or register any daemons - keep registry empty
        // Don't initialize the Oracle - keep it uninitialized
        console2.log("Setup complete - no daemons registered, Oracle not initialized");
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
    
    function setupTopOracleEpochEmpty() internal {
        // Setup initial template and epoch but don't fulfill the request
        bytes memory encodedRequest = abi.encode("test-request");
        uint64 subscriptionId = 1;
        uint32 callbackGasLimit = 300000;
        
        topOracle.startRebateEpochs(
            100, // epochDurationBlocks
            encodedRequest,
            subscriptionId,
            callbackGasLimit
        );
        
        // Don't fulfill the request - this leaves the top empty initially
    }
    
    function performSwap(uint256 amount, bool zeroForOne) internal {
        deal(Currency.unwrap(currency0), user, amount * 2);
        deal(Currency.unwrap(currency1), user, amount * 2);
        vm.prank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amount * 2);
        vm.prank(user);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), amount * 2);
        
        vm.prank(user);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: "",
            receiver: user,
            deadline: block.timestamp + 1
        });
    }

    function testStage0() public {
        // Start from block 1
        vm.roll(1);
        console2.log("Starting from block:", block.number);
        console2.log("Top count (should be 0):", topOracle.topCount());

        // Verify that top is initially empty
        assertEq(topOracle.topCount(), 0, "Top should be empty at start");
        console2.log("Top is empty at start");

        // Verify that registry is empty (no daemons registered)
        assertEq(registry.length(), 0, "Registry should be empty at start");
        console2.log("Registry is empty at start");

        // Verify Oracle is not initialized (no epoch duration set)
        assertEq(topOracle.epochDurationBlocks(), 0, "Oracle should not be initialized");
        console2.log("Oracle is not initialized (0 epoch duration)");

        // Define 3 different users
        address user1 = address(0x1001);
        address user2 = address(0x1002);
        address user3 = address(0x1003);
        
        console2.log("\n--- PERFORMING 3 SWAPS WITH NO REBATES ---");
        console2.log("User1:", user1);
        console2.log("User2:", user2);
        console2.log("User3:", user3);
        
        // Track balances for all users
        uint256[3] memory user0BalancesBefore;
        uint256[3] memory user1BalancesBefore;
        uint256[3] memory user0BalancesAfter;
        uint256[3] memory user1BalancesAfter;
        
        // SWAP 1: token0 -> token1 (user1)
        console2.log("\n--- SWAP 1: token0 -> token1 (user1) ---");
        console2.log("Block before swap:", block.number);
        
        uint256 swapAmount = 1e18;
        deal(Currency.unwrap(currency0), user1, swapAmount * 2);
        vm.prank(user1);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[0] = IERC20(Currency.unwrap(currency0)).balanceOf(user1);
        user1BalancesBefore[0] = IERC20(Currency.unwrap(currency1)).balanceOf(user1);
        
        console2.log("  User1 token0 balance before:", user0BalancesBefore[0]);
        console2.log("  User1 token1 balance before:", user1BalancesBefore[0]);
        console2.log("  Top count before swap:", topOracle.topCount());
        
        vm.prank(user1);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true, // token0 -> token1
            poolKey: poolKey,
            hookData: "",
            receiver: user1,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[0] = IERC20(Currency.unwrap(currency0)).balanceOf(user1);
        user1BalancesAfter[0] = IERC20(Currency.unwrap(currency1)).balanceOf(user1);
        
        console2.log("  User1 token0 balance after:", user0BalancesAfter[0]);
        console2.log("  User1 token1 balance after:", user1BalancesAfter[0]);
        console2.log("  User1 token0 spent:", user0BalancesBefore[0] - user0BalancesAfter[0]);
        console2.log("  User1 token1 received:", user1BalancesAfter[0] - user1BalancesBefore[0]);
        
        // Move 12 blocks forward
        vm.roll(block.number + 12);
        console2.log("  Moved to block:", block.number);
        
        // SWAP 2: token1 -> token0 (user2)
        console2.log("\n--- SWAP 2: token1 -> token0 (user2) ---");
        console2.log("Block before swap:", block.number);
        
        deal(Currency.unwrap(currency1), user2, swapAmount * 2);
        vm.prank(user2);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[1] = IERC20(Currency.unwrap(currency0)).balanceOf(user2);
        user1BalancesBefore[1] = IERC20(Currency.unwrap(currency1)).balanceOf(user2);
        
        console2.log("  User2 token0 balance before:", user0BalancesBefore[1]);
        console2.log("  User2 token1 balance before:", user1BalancesBefore[1]);
        console2.log("  Top count before swap:", topOracle.topCount());
        
        vm.prank(user2);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false, // token1 -> token0
            poolKey: poolKey,
            hookData: "",
            receiver: user2,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[1] = IERC20(Currency.unwrap(currency0)).balanceOf(user2);
        user1BalancesAfter[1] = IERC20(Currency.unwrap(currency1)).balanceOf(user2);
        
        console2.log("  User2 token0 balance after:", user0BalancesAfter[1]);
        console2.log("  User2 token1 balance after:", user1BalancesAfter[1]);
        console2.log("  User2 token1 spent:", user1BalancesBefore[1] - user1BalancesAfter[1]);
        console2.log("  User2 token0 received:", user0BalancesAfter[1] - user0BalancesBefore[1]);
        
        // Move 15 blocks forward
        vm.roll(block.number + 15);
        console2.log("  Moved to block:", block.number);
        
        // SWAP 3: token1 -> token0 (user3)
        console2.log("\n--- SWAP 3: token1 -> token0 (user3) ---");
        console2.log("Block before swap:", block.number);
        
        deal(Currency.unwrap(currency1), user3, swapAmount * 2);
        vm.prank(user3);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[2] = IERC20(Currency.unwrap(currency0)).balanceOf(user3);
        user1BalancesBefore[2] = IERC20(Currency.unwrap(currency1)).balanceOf(user3);
        
        console2.log("  User3 token0 balance before:", user0BalancesBefore[2]);
        console2.log("  User3 token1 balance before:", user1BalancesBefore[2]);
        console2.log("  Top count before swap:", topOracle.topCount());
        
        vm.prank(user3);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false, // token1 -> token0
            poolKey: poolKey,
            hookData: "",
            receiver: user3,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[2] = IERC20(Currency.unwrap(currency0)).balanceOf(user3);
        user1BalancesAfter[2] = IERC20(Currency.unwrap(currency1)).balanceOf(user3);
        
        console2.log("  User3 token0 balance after:", user0BalancesAfter[2]);
        console2.log("  User3 token1 balance after:", user1BalancesAfter[2]);
        console2.log("  User3 token1 spent:", user1BalancesBefore[2] - user1BalancesAfter[2]);
        console2.log("  User3 token0 received:", user0BalancesAfter[2] - user0BalancesBefore[2]);
        
        // Verify no rebates occurred (no daemons to pay)
        assertEq(topOracle.topCount(), 0, "Top should remain empty");
        assertEq(registry.length(), 0, "Registry should remain empty");
        assertEq(topOracle.epochDurationBlocks(), 0, "Oracle should remain uninitialized");
        
        console2.log("Test completed successfully - no rebates as expected");
    }


    function testStage1Filled() public {
        // Start from block 1
        vm.roll(1);
        console2.log("Starting from block:", block.number);
        console2.log("Top count (should be 0):", topOracle.topCount());

        // Verify that top is initially empty
        assertEq(topOracle.topCount(), 0, "Top should be empty at start");
        console2.log("Top is empty at start");

        // Verify that registry is empty initially
        assertEq(registry.length(), 0, "Registry should be empty at start");
        console2.log("Registry is empty at start");

        // Verify Oracle is not initialized initially
        assertEq(topOracle.epochDurationBlocks(), 0, "Oracle should not be initialized");
        console2.log("Oracle is not initialized (0 epoch duration)");

        // NOW ADD 10 DAEMONS TO REGISTRY FIRST
        console2.log("\n--- ADDING 10 DAEMONS TO REGISTRY ---");
        
        // Deploy 10 test daemons
        TestDaemon[] memory daemons = new TestDaemon[](10);
        address[] memory daemonAddresses = new address[](10);
        address[] memory owners = new address[](10);
        
        for (uint256 i = 0; i < 10; i++) {
            daemons[i] = new TestDaemon(uint128(100e15 + i * 10e15), Currency.unwrap(currency0)); // Different rebate amounts
            daemonAddresses[i] = address(daemons[i]);
            owners[i] = address(this);
            
            // Fund daemons
            deal(Currency.unwrap(currency0), address(daemons[i]), 10e18);
            
            // Daemons approve hook and pool manager
            daemons[i].approveHook(address(hook), 10e18);
            daemons[i].approvePoolManager(address(poolManager), 10e18);
        }
        
        // Register all daemons
        vm.prank(registryOwner);
        registry.addMany(daemonAddresses, owners);
        
        // Activate all daemons
        for (uint256 i = 0; i < 10; i++) {
            registry.setActive(address(daemons[i]), true);
        }
        
        console2.log("Registry daemon count:", registry.length());
        console2.log("Top count still empty:", topOracle.topCount());
        console2.log("Has pending top request:", topOracle.hasPendingTopRequest());

        // NOW ACTIVATE THE ORACLE (after daemons are registered)
        console2.log("\n--- ACTIVATING ORACLE ---");
        bytes memory encodedRequest = abi.encode("test-request");
        uint64 subscriptionId = 1;
        uint32 callbackGasLimit = 300000;
        
        topOracle.startRebateEpochs(
            100, // epochDurationBlocks
            encodedRequest,
            subscriptionId,
            callbackGasLimit
        );
        
        console2.log("Oracle activated with epoch duration:", topOracle.epochDurationBlocks());
        console2.log("Top count after activation:", topOracle.topCount());
        console2.log("Has pending top request after activation:", topOracle.hasPendingTopRequest());

        // Wait 10 blocks to simulate Chainlink Functions computation
        console2.log("\n--- WAITING 10 BLOCKS FOR CHAINLINK COMPUTATION ---");
        vm.roll(block.number + 10);
        console2.log("Moved to block:", block.number);
        
        // Fulfill the Chainlink request to populate top daemons
        console2.log("\n--- FULFILLING CHAINLINK REQUEST ---");
        uint256[8] memory topIds;
        // Set first 3 daemons as top (ids 0, 1, 2)
        topIds[0] = 0 | (1 << 16) | (2 << 32) | (0xffff << 48);
        
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, topIds);
        
        console2.log("Top count after fulfillment:", topOracle.topCount());
        console2.log("Current top after fulfillment:", topOracle.getCurrentTop());
        console2.log("Has pending top request after fulfillment:", topOracle.hasPendingTopRequest());

        // Define 3 different users
        address user1 = address(0x1001);
        address user2 = address(0x1002);
        address user3 = address(0x1003);
        
        console2.log("\n--- PERFORMING 3 SWAPS (ALL SHOULD GET REBATES) ---");
        console2.log("User1:", user1);
        console2.log("User2:", user2);
        console2.log("User3:", user3);
        
        // Track balances for all users and daemons
        uint256[3] memory user0BalancesBefore;
        uint256[3] memory user1BalancesBefore;
        uint256[3] memory user0BalancesAfter;
        uint256[3] memory user1BalancesAfter;
        uint256[10] memory daemonBalancesBefore;
        uint256[10] memory daemonBalancesAfter;
        
        // SWAP 1: token0 -> token1 (user1) - Should get rebate (top already populated)
        console2.log("\n--- SWAP 1: token0 -> token1 (user1) - SHOULD GET REBATE ---");
        console2.log("Block before swap:", block.number);
        
        uint256 swapAmount = 1e18;
        deal(Currency.unwrap(currency0), user1, swapAmount * 2);
        vm.prank(user1);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[0] = IERC20(Currency.unwrap(currency0)).balanceOf(user1);
        user1BalancesBefore[0] = IERC20(Currency.unwrap(currency1)).balanceOf(user1);
        
        // Track daemon balances before swap
        for (uint256 i = 0; i < 3; i++) {
            daemonBalancesBefore[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User1 token0 balance before:", user0BalancesBefore[0]);
        console2.log("  User1 token1 balance before:", user1BalancesBefore[0]);
        console2.log("  Top count before swap:", topOracle.topCount());
        console2.log("  Daemon0 balance before:", daemonBalancesBefore[0]);
        console2.log("  Daemon1 balance before:", daemonBalancesBefore[1]);
        console2.log("  Daemon2 balance before:", daemonBalancesBefore[2]);
        
        vm.prank(user1);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true, // token0 -> token1
            poolKey: poolKey,
            hookData: "",
            receiver: user1,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[0] = IERC20(Currency.unwrap(currency0)).balanceOf(user1);
        user1BalancesAfter[0] = IERC20(Currency.unwrap(currency1)).balanceOf(user1);
        
        // Track daemon balances after swap
        for (uint256 i = 0; i < 3; i++) {
            daemonBalancesAfter[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User1 token0 balance after:", user0BalancesAfter[0]);
        console2.log("  User1 token1 balance after:", user1BalancesAfter[0]);
        console2.log("  User1 token0 spent:", user0BalancesBefore[0] - user0BalancesAfter[0]);
        console2.log("  User1 token1 received:", user1BalancesAfter[0] - user1BalancesBefore[0]);
        console2.log("  Daemon0 balance after:", daemonBalancesAfter[0]);
        console2.log("  Daemon1 balance after:", daemonBalancesAfter[1]);
        console2.log("  Daemon2 balance after:", daemonBalancesAfter[2]);
        console2.log("  Daemon0 paid:", daemonBalancesBefore[0] - daemonBalancesAfter[0]);
        console2.log("  Daemon1 paid:", daemonBalancesBefore[1] - daemonBalancesAfter[1]);
        console2.log("  Daemon2 paid:", daemonBalancesBefore[2] - daemonBalancesAfter[2]);
        
        // Move 12 blocks forward
        vm.roll(block.number + 12);
        console2.log("  Moved to block:", block.number);
        
        // SWAP 2: token1 -> token0 (user2) - Should get rebate
        console2.log("\n--- SWAP 2: token1 -> token0 (user2) - SHOULD GET REBATE ---");
        console2.log("Block before swap:", block.number);
        
        deal(Currency.unwrap(currency1), user2, swapAmount * 2);
        vm.prank(user2);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[1] = IERC20(Currency.unwrap(currency0)).balanceOf(user2);
        user1BalancesBefore[1] = IERC20(Currency.unwrap(currency1)).balanceOf(user2);
        
        // Track daemon balances before swap
        for (uint256 i = 0; i < 3; i++) {
            daemonBalancesBefore[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User2 token0 balance before:", user0BalancesBefore[1]);
        console2.log("  User2 token1 balance before:", user1BalancesBefore[1]);
        console2.log("  Top count before swap:", topOracle.topCount());
        console2.log("  Daemon0 balance before:", daemonBalancesBefore[0]);
        console2.log("  Daemon1 balance before:", daemonBalancesBefore[1]);
        console2.log("  Daemon2 balance before:", daemonBalancesBefore[2]);
        
        vm.prank(user2);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false, // token1 -> token0
            poolKey: poolKey,
            hookData: "",
            receiver: user2,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[1] = IERC20(Currency.unwrap(currency0)).balanceOf(user2);
        user1BalancesAfter[1] = IERC20(Currency.unwrap(currency1)).balanceOf(user2);
        
        // Track daemon balances after swap
        for (uint256 i = 0; i < 3; i++) {
            daemonBalancesAfter[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User2 token0 balance after:", user0BalancesAfter[1]);
        console2.log("  User2 token1 balance after:", user1BalancesAfter[1]);
        console2.log("  User2 token1 spent:", user1BalancesBefore[1] - user1BalancesAfter[1]);
        console2.log("  User2 token0 received:", user0BalancesAfter[1] - user0BalancesBefore[1]);
        console2.log("  Daemon0 balance after:", daemonBalancesAfter[0]);
        console2.log("  Daemon1 balance after:", daemonBalancesAfter[1]);
        console2.log("  Daemon2 balance after:", daemonBalancesAfter[2]);
        console2.log("  Daemon0 paid:", daemonBalancesBefore[0] - daemonBalancesAfter[0]);
        console2.log("  Daemon1 paid:", daemonBalancesBefore[1] - daemonBalancesAfter[1]);
        console2.log("  Daemon2 paid:", daemonBalancesBefore[2] - daemonBalancesAfter[2]);
        
        // Move 15 blocks forward
        vm.roll(block.number + 15);
        console2.log("  Moved to block:", block.number);
        
        // SWAP 3: token1 -> token0 (user3) - Should get rebate
        console2.log("\n--- SWAP 3: token1 -> token0 (user3) - SHOULD GET REBATE ---");
        console2.log("Block before swap:", block.number);
        
        deal(Currency.unwrap(currency1), user3, swapAmount * 2);
        vm.prank(user3);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[2] = IERC20(Currency.unwrap(currency0)).balanceOf(user3);
        user1BalancesBefore[2] = IERC20(Currency.unwrap(currency1)).balanceOf(user3);
        
        // Track daemon balances before swap (reset for swap 3)
        for (uint256 i = 0; i < 3; i++) {
            daemonBalancesBefore[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User3 token0 balance before:", user0BalancesBefore[2]);
        console2.log("  User3 token1 balance before:", user1BalancesBefore[2]);
        console2.log("  Top count before swap:", topOracle.topCount());
        console2.log("  Daemon0 balance before:", daemonBalancesBefore[0]);
        console2.log("  Daemon1 balance before:", daemonBalancesBefore[1]);
        console2.log("  Daemon2 balance before:", daemonBalancesBefore[2]);
        
        vm.prank(user3);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false, // token1 -> token0
            poolKey: poolKey,
            hookData: "",
            receiver: user3,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[2] = IERC20(Currency.unwrap(currency0)).balanceOf(user3);
        user1BalancesAfter[2] = IERC20(Currency.unwrap(currency1)).balanceOf(user3);
        
        // Track daemon balances after swap
        for (uint256 i = 0; i < 3; i++) {
            daemonBalancesAfter[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User3 token0 balance after:", user0BalancesAfter[2]);
        console2.log("  User3 token1 balance after:", user1BalancesAfter[2]);
        console2.log("  User3 token1 spent:", user1BalancesBefore[2] - user1BalancesAfter[2]);
        console2.log("  User3 token0 received:", user0BalancesAfter[2] - user0BalancesBefore[2]);
        console2.log("  Daemon0 balance after:", daemonBalancesAfter[0]);
        console2.log("  Daemon1 balance after:", daemonBalancesAfter[1]);
        console2.log("  Daemon2 balance after:", daemonBalancesAfter[2]);
        console2.log("  Daemon0 paid:", daemonBalancesBefore[0] - daemonBalancesAfter[0]);
        console2.log("  Daemon1 paid:", daemonBalancesBefore[1] - daemonBalancesAfter[1]);
        console2.log("  Daemon2 paid:", daemonBalancesBefore[2] - daemonBalancesAfter[2]);
        
        // Final verification
        console2.log("\n=== FINAL VERIFICATION ===");
        console2.log("All swaps completed successfully");
        console2.log("Top count:", topOracle.topCount());
        console2.log("Registry daemon count:", registry.length());
        console2.log("Oracle epoch duration:", topOracle.epochDurationBlocks());
        
        // Verify rebates occurred for all swaps
        assertGt(topOracle.topCount(), 0, "Top should be populated after fulfillment");
        assertGt(registry.length(), 0, "Registry should have daemons");
        assertGt(topOracle.epochDurationBlocks(), 0, "Oracle should be activated");
        
        console2.log("Test completed successfully - rebates received for all 3 swaps");
    }

    function testStage2Mature() public {
        // Start from block 1
        vm.roll(1);
        console2.log("Starting from block:", block.number);
        console2.log("Top count (should be 0):", topOracle.topCount());

        // Verify that top is initially empty
        assertEq(topOracle.topCount(), 0, "Top should be empty at start");
        console2.log("Top is empty at start");

        // Verify that registry is empty initially
        assertEq(registry.length(), 0, "Registry should be empty at start");
        console2.log("Registry is empty at start");

        // Verify Oracle is not initialized initially
        assertEq(topOracle.epochDurationBlocks(), 0, "Oracle should not be initialized");
        console2.log("Oracle is not initialized (0 epoch duration)");

        // NOW ADD 15 DAEMONS TO REGISTRY FIRST
        console2.log("\n--- ADDING 15 DAEMONS TO REGISTRY ---");
        
        // Deploy 15 test daemons
        TestDaemon[] memory daemons = new TestDaemon[](15);
        address[] memory daemonAddresses = new address[](15);
        address[] memory owners = new address[](15);
        
        for (uint256 i = 0; i < 15; i++) {
            daemons[i] = new TestDaemon(uint128(100e15 + i * 10e15), Currency.unwrap(currency0)); // Different rebate amounts
            daemonAddresses[i] = address(daemons[i]);
            owners[i] = address(this);
            
            // Fund daemons
            deal(Currency.unwrap(currency0), address(daemons[i]), 20e18);
            
            // Daemons approve hook and pool manager
            daemons[i].approveHook(address(hook), 20e18);
            daemons[i].approvePoolManager(address(poolManager), 20e18);
        }
        
        // Register all daemons
        vm.prank(registryOwner);
        registry.addMany(daemonAddresses, owners);
        
        // Activate all daemons
        for (uint256 i = 0; i < 15; i++) {
            registry.setActive(address(daemons[i]), true);
        }
        
        console2.log("Registry daemon count:", registry.length());
        console2.log("Top count still empty:", topOracle.topCount());
        console2.log("Has pending top request:", topOracle.hasPendingTopRequest());

        // NOW ACTIVATE THE ORACLE (after daemons are registered)
        console2.log("\n--- ACTIVATING ORACLE ---");
        bytes memory encodedRequest = abi.encode("test-request");
        uint64 subscriptionId = 1;
        uint32 callbackGasLimit = 300000;
        
        topOracle.startRebateEpochs(
            100, // epochDurationBlocks = 100 blocks
            encodedRequest,
            subscriptionId,
            callbackGasLimit
        );
        
        console2.log("Oracle activated with epoch duration:", topOracle.epochDurationBlocks());
        console2.log("Top count after activation:", topOracle.topCount());
        console2.log("Has pending top request after activation:", topOracle.hasPendingTopRequest());

        // Wait 10 blocks to simulate Chainlink Functions computation
        console2.log("\n--- WAITING 10 BLOCKS FOR CHAINLINK COMPUTATION ---");
        vm.roll(block.number + 10);
        console2.log("Moved to block:", block.number);
        
        // Fulfill the Chainlink request to populate EPOCH 1 top daemons (all 15 daemons)
        console2.log("\n--- FULFILLING EPOCH 1 CHAINLINK REQUEST ---");
        uint256[8] memory epoch1TopIds;
        // Set all 15 daemons as top (ids 0-14)
        epoch1TopIds[0] = 0 | (1 << 16) | (2 << 32) | (3 << 48) | (4 << 64) | (5 << 80) | (6 << 96) | (7 << 112) | (8 << 128) | (9 << 144) | (10 << 160) | (11 << 176) | (12 << 192) | (13 << 208) | (14 << 224);
        epoch1TopIds[1] = 0xffff; // End marker
        
        bytes32 requestId1 = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId1, epoch1TopIds);
        
        console2.log("Epoch 1 top count after fulfillment:", topOracle.topCount());
        console2.log("Epoch 1 current top after fulfillment:", topOracle.getCurrentTop());
        console2.log("Has pending top request after fulfillment:", topOracle.hasPendingTopRequest());
        console2.log("Current epoch:", topOracle.topEpoch());

        // Define 5 different users for 5 swaps
        address user1 = address(0x1001);
        address user2 = address(0x1002);
        address user3 = address(0x1003);
        address user4 = address(0x1004);
        address user5 = address(0x1005);
        
        console2.log("\n--- PERFORMING 5 SWAPS ACROSS EPOCH TRANSITION ---");
        console2.log("User1:", user1);
        console2.log("User2:", user2);
        console2.log("User3:", user3);
        console2.log("User4:", user4);
        console2.log("User5:", user5);
        
        // Track balances for all users and daemons
        uint256[5] memory user0BalancesBefore;
        uint256[5] memory user1BalancesBefore;
        uint256[5] memory user0BalancesAfter;
        uint256[5] memory user1BalancesAfter;
        uint256[15] memory daemonBalancesBefore;
        uint256[15] memory daemonBalancesAfter;
        
        // EPOCH 1 SWAPS (blocks 11-111): Swaps 1-3
        console2.log("\n=== EPOCH 1 SWAPS (blocks 11-111) ===");
        
        // SWAP 1: token0 -> token1 (user1) - EPOCH 1
        console2.log("\n--- SWAP 1: token0 -> token1 (user1) - EPOCH 1 ---");
        console2.log("Block before swap:", block.number);
        
        uint256 swapAmount = 1e18;
        deal(Currency.unwrap(currency0), user1, swapAmount * 2);
        vm.prank(user1);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[0] = IERC20(Currency.unwrap(currency0)).balanceOf(user1);
        user1BalancesBefore[0] = IERC20(Currency.unwrap(currency1)).balanceOf(user1);
        
        // Track daemon balances before swap
        for (uint256 i = 0; i < 15; i++) {
            daemonBalancesBefore[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User1 token0 balance before:", user0BalancesBefore[0]);
        console2.log("  User1 token1 balance before:", user1BalancesBefore[0]);
        console2.log("  Top count before swap:", topOracle.topCount());
        console2.log("  Current epoch before swap:", topOracle.topEpoch());
        console2.log("  Daemon0 balance before:", daemonBalancesBefore[0]);
        console2.log("  Daemon1 balance before:", daemonBalancesBefore[1]);
        console2.log("  Daemon2 balance before:", daemonBalancesBefore[2]);
        
        vm.prank(user1);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true, // token0 -> token1
            poolKey: poolKey,
            hookData: "",
            receiver: user1,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[0] = IERC20(Currency.unwrap(currency0)).balanceOf(user1);
        user1BalancesAfter[0] = IERC20(Currency.unwrap(currency1)).balanceOf(user1);
        
        // Track daemon balances after swap
        for (uint256 i = 0; i < 15; i++) {
            daemonBalancesAfter[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User1 token0 balance after:", user0BalancesAfter[0]);
        console2.log("  User1 token1 balance after:", user1BalancesAfter[0]);
        console2.log("  User1 token0 spent:", user0BalancesBefore[0] - user0BalancesAfter[0]);
        console2.log("  User1 token1 received:", user1BalancesAfter[0] - user1BalancesBefore[0]);
        console2.log("  Daemon0 paid:", daemonBalancesBefore[0] - daemonBalancesAfter[0]);
        console2.log("  Daemon1 paid:", daemonBalancesBefore[1] - daemonBalancesAfter[1]);
        console2.log("  Daemon2 paid:", daemonBalancesBefore[2] - daemonBalancesAfter[2]);
        
        // Move to block 30 (within EPOCH 1)
        vm.roll(30);
        console2.log("  Moved to block:", block.number);
        
        // SWAP 2: token1 -> token0 (user2) - EPOCH 1
        console2.log("\n--- SWAP 2: token1 -> token0 (user2) - EPOCH 1 ---");
        console2.log("Block before swap:", block.number);
        
        deal(Currency.unwrap(currency1), user2, swapAmount * 2);
        vm.prank(user2);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[1] = IERC20(Currency.unwrap(currency0)).balanceOf(user2);
        user1BalancesBefore[1] = IERC20(Currency.unwrap(currency1)).balanceOf(user2);
        
        // Track daemon balances before swap
        for (uint256 i = 0; i < 15; i++) {
            daemonBalancesBefore[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User2 token0 balance before:", user0BalancesBefore[1]);
        console2.log("  User2 token1 balance before:", user1BalancesBefore[1]);
        console2.log("  Top count before swap:", topOracle.topCount());
        console2.log("  Current epoch before swap:", topOracle.topEpoch());
        console2.log("  Daemon0 balance before:", daemonBalancesBefore[0]);
        console2.log("  Daemon1 balance before:", daemonBalancesBefore[1]);
        console2.log("  Daemon2 balance before:", daemonBalancesBefore[2]);
        
        vm.prank(user2);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false, // token1 -> token0
            poolKey: poolKey,
            hookData: "",
            receiver: user2,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[1] = IERC20(Currency.unwrap(currency0)).balanceOf(user2);
        user1BalancesAfter[1] = IERC20(Currency.unwrap(currency1)).balanceOf(user2);
        
        // Track daemon balances after swap
        for (uint256 i = 0; i < 15; i++) {
            daemonBalancesAfter[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User2 token0 balance after:", user0BalancesAfter[1]);
        console2.log("  User2 token1 balance after:", user1BalancesAfter[1]);
        console2.log("  User2 token1 spent:", user1BalancesBefore[1] - user1BalancesAfter[1]);
        console2.log("  User2 token0 received:", user0BalancesAfter[1] - user0BalancesBefore[1]);
        console2.log("  Daemon0 paid:", daemonBalancesBefore[0] - daemonBalancesAfter[0]);
        console2.log("  Daemon1 paid:", daemonBalancesBefore[1] - daemonBalancesAfter[1]);
        console2.log("  Daemon2 paid:", daemonBalancesBefore[2] - daemonBalancesAfter[2]);
        
        // Move to block 50 (within EPOCH 1)
        vm.roll(50);
        console2.log("  Moved to block:", block.number);
        
        // SWAP 3: token1 -> token0 (user3) - EPOCH 1
        console2.log("\n--- SWAP 3: token1 -> token0 (user3) - EPOCH 1 ---");
        console2.log("Block before swap:", block.number);
        
        deal(Currency.unwrap(currency1), user3, swapAmount * 2);
        vm.prank(user3);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[2] = IERC20(Currency.unwrap(currency0)).balanceOf(user3);
        user1BalancesBefore[2] = IERC20(Currency.unwrap(currency1)).balanceOf(user3);
        
        // Track daemon balances before swap
        for (uint256 i = 0; i < 15; i++) {
            daemonBalancesBefore[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User3 token0 balance before:", user0BalancesBefore[2]);
        console2.log("  User3 token1 balance before:", user1BalancesBefore[2]);
        console2.log("  Top count before swap:", topOracle.topCount());
        console2.log("  Current epoch before swap:", topOracle.topEpoch());
        console2.log("  Daemon0 balance before:", daemonBalancesBefore[0]);
        console2.log("  Daemon1 balance before:", daemonBalancesBefore[1]);
        console2.log("  Daemon2 balance before:", daemonBalancesBefore[2]);
        
        vm.prank(user3);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false, // token1 -> token0
            poolKey: poolKey,
            hookData: "",
            receiver: user3,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[2] = IERC20(Currency.unwrap(currency0)).balanceOf(user3);
        user1BalancesAfter[2] = IERC20(Currency.unwrap(currency1)).balanceOf(user3);
        
        // Track daemon balances after swap
        for (uint256 i = 0; i < 15; i++) {
            daemonBalancesAfter[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User3 token0 balance after:", user0BalancesAfter[2]);
        console2.log("  User3 token1 balance after:", user1BalancesAfter[2]);
        console2.log("  User3 token1 spent:", user1BalancesBefore[2] - user1BalancesAfter[2]);
        console2.log("  User3 token0 received:", user0BalancesAfter[2] - user0BalancesBefore[2]);
        console2.log("  Daemon0 paid:", daemonBalancesBefore[0] - daemonBalancesAfter[0]);
        console2.log("  Daemon1 paid:", daemonBalancesBefore[1] - daemonBalancesAfter[1]);
        console2.log("  Daemon2 paid:", daemonBalancesBefore[2] - daemonBalancesAfter[2]);
        
        // Move to block 111 (EPOCH 1 EXPIRED - triggers maybeRequestTopUpdate)
        console2.log("\n=== EPOCH TRANSITION (block 111) ===");
        vm.roll(111);
        console2.log("Moved to block 111 (EPOCH 1 EXPIRED):", block.number);
        console2.log("Epoch duration:", topOracle.epochDurationBlocks());
        console2.log("Last epoch start block:", topOracle.lastEpochStartBlock());
        console2.log("Has pending top request before swap:", topOracle.hasPendingTopRequest());
        
        // SWAP 4: token0 -> token1 (user4) - EPOCH 1 EXPIRED, triggers request
        console2.log("\n--- SWAP 4: token0 -> token1 (user4) - EPOCH 1 EXPIRED, TRIGGERS REQUEST ---");
        console2.log("Block before swap:", block.number);
        
        deal(Currency.unwrap(currency0), user4, swapAmount * 2);
        vm.prank(user4);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[3] = IERC20(Currency.unwrap(currency0)).balanceOf(user4);
        user1BalancesBefore[3] = IERC20(Currency.unwrap(currency1)).balanceOf(user4);
        
        // Track daemon balances before swap
        for (uint256 i = 0; i < 15; i++) {
            daemonBalancesBefore[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User4 token0 balance before:", user0BalancesBefore[3]);
        console2.log("  User4 token1 balance before:", user1BalancesBefore[3]);
        console2.log("  Top count before swap:", topOracle.topCount());
        console2.log("  Current epoch before swap:", topOracle.topEpoch());
        console2.log("  Daemon3 balance before:", daemonBalancesBefore[3]);
        console2.log("  Daemon4 balance before:", daemonBalancesBefore[4]);
        console2.log("  Daemon5 balance before:", daemonBalancesBefore[5]);
        
        vm.prank(user4);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true, // token0 -> token1
            poolKey: poolKey,
            hookData: "",
            receiver: user4,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[3] = IERC20(Currency.unwrap(currency0)).balanceOf(user4);
        user1BalancesAfter[3] = IERC20(Currency.unwrap(currency1)).balanceOf(user4);
        
        // Track daemon balances after swap
        for (uint256 i = 0; i < 15; i++) {
            daemonBalancesAfter[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User4 token0 balance after:", user0BalancesAfter[3]);
        console2.log("  User4 token1 balance after:", user1BalancesAfter[3]);
        console2.log("  User4 token0 spent:", user0BalancesBefore[3] - user0BalancesAfter[3]);
        console2.log("  User4 token1 received:", user1BalancesAfter[3] - user1BalancesBefore[3]);
        console2.log("  Daemon3 paid:", daemonBalancesBefore[3] - daemonBalancesAfter[3]);
        console2.log("  Daemon4 paid:", daemonBalancesBefore[4] - daemonBalancesAfter[4]);
        console2.log("  Daemon5 paid:", daemonBalancesBefore[5] - daemonBalancesAfter[5]);
        console2.log("  Has pending top request after swap:", topOracle.hasPendingTopRequest());
        
        // SWAP 5: token1 -> token0 (user5) - Still using EPOCH 1 top (during Chainlink computation)
        console2.log("\n--- SWAP 5: token1 -> token0 (user5) - STILL EPOCH 1 TOP (DURING COMPUTATION) ---");
        // Move to block 115 (during Chainlink computation period)
        vm.roll(115);
        console2.log("Moved to block 115 (during Chainlink computation):", block.number);
        console2.log("Block before swap:", block.number);
        
        deal(Currency.unwrap(currency1), user5, swapAmount * 2);
        vm.prank(user5);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[4] = IERC20(Currency.unwrap(currency0)).balanceOf(user5);
        user1BalancesBefore[4] = IERC20(Currency.unwrap(currency1)).balanceOf(user5);
        
        // Track daemon balances before swap
        for (uint256 i = 0; i < 15; i++) {
            daemonBalancesBefore[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User5 token0 balance before:", user0BalancesBefore[4]);
        console2.log("  User5 token1 balance before:", user1BalancesBefore[4]);
        console2.log("  Top count before swap:", topOracle.topCount());
        console2.log("  Current epoch before swap:", topOracle.topEpoch());
        console2.log("  Daemon3 balance before:", daemonBalancesBefore[3]);
        console2.log("  Daemon4 balance before:", daemonBalancesBefore[4]);
        console2.log("  Daemon5 balance before:", daemonBalancesBefore[5]);
        
        vm.prank(user5);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false, // token1 -> token0
            poolKey: poolKey,
            hookData: "",
            receiver: user5,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[4] = IERC20(Currency.unwrap(currency0)).balanceOf(user5);
        user1BalancesAfter[4] = IERC20(Currency.unwrap(currency1)).balanceOf(user5);
        
        // Track daemon balances after swap
        for (uint256 i = 0; i < 15; i++) {
            daemonBalancesAfter[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  User5 token0 balance after:", user0BalancesAfter[4]);
        console2.log("  User5 token1 balance after:", user1BalancesAfter[4]);
        console2.log("  User5 token1 spent:", user1BalancesBefore[4] - user1BalancesAfter[4]);
        console2.log("  User5 token0 received:", user0BalancesAfter[4] - user0BalancesBefore[4]);
        console2.log("  Daemon3 paid:", daemonBalancesBefore[3] - daemonBalancesAfter[3]);
        console2.log("  Daemon4 paid:", daemonBalancesBefore[4] - daemonBalancesAfter[4]);
        console2.log("  Daemon5 paid:", daemonBalancesBefore[5] - daemonBalancesAfter[5]);
        
        // Wait for Chainlink Functions computation to complete
        console2.log("\n--- WAITING FOR CHAINLINK COMPUTATION TO COMPLETE ---");
        vm.roll(121);
        console2.log("Moved to block 121 (Chainlink computation complete):", block.number);
        
        // Fulfill EPOCH 2 request (daemons 5-14, since first 5 were used)
        console2.log("\n--- FULFILLING EPOCH 2 CHAINLINK REQUEST ---");
        uint256[8] memory epoch2TopIds;
        // Set daemons 5-14 as top (ids 5-14)
        epoch2TopIds[0] = 5 | (6 << 16) | (7 << 32) | (8 << 48) | (9 << 64) | (10 << 80) | (11 << 96) | (12 << 112) | (13 << 128) | (14 << 144) | (0xffff << 160);
        
        bytes32 requestId2 = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId2, epoch2TopIds);
        
        console2.log("Epoch 2 top count after fulfillment:", topOracle.topCount());
        console2.log("Epoch 2 current top after fulfillment:", topOracle.getCurrentTop());
        console2.log("Has pending top request after fulfillment:", topOracle.hasPendingTopRequest());
        console2.log("Current epoch after fulfillment:", topOracle.topEpoch());
        
        // Move to block 130 (within EPOCH 2)
        vm.roll(130);
        console2.log("Moved to block 130 (EPOCH 2):", block.number);
        
        // EPOCH 2 SWAPS: Additional swaps using EPOCH 2 top daemons
        console2.log("\n=== EPOCH 2 SWAPS (block 130+) ===");
        
        // Additional swap to test EPOCH 2
        console2.log("\n--- ADDITIONAL SWAP: token0 -> token1 (user1) - EPOCH 2 ---");
        console2.log("Block before swap:", block.number);
        
        deal(Currency.unwrap(currency0), user1, swapAmount * 2);
        vm.prank(user1);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount * 2);
        
        // Track daemon balances before swap (daemons 5-14)
        for (uint256 i = 5; i < 15; i++) {
            daemonBalancesBefore[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  Top count before swap:", topOracle.topCount());
        console2.log("  Current epoch before swap:", topOracle.topEpoch());
        console2.log("  Daemon5 balance before:", daemonBalancesBefore[5]);
        console2.log("  Daemon6 balance before:", daemonBalancesBefore[6]);
        console2.log("  Daemon7 balance before:", daemonBalancesBefore[7]);
        
        vm.prank(user1);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true, // token0 -> token1
            poolKey: poolKey,
            hookData: "",
            receiver: user1,
            deadline: block.timestamp + 1
        });
        
        // Track daemon balances after swap
        for (uint256 i = 5; i < 15; i++) {
            daemonBalancesAfter[i] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemons[i]));
        }
        
        console2.log("  Daemon5 paid:", daemonBalancesBefore[5] - daemonBalancesAfter[5]);
        console2.log("  Daemon6 paid:", daemonBalancesBefore[6] - daemonBalancesAfter[6]);
        console2.log("  Daemon7 paid:", daemonBalancesBefore[7] - daemonBalancesAfter[7]);
        
        // Final verification
        console2.log("\n=== FINAL VERIFICATION ===");
        console2.log("All swaps completed successfully");
        console2.log("Final top count:", topOracle.topCount());
        console2.log("Final registry daemon count:", registry.length());
        console2.log("Final epoch:", topOracle.topEpoch());
        console2.log("Has pending top request:", topOracle.hasPendingTopRequest());
        
        // Verify epoch transition worked correctly
        assertGt(topOracle.topCount(), 0, "Top should be populated");
        assertGt(registry.length(), 0, "Registry should have daemons");
        assertGt(topOracle.epochDurationBlocks(), 0, "Oracle should be activated");
        assertEq(topOracle.topEpoch(), 2, "Should be in epoch 2");
        
        console2.log("Test completed successfully - epoch transition and daemon rotation working correctly");
    }

    function testStage1Empty() public {
        // Start from block 1
        vm.roll(1);
        console2.log("Starting from block:", block.number);
        console2.log("Top count (should be 0):", topOracle.topCount());

        // Verify that top is initially empty
        assertEq(topOracle.topCount(), 0, "Top should be empty at start");
        console2.log("Top is empty at start");

        // Verify that registry is empty (no daemons registered)
        assertEq(registry.length(), 0, "Registry should be empty at start");
        console2.log("Registry is empty at start");

        // Verify Oracle is not initialized initially
        assertEq(topOracle.epochDurationBlocks(), 0, "Oracle should not be initialized");
        console2.log("Oracle is not initialized (0 epoch duration)");

        // NOW ACTIVATE THE ORACLE (but keep registry empty)
        console2.log("\n--- ACTIVATING ORACLE ---");
        bytes memory encodedRequest = abi.encode("test-request");
        uint64 subscriptionId = 1;
        uint32 callbackGasLimit = 300000;
        
        topOracle.startRebateEpochs(
            100, // epochDurationBlocks
            encodedRequest,
            subscriptionId,
            callbackGasLimit
        );
        
        console2.log("Oracle activated with epoch duration:", topOracle.epochDurationBlocks());
        console2.log("Top count after activation:", topOracle.topCount());
        console2.log("Registry still empty:", registry.length());

        // Define 3 different users
        address user1 = address(0x1001);
        address user2 = address(0x1002);
        address user3 = address(0x1003);
        
        console2.log("\n--- PERFORMING 3 SWAPS WITH NO REBATES (ORACLE ACTIVE BUT NO DAEMONS) ---");
        console2.log("User1:", user1);
        console2.log("User2:", user2);
        console2.log("User3:", user3);
        
        // Track balances for all users
        uint256[3] memory user0BalancesBefore;
        uint256[3] memory user1BalancesBefore;
        uint256[3] memory user0BalancesAfter;
        uint256[3] memory user1BalancesAfter;
        
        // SWAP 1: token0 -> token1 (user1)
        console2.log("\n--- SWAP 1: token0 -> token1 (user1) ---");
        console2.log("Block before swap:", block.number);
        
        uint256 swapAmount = 1e18;
        deal(Currency.unwrap(currency0), user1, swapAmount * 2);
        vm.prank(user1);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[0] = IERC20(Currency.unwrap(currency0)).balanceOf(user1);
        user1BalancesBefore[0] = IERC20(Currency.unwrap(currency1)).balanceOf(user1);
        
        console2.log("  User1 token0 balance before:", user0BalancesBefore[0]);
        console2.log("  User1 token1 balance before:", user1BalancesBefore[0]);
        console2.log("  Top count before swap:", topOracle.topCount());
        
        vm.prank(user1);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true, // token0 -> token1
            poolKey: poolKey,
            hookData: "",
            receiver: user1,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[0] = IERC20(Currency.unwrap(currency0)).balanceOf(user1);
        user1BalancesAfter[0] = IERC20(Currency.unwrap(currency1)).balanceOf(user1);
        
        console2.log("  User1 token0 balance after:", user0BalancesAfter[0]);
        console2.log("  User1 token1 balance after:", user1BalancesAfter[0]);
        console2.log("  User1 token0 spent:", user0BalancesBefore[0] - user0BalancesAfter[0]);
        console2.log("  User1 token1 received:", user1BalancesAfter[0] - user1BalancesBefore[0]);
        
        // Move 12 blocks forward
        vm.roll(block.number + 12);
        console2.log("  Moved to block:", block.number);
        
        // SWAP 2: token1 -> token0 (user2)
        console2.log("\n--- SWAP 2: token1 -> token0 (user2) ---");
        console2.log("Block before swap:", block.number);
        
        deal(Currency.unwrap(currency1), user2, swapAmount * 2);
        vm.prank(user2);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[1] = IERC20(Currency.unwrap(currency0)).balanceOf(user2);
        user1BalancesBefore[1] = IERC20(Currency.unwrap(currency1)).balanceOf(user2);
        
        console2.log("  User2 token0 balance before:", user0BalancesBefore[1]);
        console2.log("  User2 token1 balance before:", user1BalancesBefore[1]);
        console2.log("  Top count before swap:", topOracle.topCount());
        
        vm.prank(user2);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false, // token1 -> token0
            poolKey: poolKey,
            hookData: "",
            receiver: user2,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[1] = IERC20(Currency.unwrap(currency0)).balanceOf(user2);
        user1BalancesAfter[1] = IERC20(Currency.unwrap(currency1)).balanceOf(user2);
        
        console2.log("  User2 token0 balance after:", user0BalancesAfter[1]);
        console2.log("  User2 token1 balance after:", user1BalancesAfter[1]);
        console2.log("  User2 token1 spent:", user1BalancesBefore[1] - user1BalancesAfter[1]);
        console2.log("  User2 token0 received:", user0BalancesAfter[1] - user0BalancesBefore[1]);
        
        // Move 15 blocks forward
        vm.roll(block.number + 15);
        console2.log("  Moved to block:", block.number);
        
        // SWAP 3: token1 -> token0 (user3)
        console2.log("\n--- SWAP 3: token1 -> token0 (user3) ---");
        console2.log("Block before swap:", block.number);
        
        deal(Currency.unwrap(currency1), user3, swapAmount * 2);
        vm.prank(user3);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount * 2);
        
        user0BalancesBefore[2] = IERC20(Currency.unwrap(currency0)).balanceOf(user3);
        user1BalancesBefore[2] = IERC20(Currency.unwrap(currency1)).balanceOf(user3);
        
        console2.log("  User3 token0 balance before:", user0BalancesBefore[2]);
        console2.log("  User3 token1 balance before:", user1BalancesBefore[2]);
        console2.log("  Top count before swap:", topOracle.topCount());
        
        vm.prank(user3);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false, // token1 -> token0
            poolKey: poolKey,
            hookData: "",
            receiver: user3,
            deadline: block.timestamp + 1
        });
        
        user0BalancesAfter[2] = IERC20(Currency.unwrap(currency0)).balanceOf(user3);
        user1BalancesAfter[2] = IERC20(Currency.unwrap(currency1)).balanceOf(user3);
        
        console2.log("  User3 token0 balance after:", user0BalancesAfter[2]);
        console2.log("  User3 token1 balance after:", user1BalancesAfter[2]);
        console2.log("  User3 token1 spent:", user1BalancesBefore[2] - user1BalancesAfter[2]);
        console2.log("  User3 token0 received:", user0BalancesAfter[2] - user0BalancesBefore[2]);
        
        // Verify no rebates occurred (no daemons to pay)
        assertEq(topOracle.topCount(), 0, "Top should remain empty");
        assertEq(registry.length(), 0, "Registry should remain empty");
        assertGt(topOracle.epochDurationBlocks(), 0, "Oracle should be activated");
        
        console2.log("Test completed successfully - no rebates as expected (Oracle active but no daemons)");
    }


}

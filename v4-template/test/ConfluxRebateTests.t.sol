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
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
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

// Fee-on-transfer token for testing
contract FeeOnTransferToken is ERC20 {
    uint256 public feePercent = 10; // 10% fee
    
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10**18);
    }
    
    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feePercent) / 100;
        uint256 netAmount = amount - fee;
        
        _transfer(msg.sender, to, netAmount);
        _transfer(msg.sender, address(this), fee);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feePercent) / 100;
        uint256 netAmount = amount - fee;
        
        _transfer(from, to, netAmount);
        _transfer(from, address(this), fee);
        return true;
    }
}

// Malicious daemon that attempts reentrancy during job execution
contract MaliciousReentrantDaemon is IDaemon {
    uint128 public rebateAmount;
    address public token;
    bool public jobExecuted;
    address public owner;
    address public poolManager;
    PoolKey public poolKey;
    uint256 public reentrancyAttempts;
    
    constructor(uint128 _rebateAmount, address _token, address _poolManager, PoolKey memory _poolKey) {
        rebateAmount = _rebateAmount;
        token = _token;
        owner = msg.sender;
        poolManager = _poolManager;
        poolKey = _poolKey;
    }
    
    function getRebateAmount(uint256) external view override returns (int128) {
        return int128(rebateAmount);
    }
    
    function accomplishDaemonJob() external override {
        jobExecuted = true;
        reentrancyAttempts++;
        
        // Attempt reentrancy by calling the pool manager's swap function
        // This should trigger the hook's beforeSwap again, testing reentrancy guard
        try IPoolManager(poolManager).swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: 1e18,
                sqrtPriceLimitX96: 0
            }),
            ""
        ) returns (BalanceDelta) {
            // If we get here, reentrancy succeeded (this should not happen)
            reentrancyAttempts++;
            console2.log("REENTRANCY SUCCESS: This should not happen!");
        } catch {
            console2.log("Reentrancy guard is working correctly");
        }
    }
    
    // Helper to approve tokens for hook
    function approveHook(address _hook, uint256 amount) external {
        require(msg.sender == owner, "Only owner");
        IERC20(token).approve(_hook, amount);
    }
    
    // Helper to approve tokens for pool manager
    function approvePoolManager(address _poolManager, uint256 amount) external {
        require(msg.sender == owner, "Only owner");
        IERC20(token).approve(_poolManager, amount);
    }
}

contract ConfluxRebateTests is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency currency0;
    Currency currency1;
    Currency feeToken;
    
    PoolKey poolKey;
    PoolKey poolKeyWithFeeToken;
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
        
        // Deploy fee-on-transfer token
        FeeOnTransferToken feeOnTransferToken = new FeeOnTransferToken("FeeToken", "FEE");
        feeToken = Currency.wrap(address(feeOnTransferToken));
        
        // Deploy mock Chainlink router
        functionsRouter = new MockFunctionsRouter();
        
        // Deploy TopOracle (testable version)
        bytes32 donId = keccak256("test-don");
        topOracle = new TestableTopOracle(address(functionsRouter), donId, address(0), address(0));
        functionsRouter.setTopOracle(address(topOracle));
        
        // Deploy DaemonRegistryModerated
        vm.prank(registryOwner);
        registry = new DaemonRegistryModerated();
        
        // Update TopOracle with registry address
        topOracle.setRegistry(address(registry));
        
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
        
        // Set hook authority
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
        
        // Deploy test daemons
        daemon1 = new TestDaemon(100e15, Currency.unwrap(currency0)); // 0.1 token rebate
        daemon2 = new TestDaemon(50e15, Currency.unwrap(currency0));  // 0.05 token rebate
        daemon3 = new TestDaemon(75e15, Currency.unwrap(currency0));  // 0.075 token rebate
        failingDaemon = new TestDaemon(200e15, Currency.unwrap(currency0)); // High rebate but will fail
        
        // Fund daemons
        deal(Currency.unwrap(currency0), address(daemon1), 10e18);
        deal(Currency.unwrap(currency0), address(daemon2), 10e18);
        deal(Currency.unwrap(currency0), address(daemon3), 10e18);
        deal(Currency.unwrap(currency0), address(failingDaemon), 10e18);
        
        // Daemons approve hook and pool manager
        daemon1.approveHook(address(hook), 10e18);
        daemon1.approvePoolManager(address(poolManager), 10e18);
        daemon2.approveHook(address(hook), 10e18);
        daemon2.approvePoolManager(address(poolManager), 10e18);
        daemon3.approveHook(address(hook), 10e18);
        daemon3.approvePoolManager(address(poolManager), 10e18);
        failingDaemon.approveHook(address(hook), 10e18);
        failingDaemon.approvePoolManager(address(poolManager), 10e18);
        
        // Register daemons
        address[] memory daemons = new address[](4);
        daemons[0] = address(daemon1);
        daemons[1] = address(daemon2);
        daemons[2] = address(daemon3);
        daemons[3] = address(failingDaemon);
        
        address[] memory owners = new address[](4);
        owners[0] = address(this);
        owners[1] = address(this);
        owners[2] = address(this);
        owners[3] = address(this);
        
        vm.prank(registryOwner);
        registry.addMany(daemons, owners);
        
        // Activate daemons
        registry.setActive(address(daemon1), true);
        registry.setActive(address(daemon2), true);
        registry.setActive(address(daemon3), true);
        registry.setActive(address(failingDaemon), true);
        
        // Setup TopOracle with initial epoch
        setupTopOracleEpoch();
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
        string memory source = "test-request";
        FunctionsRequest.Location secretsLocation = FunctionsRequest.Location.Inline;
        bytes memory encryptedSecretsReference = "";
        string[] memory args = new string[](0);
        bytes[] memory bytesArgs = new bytes[](0);
        uint64 subscriptionId = 1;
        uint32 callbackGasLimit = 300000;
        
        // First set the template
        topOracle.setRequestTemplate(source, secretsLocation, encryptedSecretsReference, args, bytesArgs, subscriptionId, callbackGasLimit);
        
        // Then start rebate epochs
        topOracle.startRebateEpochs(100); // epochDurationBlocks
        
        // Simulate Chainlink response with daemon1 as top
        uint256[8] memory topIds;
        topIds[0] = 0; // daemon1 has id 0
        topIds[1] = 0xffff; // End marker
        
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, topIds);
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

    // ===== CONDITION 1: EPOCHS DISABLED =====
    
    function testRebateCondition_EpochsDisabled() public {
        // Create a new TopOracle with epoch duration = 0 (disabled)
        bytes32 testDonId = keccak256("test-don-disabled");
        TestableTopOracle disabledTopOracle = new TestableTopOracle(
            address(functionsRouter),
            testDonId,
            address(registry),
            address(0)
        );
        
        console2.log("Created disabled TopOracle with epoch duration:", disabledTopOracle.epochDurationBlocks());
        
        // Deploy disabled hook
        address disabledFlags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | 
                Hooks.AFTER_INITIALIZE_FLAG | 
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4445 << 144)
        );
        
        bytes memory disabledConstructorArgs = abi.encode(
            poolManager, 
            address(disabledTopOracle), 
            address(registry), 
            Currency.unwrap(currency0)
        );
        deployCodeTo("ConfluxHook.sol:ConfluxHook", disabledConstructorArgs, disabledFlags);
        ConfluxHook disabledHook = ConfluxHook(disabledFlags);
        
        // Set hook authority
        disabledTopOracle.setHookAuthority(address(disabledHook));
        
        // Create pool with disabled hook
        PoolKey memory disabledPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: disabledHook
        });
        
        // Initialize pool
        poolManager.initialize(disabledPoolKey, Constants.SQRT_PRICE_1_1);
        
        // Add liquidity
        addLiquidityForPool(disabledPoolKey);
        
        // Verify epoch duration is 0
        assertEq(disabledTopOracle.epochDurationBlocks(), 0);
        console2.log("Epoch duration confirmed as 0 (disabled)");
        
        // Perform swap - should not have rebate
        uint256 swapAmount = 1e18;
        deal(Currency.unwrap(currency0), user, swapAmount);
        vm.prank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        
        uint256 daemon1BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        console2.log("Daemon1 balance before swap:", daemon1BalanceBefore);
        
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
        
        uint256 daemon1BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        console2.log("Daemon1 balance after swap:", daemon1BalanceAfter);
        console2.log("Daemon1 paid:", daemon1BalanceBefore - daemon1BalanceAfter);
        console2.log("Daemon1 job executed:", daemon1.jobExecuted());
        
        // Daemon should not pay anything when epochs are disabled
        assertEq(daemon1BalanceBefore, daemon1BalanceAfter);
        
        // Job should not be executed when epochs are disabled
        assertFalse(daemon1.jobExecuted(), "Job should not be executed when epochs are disabled");
    }

    // ===== CONDITION 2: NO TOP DAEMONS =====
    
    function testRebateCondition_NoTopDaemons() public {
        // Update top oracle with empty top list
        uint256[8] memory emptyTopIds;
        emptyTopIds[0] = 0xffff; // End marker immediately
        
        console2.log("Setting up empty top daemon list...");
        topOracle.refreshTopNow();
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, emptyTopIds);
        
        // Verify no top daemons
        assertEq(topOracle.topCount(), 0);
        console2.log("Top count confirmed as 0 (no top daemons)");
        
        // Perform swap - should not have rebate
        uint256 swapAmount = 1e18;
        uint256 daemon1BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        console2.log("Daemon1 balance before swap:", daemon1BalanceBefore);
        
        performSwap(swapAmount, true);
        
        uint256 daemon1BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        console2.log("Daemon1 balance after swap:", daemon1BalanceAfter);
        console2.log("Daemon1 paid:", daemon1BalanceBefore - daemon1BalanceAfter);
        console2.log("Daemon1 job executed:", daemon1.jobExecuted());
        
        // Daemon should not pay anything when no top daemons
        assertEq(daemon1BalanceBefore, daemon1BalanceAfter);
        
        // Job should not be executed when no top daemons
        assertFalse(daemon1.jobExecuted(), "Job should not be executed when no top daemons");
    }

    // ===== CONDITION 3: ALL DAEMONS EXHAUSTED IN EPOCH =====
    
    function testRebateCondition_AllDaemonsExhausted() public {
        // Set up multiple daemons in top - pack daemon1 (id=0) in slot 0, daemon2 (id=1) in slot 1, 0xffff in slot 2
        uint256[8] memory topIds;
        topIds[0] = 0 | (1 << 16) | (0xffff << 32);
        
        console2.log("Setting up top daemons: daemon1 and daemon2");
        topOracle.refreshTopNow();
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, topIds);
        
        console2.log("Top count:", topOracle.topCount());
        console2.log("Current top:", topOracle.getCurrentTop());
        
        // First swap - daemon1 pays
        console2.log("\n--- SWAP 1: daemon1 should pay ---");
        uint256 swapAmount = 1e18;
        deal(Currency.unwrap(currency0), user, swapAmount * 3);
        vm.prank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount * 3);
        
        uint256 daemon1BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        uint256 daemon2BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        console2.log("Daemon1 balance before:", daemon1BalanceBefore);
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
        
        uint256 daemon1BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        uint256 daemon2BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        console2.log("Daemon1 balance after:", daemon1BalanceAfter);
        console2.log("Daemon2 balance after:", daemon2BalanceAfter);
        console2.log("Daemon1 paid:", daemon1BalanceBefore - daemon1BalanceAfter);
        console2.log("Daemon2 paid:", daemon2BalanceBefore - daemon2BalanceAfter);
        
        assertGt(daemon1BalanceBefore - daemon1BalanceAfter, 0, "Daemon1 should pay first");
        
        // Second swap - daemon2 pays
        console2.log("\n--- SWAP 2: daemon2 should pay ---");
        uint256 daemon2BalanceBefore2 = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        console2.log("Daemon2 balance before:", daemon2BalanceBefore2);
        
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
        
        uint256 daemon2BalanceAfter2 = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        console2.log("Daemon2 balance after:", daemon2BalanceAfter2);
        console2.log("Daemon2 paid:", daemon2BalanceBefore2 - daemon2BalanceAfter2);
        
        assertGt(daemon2BalanceBefore2 - daemon2BalanceAfter2, 0, "Daemon2 should pay second");
        
        // Third swap - no rebate (all daemons exhausted)
        console2.log("\n--- SWAP 3: no rebate (all daemons exhausted) ---");
        uint256 daemon1BalanceBefore3 = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        uint256 daemon2BalanceBefore3 = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        console2.log("Daemon1 balance before:", daemon1BalanceBefore3);
        console2.log("Daemon2 balance before:", daemon2BalanceBefore3);
        
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
        
        uint256 daemon1BalanceAfter3 = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        uint256 daemon2BalanceAfter3 = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        console2.log("Daemon1 balance after:", daemon1BalanceAfter3);
        console2.log("Daemon2 balance after:", daemon2BalanceAfter3);
        console2.log("Daemon1 paid:", daemon1BalanceBefore3 - daemon1BalanceAfter3);
        console2.log("Daemon2 paid:", daemon2BalanceBefore3 - daemon2BalanceAfter3);
        
        // No daemon should pay - all exhausted
        assertEq(daemon1BalanceBefore3, daemon1BalanceAfter3, "Daemon1 should not pay - exhausted");
        assertEq(daemon2BalanceBefore3, daemon2BalanceAfter3, "Daemon2 should not pay - exhausted");
    }

    // ===== CONDITION 4: BANNED DAEMON =====
    
    function testRebateCondition_BannedDaemon() public {
        // Ban daemon1
        console2.log("Banning daemon1...");
        vm.prank(registryOwner);
        registry.banDaemon(address(daemon1));
        
        assertTrue(registry.banned(address(daemon1)));
        assertFalse(registry.active(address(daemon1)));
        console2.log("Daemon1 is banned and inactive");
        console2.log("Daemon1 banned status:", registry.banned(address(daemon1)));
        console2.log("Daemon1 active status:", registry.active(address(daemon1)));
        
        // Perform swap - should skip banned daemon
        console2.log("\nPerforming swap with banned daemon...");
        uint256 swapAmount = 1e18;
        uint256 daemon1BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        console2.log("Daemon1 balance before swap:", daemon1BalanceBefore);
        
        performSwap(swapAmount, true);
        
        uint256 daemon1BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        console2.log("Daemon1 balance after swap:", daemon1BalanceAfter);
        console2.log("Daemon1 paid:", daemon1BalanceBefore - daemon1BalanceAfter);
        console2.log("Daemon1 job executed:", daemon1.jobExecuted());
        
        // Banned daemon should not pay
        assertEq(daemon1BalanceBefore, daemon1BalanceAfter, "Banned daemon should not pay");
        
        // Job should not be executed for banned daemon
        assertFalse(daemon1.jobExecuted(), "Job should not be executed for banned daemon");
    }

    // ===== CONDITION 5: POOL DOES NOT CONTAIN REBATE TOKEN =====
    
    function testRebateCondition_PoolWithoutRebateToken() public {
        // The hook now prevents pools from being initialized if they don't contain the rebate token
        // This is a much better approach than trying to handle it gracefully during swaps
        
        console2.log("Creating pool key without rebate token...");
        // Create a pool key that doesn't contain the rebate token
        // Ensure currencies are in correct order (currency0 < currency1)
        address token0Addr = Currency.unwrap(currency1);
        address token1Addr = Currency.unwrap(feeToken);
        
        if (token0Addr > token1Addr) {
            (token0Addr, token1Addr) = (token1Addr, token0Addr);
        }
        
        console2.log("Token0 address:", token0Addr);
        console2.log("Token1 address:", token1Addr);
        console2.log("Rebate token address:", Currency.unwrap(currency0));
        
        PoolKey memory testKey = PoolKey({
            currency0: Currency.wrap(token0Addr),  // Not the rebate token
            currency1: Currency.wrap(token1Addr),  // Also not the rebate token  
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        
        // Pool initialization should fail because it doesn't contain the rebate token
        console2.log("Attempting to initialize pool without rebate token...");
        vm.prank(poolOwner);
        vm.expectRevert(); // Any revert is fine, we just want to ensure it fails
        poolManager.initialize(testKey, Constants.SQRT_PRICE_1_1);
        
        console2.log("Pool initialization failed as expected - pool does not contain rebate token");
    }

    // ===== CONDITION 6: REBATE DISABLED ON POOL =====
    
    function testRebateCondition_RebateDisabledOnPool() public {
        // Disable rebate on pool
        console2.log("Disabling rebate on pool...");
        vm.prank(poolOwner);
        hook.toggleRebate(poolKey);
        
        assertFalse(hook.getRebateState(poolKey));
        console2.log("Rebate disabled on pool");
        console2.log("Pool rebate state:", hook.getRebateState(poolKey));
        
        // Perform swap - should not have rebate
        console2.log("\nPerforming swap with rebate disabled...");
        uint256 swapAmount = 1e18;
        uint256 daemon1BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        console2.log("Daemon1 balance before swap:", daemon1BalanceBefore);
        
        performSwap(swapAmount, true);
        
        uint256 daemon1BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        console2.log("Daemon1 balance after swap:", daemon1BalanceAfter);
        console2.log("Daemon1 paid:", daemon1BalanceBefore - daemon1BalanceAfter);
        console2.log("Daemon1 job executed:", daemon1.jobExecuted());
        
        // Daemon should not pay when rebate is disabled on pool
        assertEq(daemon1BalanceBefore, daemon1BalanceAfter, "Daemon should not pay - rebate disabled");
        
        // Job should not be executed when rebate is disabled on pool
        assertFalse(daemon1.jobExecuted(), "Job should not be executed when rebate is disabled on pool");
    }

    // ===== CONDITION 7: DAEMON REBATE AMOUNT CALL FAILS =====
    
    function testRebateCondition_DaemonRebateAmountFails() public {
        // Set daemon to revert on getRebateAmount call
        console2.log("Setting failingDaemon to revert on getRebateAmount call...");
        failingDaemon.setShouldRevertOnRebate(true);
        
        // Update top to failing daemon
        uint256[8] memory topIds;
        topIds[0] = 3; // failingDaemon has id 3
        topIds[1] = 0xffff;
        
        console2.log("Setting failingDaemon as top daemon...");
        topOracle.refreshTopNow();
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, topIds);
        
        console2.log("Current top:", topOracle.getCurrentTop());
        console2.log("FailingDaemon active before swap:", registry.active(address(failingDaemon)));
        
        // Perform swap - should disable daemon and not pay
        console2.log("\nPerforming swap with failing daemon...");
        uint256 swapAmount = 1e18;
        uint256 failingDaemonBalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(failingDaemon));
        console2.log("FailingDaemon balance before swap:", failingDaemonBalanceBefore);
        
        performSwap(swapAmount, true);
        
        uint256 failingDaemonBalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(failingDaemon));
        console2.log("FailingDaemon balance after swap:", failingDaemonBalanceAfter);
        console2.log("FailingDaemon paid:", failingDaemonBalanceBefore - failingDaemonBalanceAfter);
        console2.log("FailingDaemon active after swap:", registry.active(address(failingDaemon)));
        console2.log("FailingDaemon job executed:", failingDaemon.jobExecuted());
        
        // Daemon should not pay and should be deactivated
        assertEq(failingDaemonBalanceBefore, failingDaemonBalanceAfter, "Daemon should not pay - call failed");
        assertFalse(registry.active(address(failingDaemon)), "Daemon should be deactivated");
        
        // Job should not be executed when rebate amount call fails
        assertFalse(failingDaemon.jobExecuted(), "Job should not be executed when rebate amount call fails");
    }

    // ===== CONDITION 8: DAEMON RETURNS INVALID DATA =====
    
    function testRebateCondition_DaemonReturnsInvalidData() public {
        // Set daemon to return invalid data
        console2.log("Setting failingDaemon to return invalid data...");
        failingDaemon.setShouldReturnInvalidData(true);
        
        // Update top to failing daemon
        uint256[8] memory topIds;
        topIds[0] = 3; // failingDaemon has id 3
        topIds[1] = 0xffff;
        
        console2.log("Setting failingDaemon as top daemon...");
        topOracle.refreshTopNow();
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, topIds);
        
        console2.log("Current top:", topOracle.getCurrentTop());
        console2.log("FailingDaemon active before swap:", registry.active(address(failingDaemon)));
        
        // Perform swap - should disable daemon and not pay
        console2.log("\nPerforming swap with daemon returning invalid data...");
        uint256 swapAmount = 1e18;
        uint256 failingDaemonBalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(failingDaemon));
        console2.log("FailingDaemon balance before swap:", failingDaemonBalanceBefore);
        
        performSwap(swapAmount, true);
        
        uint256 failingDaemonBalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(failingDaemon));
        console2.log("FailingDaemon balance after swap:", failingDaemonBalanceAfter);
        console2.log("FailingDaemon paid:", failingDaemonBalanceBefore - failingDaemonBalanceAfter);
        console2.log("FailingDaemon active after swap:", registry.active(address(failingDaemon)));
        
        // Daemon should not pay and should be deactivated
        assertEq(failingDaemonBalanceBefore, failingDaemonBalanceAfter, "Daemon should not pay - invalid data");
        assertFalse(registry.active(address(failingDaemon)), "Daemon should be deactivated");
    }

    // ===== CONDITION 9: DAEMON RETURNS ZERO OR NEGATIVE REBATE =====
    
    function testRebateCondition_ZeroRebateAmount() public {
        // Create a new daemon with 0 rebate amount
        TestDaemon zeroRebateDaemon = new TestDaemon(0, Currency.unwrap(currency0));
        deal(Currency.unwrap(currency0), address(zeroRebateDaemon), 10e18);
        zeroRebateDaemon.approveHook(address(hook), 10e18);
        zeroRebateDaemon.approvePoolManager(address(poolManager), 10e18);
        
        // Register and activate daemon
        vm.prank(registryOwner);
        registry.add(address(zeroRebateDaemon), address(this));
        registry.setActive(address(zeroRebateDaemon), true);
        
        // Update top to zero rebate daemon
        uint256[8] memory topIds;
        topIds[0] = 4; // zeroRebateDaemon has id 4
        topIds[1] = 0xffff;
        
        console2.log("Setting zeroRebateDaemon (with 0 rebate) as top daemon...");
        topOracle.refreshTopNow();
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, topIds);
        
        console2.log("Current top:", topOracle.getCurrentTop());
        console2.log("ZeroRebateDaemon active:", registry.active(address(zeroRebateDaemon)));
        console2.log("ZeroRebateDaemon rebate amount:", zeroRebateDaemon.getRebateAmount(block.number));
        
        // Perform swap - should skip daemon with 0 rebate
        console2.log("\nPerforming swap with daemon having 0 rebate...");
        uint256 swapAmount = 1e18;
        uint256 zeroRebateDaemonBalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(zeroRebateDaemon));
        console2.log("ZeroRebateDaemon balance before swap:", zeroRebateDaemonBalanceBefore);
        
        performSwap(swapAmount, true);
        
        uint256 zeroRebateDaemonBalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(zeroRebateDaemon));
        console2.log("ZeroRebateDaemon balance after swap:", zeroRebateDaemonBalanceAfter);
        console2.log("ZeroRebateDaemon paid:", zeroRebateDaemonBalanceBefore - zeroRebateDaemonBalanceAfter);
        console2.log("ZeroRebateDaemon job executed:", zeroRebateDaemon.jobExecuted());
        
        // Daemon with 0 rebate should not pay
        assertEq(zeroRebateDaemonBalanceBefore, zeroRebateDaemonBalanceAfter, "Daemon with 0 rebate should not pay");
        
        // Job should not be executed if daemon has 0 rebate
        assertFalse(zeroRebateDaemon.jobExecuted(), "Job should not be executed for daemon with 0 rebate");
    }

    // ===== CONDITION 10: TRANSFER FAILS =====
    
    function testRebateCondition_TransferFails() public {
        // Set daemon rebate amount to more than it has approved
        console2.log("Setting failingDaemon rebate amount to more than approved...");
        failingDaemon.setRebateAmount(20e18); // More than funded amount
        
        console2.log("FailingDaemon rebate amount:", failingDaemon.getRebateAmount(block.number));
        console2.log("FailingDaemon balance:", IERC20(Currency.unwrap(currency0)).balanceOf(address(failingDaemon)));
        
        // Update top to failing daemon
        uint256[8] memory topIds;
        topIds[0] = 3; // failingDaemon has id 3
        topIds[1] = 0xffff;
        
        console2.log("Setting failingDaemon as top daemon...");
        topOracle.refreshTopNow();
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, topIds);
        
        console2.log("Current top:", topOracle.getCurrentTop());
        console2.log("FailingDaemon active before swap:", registry.active(address(failingDaemon)));
        
        // Perform swap - should disable daemon and not pay
        console2.log("\nPerforming swap with daemon having insufficient balance...");
        uint256 swapAmount = 1e18;
        uint256 failingDaemonBalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(failingDaemon));
        console2.log("FailingDaemon balance before swap:", failingDaemonBalanceBefore);
        
        performSwap(swapAmount, true);
        
        uint256 failingDaemonBalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(failingDaemon));
        console2.log("FailingDaemon balance after swap:", failingDaemonBalanceAfter);
        console2.log("FailingDaemon paid:", failingDaemonBalanceBefore - failingDaemonBalanceAfter);
        console2.log("FailingDaemon active after swap:", registry.active(address(failingDaemon)));
        console2.log("FailingDaemon job executed:", failingDaemon.jobExecuted());
        
        // Daemon should not pay and should be deactivated
        assertEq(failingDaemonBalanceBefore, failingDaemonBalanceAfter, "Daemon should not pay - transfer failed");
        assertFalse(registry.active(address(failingDaemon)), "Daemon should be deactivated");
        
        // Job should not be executed when transfer fails
        assertFalse(failingDaemon.jobExecuted(), "Job should not be executed when transfer fails");
    }

    // ===== CONDITION 11: FEE-ON-TRANSFER TOKEN =====
    
    function testRebateCondition_FeeOnTransferToken() public {

        
        // The fee-on-transfer protection is already tested in testRebateCondition_TransferFails
        // where we test that when a daemon pays less than expected (including due to fee-on-transfer),
        // it gets disabled. This test would be redundant and causes v4 internal issues.

        // AND ALSO UNIV4 DOES NOT SUPPORT FEE-ON-TRANSFER TOKENS
        
        // Skip this test as it's covered by the TransferFails test
        vm.skip(true);
    }

    // ===== CONDITION 12: SUCCESSFUL REBATE =====
    
    function testRebateCondition_SuccessfulRebate() public {
        // Perform swap - should have successful rebate
        console2.log("Performing swap with successful rebate...");
        uint256 swapAmount = 1e18;
        
        // Track all balances
        uint256 userBalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 poolBalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 daemon1BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        
        console2.log("User balance before swap:", userBalanceBefore);
        console2.log("Pool balance before swap:", poolBalanceBefore);
        console2.log("Daemon1 balance before swap:", daemon1BalanceBefore);
        console2.log("Daemon1 active:", registry.active(address(daemon1)));
        console2.log("Current top:", topOracle.getCurrentTop());
        
        performSwap(swapAmount, true);
        
        uint256 userBalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 poolBalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 daemon1BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        
        console2.log("User balance after swap:", userBalanceAfter);
        console2.log("Pool balance after swap:", poolBalanceAfter);
        console2.log("Daemon1 balance after swap:", daemon1BalanceAfter);
        console2.log("Daemon1 paid:", daemon1BalanceBefore - daemon1BalanceAfter);
        console2.log("Daemon1 job executed:", daemon1.jobExecuted());
        
        // Daemon should pay rebate
        assertGt(daemon1BalanceBefore - daemon1BalanceAfter, 0, "Daemon should pay rebate");
        
        // Daemon job should be executed
        assertTrue(daemon1.jobExecuted(), "Daemon job should be executed");
    }

    // ===== CONDITION 13: REBATE DIRECTION TESTING =====
    
    function testRebateCondition_RebateDirection_ZeroForOne() public {
        // Test rebate when swapping token0 -> token1 (rebateToken is token0)
        console2.log("Testing rebate direction: Token0 -> Token1 (rebateToken is Token0)");
        uint256 swapAmount = 1e18;
        
        // Track all balances
        uint256 userBalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 poolBalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 daemon1BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        
        console2.log("User Token0 balance before swap:", userBalanceBefore);
        console2.log("Pool Token0 balance before swap:", poolBalanceBefore);
        console2.log("Daemon1 Token0 balance before swap:", daemon1BalanceBefore);
        
        performSwap(swapAmount, true); // zeroForOne = true
        
        uint256 userBalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 poolBalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 daemon1BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        
        console2.log("User Token0 balance after swap:", userBalanceAfter);
        console2.log("Pool Token0 balance after swap:", poolBalanceAfter);
        console2.log("Daemon1 Token0 balance after swap:", daemon1BalanceAfter);
        console2.log("Daemon1 paid in Token0:", daemon1BalanceBefore - daemon1BalanceAfter);
        
        // Daemon should pay rebate in token0
        assertGt(daemon1BalanceBefore - daemon1BalanceAfter, 0, "Daemon should pay rebate in token0");
    }
    
    function testRebateCondition_RebateDirection_OneForZero() public {
        // Test rebate when swapping token1 -> token0 (rebateToken is token0)
        console2.log("Testing rebate direction: Token1 -> Token0 (rebateToken is Token0)");
        uint256 swapAmount = 1e18;
        
        // Track all balances
        uint256 userBalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 poolBalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 daemon1BalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        
        console2.log("User Token0 balance before swap:", userBalanceBefore);
        console2.log("Pool Token0 balance before swap:", poolBalanceBefore);
        console2.log("Daemon1 Token0 balance before swap:", daemon1BalanceBefore);
        
        performSwap(swapAmount, false); // zeroForOne = false
        
        uint256 userBalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(user);
        uint256 poolBalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        uint256 daemon1BalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        
        console2.log("User Token0 balance after swap:", userBalanceAfter);
        console2.log("Pool Token0 balance after swap:", poolBalanceAfter);
        console2.log("Daemon1 Token0 balance after swap:", daemon1BalanceAfter);
        console2.log("Daemon1 paid in Token0:", daemon1BalanceBefore - daemon1BalanceAfter);
        
        // Daemon should pay rebate in token0
        assertGt(daemon1BalanceBefore - daemon1BalanceAfter, 0, "Daemon should pay rebate in token0");
    }

    // ===== CONDITION 14: DAEMON JOB FAILS =====
    
    function testRebateCondition_DaemonJobFails() public {
        // Create a new daemon that fails only on job execution, not on getRebateAmount
        TestDaemon jobFailingDaemon = new TestDaemon(100e15, Currency.unwrap(currency0));
        deal(Currency.unwrap(currency0), address(jobFailingDaemon), 10e18);
        jobFailingDaemon.approveHook(address(hook), 10e18);
        jobFailingDaemon.approvePoolManager(address(poolManager), 10e18);
        
        // Register and activate daemon
        vm.prank(registryOwner);
        registry.add(address(jobFailingDaemon), address(this));
        registry.setActive(address(jobFailingDaemon), true);
        
        // Set daemon to fail only on job execution (not on getRebateAmount)
        console2.log("Setting jobFailingDaemon to revert on job execution...");
        jobFailingDaemon.setShouldRevertOnJob(true);
        
        // Update top to job failing daemon
        uint256[8] memory topIds;
        topIds[0] = 4; // jobFailingDaemon has id 4
        topIds[1] = 0xffff;
        
        console2.log("Setting jobFailingDaemon as top daemon...");
        topOracle.refreshTopNow();
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, topIds);
        
        console2.log("Current top:", topOracle.getCurrentTop());
        console2.log("JobFailingDaemon active before swap:", registry.active(address(jobFailingDaemon)));
        
        // Perform swap - daemon should still pay rebate but job should fail
        console2.log("\nPerforming swap with job failing daemon...");
        uint256 swapAmount = 1e18;
        uint256 jobFailingDaemonBalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(jobFailingDaemon));
        console2.log("JobFailingDaemon balance before swap:", jobFailingDaemonBalanceBefore);
        
        performSwap(swapAmount, true);
        
        uint256 jobFailingDaemonBalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(jobFailingDaemon));
        console2.log("JobFailingDaemon balance after swap:", jobFailingDaemonBalanceAfter);
        console2.log("JobFailingDaemon paid:", jobFailingDaemonBalanceBefore - jobFailingDaemonBalanceAfter);
        console2.log("JobFailingDaemon job executed:", jobFailingDaemon.jobExecuted());
        
        // Daemon should still pay rebate even if job fails
        assertGt(jobFailingDaemonBalanceBefore - jobFailingDaemonBalanceAfter, 0, "Daemon should pay rebate even if job fails");
        
        // Job should not be executed (should revert)
        assertFalse(jobFailingDaemon.jobExecuted(), "Job should not be executed due to revert");
    }

    // ===== CONDITION 15: REENTRANCY ATTACK =====
    
    function testRebateCondition_ReentrancyAttack() public {
        // Create a malicious daemon that tries to re-enter during job execution
        MaliciousReentrantDaemon maliciousDaemon = new MaliciousReentrantDaemon(100e15, Currency.unwrap(currency0), address(poolManager), poolKey);
        deal(Currency.unwrap(currency0), address(maliciousDaemon), 10e18);
        maliciousDaemon.approveHook(address(hook), 10e18);
        maliciousDaemon.approvePoolManager(address(poolManager), 10e18);
        
        // Register and activate malicious daemon
        vm.prank(registryOwner);
        registry.add(address(maliciousDaemon), address(this));
        registry.setActive(address(maliciousDaemon), true);
        
        // Update top to malicious daemon
        uint256[8] memory topIds;
        topIds[0] = 4; // maliciousDaemon has id 4
        topIds[1] = 0xffff;
        
        console2.log("Setting maliciousDaemon as top daemon...");
        topOracle.refreshTopNow();
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, topIds);
        
        console2.log("Current top:", topOracle.getCurrentTop());
        console2.log("MaliciousDaemon active before swap:", registry.active(address(maliciousDaemon)));
        
        // Perform swap - should be protected by reentrancy guard
        console2.log("\nPerforming swap with malicious reentrant daemon...");
        uint256 swapAmount = 1e18;
        uint256 maliciousDaemonBalanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(maliciousDaemon));
        console2.log("MaliciousDaemon balance before swap:", maliciousDaemonBalanceBefore);
        
        // The swap should succeed despite the reentrancy attempt
        performSwap(swapAmount, true);
        
        uint256 maliciousDaemonBalanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(maliciousDaemon));
        console2.log("MaliciousDaemon balance after swap:", maliciousDaemonBalanceAfter);
        console2.log("MaliciousDaemon paid:", maliciousDaemonBalanceBefore - maliciousDaemonBalanceAfter);
        console2.log("MaliciousDaemon job executed:", maliciousDaemon.jobExecuted());
        console2.log("MaliciousDaemon reentrancy attempts:", maliciousDaemon.reentrancyAttempts());
        
        // Daemon should still pay rebate (reentrancy guard prevents double execution)
        assertGt(maliciousDaemonBalanceBefore - maliciousDaemonBalanceAfter, 0, "Daemon should pay rebate");
        
        // Job should be executed only once (reentrancy guard prevents re-entry)
        assertTrue(maliciousDaemon.jobExecuted(), "Job should be executed");
        
        // CRITICAL: reentrancyAttempts should be exactly 1, meaning:
        // - Initial call to accomplishDaemonJob() = 1
        // - Reentrancy attempt should be blocked, so it stays at 1
        // If it's 2, then reentrancy succeeded (BAD!)
        // If it's 1, then reentrancy was blocked (GOOD!)
        assertEq(maliciousDaemon.reentrancyAttempts(), 1, "REENTRANCY VULNERABILITY: reentrancyAttempts should be 1, not 2. If it's 2, reentrancy succeeded!");
        
        console2.log("=== REENTRANCY PROTECTION VERIFICATION ===");
        console2.log("reentrancyAttempts =", maliciousDaemon.reentrancyAttempts());
        if (maliciousDaemon.reentrancyAttempts() == 1) {
            console2.log(" REENTRANCY PROTECTION: WORKING - Only 1 attempt recorded");
        } else {
            console2.log(" REENTRANCY VULNERABILITY: FAILED - Multiple attempts recorded");
        }
    }

    // ===== MULTI-EPOCH TESTING =====
    
    function testMultiEpochSwaps_10SwapsAcross3Epochs() public {
        console2.log("=== MULTI-EPOCH TEST: 10 SWAPS ACROSS 3 EPOCHS ===");
        
        // Set epoch length to 50 blocks
        topOracle.setEpochDuration(50);
        console2.log("Epoch duration set to 50 blocks");
        console2.log("Current epoch duration:", topOracle.epochDurationBlocks());
        
        // Start from block 1
        vm.roll(1);
        console2.log("Starting from block:", block.number);
        
        // Track daemon balances and payments across epochs
        uint256[4] memory daemonBalancesBefore; // daemon1, daemon2, daemon3, failingDaemon
        uint256[4] memory daemonPayments; // Track total payments per daemon
        
        // Initialize daemon balances
        daemonBalancesBefore[0] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        daemonBalancesBefore[1] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        daemonBalancesBefore[2] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon3));
        daemonBalancesBefore[3] = IERC20(Currency.unwrap(currency0)).balanceOf(address(failingDaemon));
        
        console2.log("Initial daemon balances:");
        console2.log("  Daemon1:", daemonBalancesBefore[0]);
        console2.log("  Daemon2:", daemonBalancesBefore[1]);
        console2.log("  Daemon3:", daemonBalancesBefore[2]);
        console2.log("  FailingDaemon:", daemonBalancesBefore[3]);
        
        // EPOCH 1: daemon1 and daemon2 in top
        console2.log("\n--- EPOCH 1: daemon1 and daemon2 ---");
        uint256[8] memory epoch1TopIds;
        epoch1TopIds[0] = 0 | (1 << 16) | (0xffff << 32); // daemon1 (id=0) and daemon2 (id=1)
        
        // Use the existing epoch from setup, just update the top daemons
        bytes32 requestId1 = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId1, epoch1TopIds);
        
        console2.log("Epoch 1 top count:", topOracle.topCount());
        console2.log("Epoch 1 current top:", topOracle.getCurrentTop());
        
        // Swaps 1-4 in Epoch 1
        for (uint256 i = 1; i <= 4; i++) {
            console2.log("\n--- SWAP", i, "in EPOCH 1 ---");
            console2.log("Block before swap:", block.number);
            console2.log("Has pending top request before swap:", topOracle.hasPendingTopRequest());
            
            uint256 swapAmount = 1e18;
            deal(Currency.unwrap(currency0), user, swapAmount * 10); // Fund for all swaps
            vm.prank(user);
            IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount * 10);
            
            uint256 daemon1Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
            uint256 daemon2Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
            
            console2.log("  Top count before swap:", topOracle.topCount());
            console2.log("  Current top before swap:", topOracle.getCurrentTop());
            console2.log("  Daemon1 active:", registry.active(address(daemon1)));
            console2.log("  Daemon2 active:", registry.active(address(daemon2)));
            
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
            
            uint256 daemon1After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
            uint256 daemon2After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
            
            uint256 daemon1Paid = daemon1Before - daemon1After;
            uint256 daemon2Paid = daemon2Before - daemon2After;
            
            console2.log("  Daemon1 paid:", daemon1Paid);
            console2.log("  Daemon2 paid:", daemon2Paid);
            console2.log("  Current top after swap:", topOracle.getCurrentTop());
            console2.log("Has pending top request after swap:", topOracle.hasPendingTopRequest());
            
            daemonPayments[0] += daemon1Paid;
            daemonPayments[1] += daemon2Paid;
            
            // Move to next block (20 blocks between swaps)
            vm.roll(block.number + 20);
        }
        
        // Transition to EPOCH 2: daemon2 and daemon3 in top
        console2.log("\n--- TRANSITION TO EPOCH 2: daemon2 and daemon3 ---");
        console2.log("Current epoch before transition:", topOracle.topEpoch());
        console2.log("Current block before transition:", block.number);
        
        // Move to epoch expiration (50 blocks from start)
        vm.roll(block.number + 10); // Move to block 81 (1 + 4*20 = 81, need 50 for epoch)
        console2.log("Block after roll to epoch expiration:", block.number);
        
        // Check if there's a pending request and fulfill it
        if (topOracle.hasPendingTopRequest()) {
            console2.log("Fulfilling pending top request for epoch 2...");
            uint256[8] memory epoch2TopIds;
            epoch2TopIds[0] = 1 | (2 << 16) | (0xffff << 32); // daemon2 (id=1) and daemon3 (id=2)
            
            bytes32 requestId2 = topOracle.lastRequestId();
            topOracle.testFulfillRequest(requestId2, epoch2TopIds);
        } else {
            console2.log("No pending request, manually updating top for epoch 2...");
            topOracle.refreshTopNow();
            bytes32 requestId2 = topOracle.lastRequestId();
            uint256[8] memory epoch2TopIds;
            epoch2TopIds[0] = 1 | (2 << 16) | (0xffff << 32); // daemon2 (id=1) and daemon3 (id=2)
            topOracle.testFulfillRequest(requestId2, epoch2TopIds);
        }
        
        console2.log("Epoch 2 top count:", topOracle.topCount());
        console2.log("Epoch 2 current top:", topOracle.getCurrentTop());
        console2.log("Epoch number after transition:", topOracle.topEpoch());
        
        // Swaps 5-7 in Epoch 2
        for (uint256 i = 5; i <= 7; i++) {
            console2.log("\n--- SWAP", i, "in EPOCH 2 ---");
            console2.log("Block before swap:", block.number);
            console2.log("Has pending top request before swap:", topOracle.hasPendingTopRequest());
            
            uint256 swapAmount = 1e18;
            
            uint256 daemon2Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
            uint256 daemon3Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon3));
            
            console2.log("  Daemon2 active:", registry.active(address(daemon2)));
            console2.log("  Daemon3 active:", registry.active(address(daemon3)));
            console2.log("  Current top before swap:", topOracle.getCurrentTop());
            
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
            
            uint256 daemon2After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
            uint256 daemon3After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon3));
            
            uint256 daemon2Paid = daemon2Before - daemon2After;
            uint256 daemon3Paid = daemon3Before - daemon3After;
            
            console2.log("  Daemon2 paid:", daemon2Paid);
            console2.log("  Daemon3 paid:", daemon3Paid);
            console2.log("  Current top after swap:", topOracle.getCurrentTop());
            console2.log("Has pending top request after swap:", topOracle.hasPendingTopRequest());
            
            daemonPayments[1] += daemon2Paid;
            daemonPayments[2] += daemon3Paid;
            
            // Move to next block (20 blocks between swaps)
            vm.roll(block.number + 20);
        }
        
        // Transition to EPOCH 3: failingDaemon and daemon1 in top
        console2.log("\n--- TRANSITION TO EPOCH 3: failingDaemon and daemon1 ---");
        console2.log("Current epoch before transition:", topOracle.topEpoch());
        console2.log("Current block before transition:", block.number);
        
        // Move to next epoch expiration (50 blocks from previous epoch)
        vm.roll(block.number + 10); // Move to next epoch expiration
        console2.log("Block after roll to next epoch expiration:", block.number);
        
        // Check if there's a pending request and fulfill it
        if (topOracle.hasPendingTopRequest()) {
            console2.log("Fulfilling pending top request for epoch 3...");
            uint256[8] memory epoch3TopIds;
            epoch3TopIds[0] = 3 | (0 << 16) | (0xffff << 32); // failingDaemon (id=3) and daemon1 (id=0)
            
            bytes32 requestId3 = topOracle.lastRequestId();
            topOracle.testFulfillRequest(requestId3, epoch3TopIds);
        } else {
            console2.log("No pending request, manually updating top for epoch 3...");
            topOracle.refreshTopNow();
            bytes32 requestId3 = topOracle.lastRequestId();
            uint256[8] memory epoch3TopIds;
            epoch3TopIds[0] = 3 | (0 << 16) | (0xffff << 32); // failingDaemon (id=3) and daemon1 (id=0)
            topOracle.testFulfillRequest(requestId3, epoch3TopIds);
        }
        
        console2.log("Epoch 3 top count:", topOracle.topCount());
        console2.log("Epoch 3 current top:", topOracle.getCurrentTop());
        console2.log("Epoch number:", topOracle.topEpoch());
        
        // Swaps 8-10 in Epoch 3
        for (uint256 i = 8; i <= 10; i++) {
            console2.log("\n--- SWAP", i, "in EPOCH 3 ---");
            console2.log("Block before swap:", block.number);
            console2.log("Has pending top request before swap:", topOracle.hasPendingTopRequest());
            
            uint256 swapAmount = 1e18;
            
            uint256 failingDaemonBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(failingDaemon));
            uint256 daemon1Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
            
            console2.log("  FailingDaemon active:", registry.active(address(failingDaemon)));
            console2.log("  Daemon1 active:", registry.active(address(daemon1)));
            console2.log("  Current top before swap:", topOracle.getCurrentTop());
            
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
            
            uint256 failingDaemonAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(failingDaemon));
            uint256 daemon1After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
            
            uint256 failingDaemonPaid = failingDaemonBefore - failingDaemonAfter;
            uint256 daemon1Paid = daemon1Before - daemon1After;
            
            console2.log("  FailingDaemon paid:", failingDaemonPaid);
            console2.log("  Daemon1 paid:", daemon1Paid);
            console2.log("  Current top after swap:", topOracle.getCurrentTop());
            console2.log("Has pending top request after swap:", topOracle.hasPendingTopRequest());
            
            daemonPayments[3] += failingDaemonPaid;
            daemonPayments[0] += daemon1Paid;
            
            // Move to next block (20 blocks between swaps)
            // For the last swap (swap 10), move to epoch expiration
            if (i == 10) {
                console2.log("  Moving to epoch expiration for final swap...");
                vm.roll(block.number + 20); // Move to epoch expiration
                console2.log("  Block at epoch expiration:", block.number);
            } else {
                // Move to next block for other swaps
                vm.roll(block.number + 20);
            }
        }
        
        // Final verification
        console2.log("\n=== FINAL VERIFICATION ===");
        console2.log("Total payments across all epochs:");
        console2.log("  Daemon1 total paid:", daemonPayments[0]);
        console2.log("  Daemon2 total paid:", daemonPayments[1]);
        console2.log("  Daemon3 total paid:", daemonPayments[2]);
        console2.log("  FailingDaemon total paid:", daemonPayments[3]);
        
        // Verify epoch progression
        // We start at epoch 2 (from setup), then transition to epoch 3, then epoch 4
        assertEq(topOracle.topEpoch(), 4, "Should be in epoch 4 (started at 2, +2 transitions)");
        
        // Verify that daemons from different epochs paid rebates
        assertGt(daemonPayments[0], 0, "Daemon1 should have paid in epochs 1 and 3");
        assertGt(daemonPayments[1], 0, "Daemon2 should have paid in epochs 1 and 2");
        assertGt(daemonPayments[2], 0, "Daemon3 should have paid in epoch 2");
        assertGt(daemonPayments[3], 0, "FailingDaemon should have paid in epoch 3");
        
        // Verify daemon rotation within epochs
        // In epoch 1: daemon1 and daemon2 should have rotated
        // In epoch 2: daemon2 and daemon3 should have rotated  
        // In epoch 3: failingDaemon and daemon1 should have rotated
        
        // Check that we had multiple different daemons paying in each epoch
        // This is verified by the fact that we have payments from all 4 daemons
        // and the epoch transitions worked correctly

    }



    function testFullCycleFlow() public {

        // Set epoch length to 50 blocks
        topOracle.setEpochDuration(50);
        console2.log("Epoch duration set to 50 blocks");
        console2.log("Current epoch duration:", topOracle.epochDurationBlocks());

        // Start from block 1
        vm.roll(1);
        console2.log("Starting from block:", block.number);
        console2.log("Current top (should be empty):", topOracle.getCurrentTop());
        console2.log("Top count (should be 0):", topOracle.topCount());

        
        
        // // Track daemon balances and payments across epochs
        // uint256[4] memory daemonBalancesBefore; // daemon1, daemon2, daemon3, failingDaemon
        // uint256[4] memory daemonPayments; // Track total payments per daemon
        
        // // Initialize daemon balances
        // daemonBalancesBefore[0] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        // daemonBalancesBefore[1] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        // daemonBalancesBefore[2] = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon3));
        // daemonBalancesBefore[3] = IERC20(Currency.unwrap(currency0)).balanceOf(address(failingDaemon));
        
        // console2.log("Initial daemon balances:");
        // console2.log("  Daemon1:", daemonBalancesBefore[0]);
        // console2.log("  Daemon2:", daemonBalancesBefore[1]);
        // console2.log("  Daemon3:", daemonBalancesBefore[2]);
        // console2.log("  FailingDaemon:", daemonBalancesBefore[3]);
        
        // // EPOCH 1: daemon1 and daemon2 in top
        // console2.log("\n--- EPOCH 1: daemon1 and daemon2 ---");
        // uint256[8] memory epoch1TopIds;
        // epoch1TopIds[0] = 0 | (1 << 16) | (0xffff << 32); // daemon1 (id=0) and daemon2 (id=1)
        
        // // Use the existing epoch from setup, just update the top daemons
        // bytes32 requestId1 = topOracle.lastRequestId();
        // topOracle.testFulfillRequest(requestId1, epoch1TopIds);
        
        // console2.log("Epoch 1 top count:", topOracle.topCount());
        // console2.log("Epoch 1 current top:", topOracle.getCurrentTop());
        
        // // Swaps 1-4 in Epoch 1
        // for (uint256 i = 1; i <= 4; i++) {
        //     console2.log("\n--- SWAP", i, "in EPOCH 1 ---");
        //     console2.log("Block before swap:", block.number);
        //     console2.log("Has pending top request before swap:", topOracle.hasPendingTopRequest());
            
        //     uint256 swapAmount = 1e18;
        //     deal(Currency.unwrap(currency0), user, swapAmount * 10); // Fund for all swaps
        //     vm.prank(user);
        //     IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount * 10);
            
        //     uint256 daemon1Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        //     uint256 daemon2Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
            
        //     console2.log("  Top count before swap:", topOracle.topCount());
        //     console2.log("  Current top before swap:", topOracle.getCurrentTop());
        //     console2.log("  Daemon1 active:", registry.active(address(daemon1)));
        //     console2.log("  Daemon2 active:", registry.active(address(daemon2)));
            
        //     vm.prank(user);
        //     swapRouter.swapExactTokensForTokens({
        //         amountIn: swapAmount,
        //         amountOutMin: 0,
        //         zeroForOne: true,
        //         poolKey: poolKey,
        //         hookData: "",
        //         receiver: user,
        //         deadline: block.timestamp + 1
        //     });
            
        //     uint256 daemon1After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
        //     uint256 daemon2After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
            
        //     uint256 daemon1Paid = daemon1Before - daemon1After;
        //     uint256 daemon2Paid = daemon2Before - daemon2After;
            
        //     console2.log("  Daemon1 paid:", daemon1Paid);
        //     console2.log("  Daemon2 paid:", daemon2Paid);
        //     console2.log("  Current top after swap:", topOracle.getCurrentTop());
        //     console2.log("Has pending top request after swap:", topOracle.hasPendingTopRequest());
            
        //     daemonPayments[0] += daemon1Paid;
        //     daemonPayments[1] += daemon2Paid;
            
        //     // Move to next block (20 blocks between swaps)
        //     vm.roll(block.number + 20);
        // }
        
        // // Transition to EPOCH 2: daemon2 and daemon3 in top
        // console2.log("\n--- TRANSITION TO EPOCH 2: daemon2 and daemon3 ---");
        // console2.log("Current epoch before transition:", topOracle.topEpoch());
        // console2.log("Current block before transition:", block.number);
        
        // // Move to epoch expiration (50 blocks from start)
        // vm.roll(block.number + 10); // Move to block 81 (1 + 4*20 = 81, need 50 for epoch)
        // console2.log("Block after roll to epoch expiration:", block.number);
        
        // // Check if there's a pending request and fulfill it
        // if (topOracle.hasPendingTopRequest()) {
        //     console2.log("Fulfilling pending top request for epoch 2...");
        //     uint256[8] memory epoch2TopIds;
        //     epoch2TopIds[0] = 1 | (2 << 16) | (0xffff << 32); // daemon2 (id=1) and daemon3 (id=2)
            
        //     bytes32 requestId2 = topOracle.lastRequestId();
        //     topOracle.testFulfillRequest(requestId2, epoch2TopIds);
        // } else {
        //     console2.log("No pending request, manually updating top for epoch 2...");
        //     topOracle.refreshTopNow();
        //     bytes32 requestId2 = topOracle.lastRequestId();
        //     uint256[8] memory epoch2TopIds;
        //     epoch2TopIds[0] = 1 | (2 << 16) | (0xffff << 32); // daemon2 (id=1) and daemon3 (id=2)
        //     topOracle.testFulfillRequest(requestId2, epoch2TopIds);
        // }
        
        // console2.log("Epoch 2 top count:", topOracle.topCount());
        // console2.log("Epoch 2 current top:", topOracle.getCurrentTop());
        // console2.log("Epoch number after transition:", topOracle.topEpoch());
        
        // // Swaps 5-7 in Epoch 2
        // for (uint256 i = 5; i <= 7; i++) {
        //     console2.log("\n--- SWAP", i, "in EPOCH 2 ---");
        //     console2.log("Block before swap:", block.number);
        //     console2.log("Has pending top request before swap:", topOracle.hasPendingTopRequest());
            
        //     uint256 swapAmount = 1e18;
            
        //     uint256 daemon2Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        //     uint256 daemon3Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon3));
            
        //     console2.log("  Daemon2 active:", registry.active(address(daemon2)));
        //     console2.log("  Daemon3 active:", registry.active(address(daemon3)));
        //     console2.log("  Current top before swap:", topOracle.getCurrentTop());
            
        //     vm.prank(user);
        //     swapRouter.swapExactTokensForTokens({
        //         amountIn: swapAmount,
        //         amountOutMin: 0,
        //         zeroForOne: true,
        //         poolKey: poolKey,
        //         hookData: "",
        //         receiver: user,
        //         deadline: block.timestamp + 1
        //     });
            
        //     uint256 daemon2After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon2));
        //     uint256 daemon3After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon3));
            
        //     uint256 daemon2Paid = daemon2Before - daemon2After;
        //     uint256 daemon3Paid = daemon3Before - daemon3After;
            
        //     console2.log("  Daemon2 paid:", daemon2Paid);
        //     console2.log("  Daemon3 paid:", daemon3Paid);
        //     console2.log("  Current top after swap:", topOracle.getCurrentTop());
        //     console2.log("Has pending top request after swap:", topOracle.hasPendingTopRequest());
            
        //     daemonPayments[1] += daemon2Paid;
        //     daemonPayments[2] += daemon3Paid;
            
        //     // Move to next block (20 blocks between swaps)
        //     vm.roll(block.number + 20);
        // }
        
        // // Transition to EPOCH 3: failingDaemon and daemon1 in top
        // console2.log("\n--- TRANSITION TO EPOCH 3: failingDaemon and daemon1 ---");
        // console2.log("Current epoch before transition:", topOracle.topEpoch());
        // console2.log("Current block before transition:", block.number);
        
        // // Move to next epoch expiration (50 blocks from previous epoch)
        // vm.roll(block.number + 10); // Move to next epoch expiration
        // console2.log("Block after roll to next epoch expiration:", block.number);
        
        // // Check if there's a pending request and fulfill it
        // if (topOracle.hasPendingTopRequest()) {
        //     console2.log("Fulfilling pending top request for epoch 3...");
        //     uint256[8] memory epoch3TopIds;
        //     epoch3TopIds[0] = 3 | (0 << 16) | (0xffff << 32); // failingDaemon (id=3) and daemon1 (id=0)
            
        //     bytes32 requestId3 = topOracle.lastRequestId();
        //     topOracle.testFulfillRequest(requestId3, epoch3TopIds);
        // } else {
        //     console2.log("No pending request, manually updating top for epoch 3...");
        //     topOracle.refreshTopNow();
        //     bytes32 requestId3 = topOracle.lastRequestId();
        //     uint256[8] memory epoch3TopIds;
        //     epoch3TopIds[0] = 3 | (0 << 16) | (0xffff << 32); // failingDaemon (id=3) and daemon1 (id=0)
        //     topOracle.testFulfillRequest(requestId3, epoch3TopIds);
        // }
        
        // console2.log("Epoch 3 top count:", topOracle.topCount());
        // console2.log("Epoch 3 current top:", topOracle.getCurrentTop());
        // console2.log("Epoch number:", topOracle.topEpoch());
        
        // // Swaps 8-10 in Epoch 3
        // for (uint256 i = 8; i <= 10; i++) {
        //     console2.log("\n--- SWAP", i, "in EPOCH 3 ---");
        //     console2.log("Block before swap:", block.number);
        //     console2.log("Has pending top request before swap:", topOracle.hasPendingTopRequest());
            
        //     uint256 swapAmount = 1e18;
            
        //     uint256 failingDaemonBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(failingDaemon));
        //     uint256 daemon1Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
            
        //     console2.log("  FailingDaemon active:", registry.active(address(failingDaemon)));
        //     console2.log("  Daemon1 active:", registry.active(address(daemon1)));
        //     console2.log("  Current top before swap:", topOracle.getCurrentTop());
            
        //     vm.prank(user);
        //     swapRouter.swapExactTokensForTokens({
        //         amountIn: swapAmount,
        //         amountOutMin: 0,
        //         zeroForOne: true,
        //         poolKey: poolKey,
        //         hookData: "",
        //         receiver: user,
        //         deadline: block.timestamp + 1
        //     });
            
        //     uint256 failingDaemonAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(failingDaemon));
        //     uint256 daemon1After = IERC20(Currency.unwrap(currency0)).balanceOf(address(daemon1));
            
        //     uint256 failingDaemonPaid = failingDaemonBefore - failingDaemonAfter;
        //     uint256 daemon1Paid = daemon1Before - daemon1After;
            
        //     console2.log("  FailingDaemon paid:", failingDaemonPaid);
        //     console2.log("  Daemon1 paid:", daemon1Paid);
        //     console2.log("  Current top after swap:", topOracle.getCurrentTop());
        //     console2.log("Has pending top request after swap:", topOracle.hasPendingTopRequest());
            
        //     daemonPayments[3] += failingDaemonPaid;
        //     daemonPayments[0] += daemon1Paid;
            
        //     // Move to next block (20 blocks between swaps)
        //     // For the last swap (swap 10), move to epoch expiration
        //     if (i == 10) {
        //         console2.log("  Moving to epoch expiration for final swap...");
        //         vm.roll(block.number + 20); // Move to epoch expiration
        //         console2.log("  Block at epoch expiration:", block.number);
        //     } else {
        //         // Move to next block for other swaps
        //         vm.roll(block.number + 20);
        //     }
        // }
        
        // // Final verification
        // console2.log("\n=== FINAL VERIFICATION ===");
        // console2.log("Total payments across all epochs:");
        // console2.log("  Daemon1 total paid:", daemonPayments[0]);
        // console2.log("  Daemon2 total paid:", daemonPayments[1]);
        // console2.log("  Daemon3 total paid:", daemonPayments[2]);
        // console2.log("  FailingDaemon total paid:", daemonPayments[3]);
        
        // // Verify epoch progression
        // // We start at epoch 2 (from setup), then transition to epoch 3, then epoch 4
        // assertEq(topOracle.topEpoch(), 4, "Should be in epoch 4 (started at 2, +2 transitions)");
        
        // // Verify that daemons from different epochs paid rebates
        // assertGt(daemonPayments[0], 0, "Daemon1 should have paid in epochs 1 and 3");
        // assertGt(daemonPayments[1], 0, "Daemon2 should have paid in epochs 1 and 2");
        // assertGt(daemonPayments[2], 0, "Daemon3 should have paid in epoch 2");
        // assertGt(daemonPayments[3], 0, "FailingDaemon should have paid in epoch 3");
        
        // // Verify daemon rotation within epochs
        // // In epoch 1: daemon1 and daemon2 should have rotated
        // // In epoch 2: daemon2 and daemon3 should have rotated  
        // // In epoch 3: failingDaemon and daemon1 should have rotated
        
        // // Check that we had multiple different daemons paying in each epoch
        // // This is verified by the fact that we have payments from all 4 daemons
        // // and the epoch transitions worked correctly

    }

    // ===== HELPER FUNCTIONS =====
    
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
}

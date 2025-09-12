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
import {NotHookOwner, ZeroAddress, NotOwner, LengthMismatch, NotAuthorized, NotDaemonOwner, DaemonIsBanned} from "../src/base/Errors.sol";

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

contract ConfluxOwnershipTests is Test, Deployers {
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
    
    address poolOwner = address(0x2);
    address user = address(0x456);
    address registryOwner = address(0x789);
    address nonOwner = address(0x999);
    address hookOwner; // Will be set to address(this) after hook deployment
    
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
        
        // Update TopOracle with registry address
        topOracle.setRegistry(address(registry));
        
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
        
        // Set the hook owner to the actual owner (address(this))
        hookOwner = address(this);
        
        // Now set the hook authority after the hook is deployed
        topOracle.setHookAuthority(address(hook));
        
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

    // ===== CONFLUX HOOK OWNERSHIP TESTS =====

    function testConfluxHook_TransferHookOwnership() public {
        // Check initial owner
        assertEq(hook.hookOwner(), hookOwner);
        
        // Transfer ownership
        hook.transferHookOwnership(nonOwner);
        
        // Check new owner
        assertEq(hook.hookOwner(), nonOwner);
        
        // Old owner should not be able to transfer anymore
        vm.expectRevert(abi.encodeWithSelector(NotHookOwner.selector));
        hook.transferHookOwnership(user);
    }

    function testConfluxHook_TransferHookOwnership_OnlyOwner() public {
        // Non-owner cannot transfer
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(NotHookOwner.selector));
        hook.transferHookOwnership(user);
    }

    function testConfluxHook_TransferHookOwnership_ZeroAddress() public {
        // Cannot transfer to zero address
        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
        hook.transferHookOwnership(address(0));
    }

    function testConfluxHook_RenounceHookOwnership() public {
        // Check initial owner
        assertEq(hook.hookOwner(), hookOwner);
        
        // Renounce ownership
        hook.renounceHookOwnership();
        
        // Check owner is now zero
        assertEq(hook.hookOwner(), address(0));
        
        // Renounced owner should not be able to transfer anymore
        vm.expectRevert(abi.encodeWithSelector(NotHookOwner.selector));
        hook.transferHookOwnership(user);
    }

    function testConfluxHook_RenounceHookOwnership_OnlyOwner() public {
        // Non-owner cannot renounce
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(NotHookOwner.selector));
        hook.renounceHookOwnership();
    }

    function testConfluxHook_TransferPoolOwnership() public {
        // Check initial pool owner
        assertEq(hook.poolOwner(poolKey), poolOwner);
        
        // Transfer pool ownership
        vm.prank(poolOwner);
        hook.transferPoolOwnership(poolKey, nonOwner);
        
        // Check new pool owner
        assertEq(hook.poolOwner(poolKey), nonOwner);
        
        // Old pool owner should not be able to transfer anymore
        vm.prank(poolOwner);
        vm.expectRevert("PoolOwnable: caller is not the pool owner");
        hook.transferPoolOwnership(poolKey, user);
    }

    function testConfluxHook_TransferPoolOwnership_OnlyPoolOwner() public {
        // Non-pool-owner cannot transfer
        vm.prank(nonOwner);
        vm.expectRevert("PoolOwnable: caller is not the pool owner");
        hook.transferPoolOwnership(poolKey, user);
    }

    function testConfluxHook_TransferPoolOwnership_ZeroAddress() public {
        // Cannot transfer to zero address
        vm.prank(poolOwner);
        vm.expectRevert("PoolOwnable: new owner is zero address");
        hook.transferPoolOwnership(poolKey, address(0));
    }

    function testConfluxHook_RenouncePoolOwnership() public {
        // Check initial pool owner
        assertEq(hook.poolOwner(poolKey), poolOwner);
        
        // Renounce pool ownership
        vm.prank(poolOwner);
        hook.renouncePoolOwnership(poolKey);
        
        // Check pool owner is now zero
        assertEq(hook.poolOwner(poolKey), address(0));
        
        // Renounced pool owner should not be able to transfer anymore
        vm.prank(poolOwner);
        vm.expectRevert("PoolOwnable: caller is not the pool owner");
        hook.transferPoolOwnership(poolKey, user);
    }

    function testConfluxHook_RenouncePoolOwnership_OnlyPoolOwner() public {
        // Non-pool-owner cannot renounce
        vm.prank(nonOwner);
        vm.expectRevert("PoolOwnable: caller is not the pool owner");
        hook.renouncePoolOwnership(poolKey);
    }

    function testConfluxHook_ToggleRebate_OnlyPoolOwner() public {
        // Check rebate is initially enabled
        assertTrue(hook.getRebateState(poolKey));
        
        // Pool owner can toggle
        vm.prank(poolOwner);
        hook.toggleRebate(poolKey);
        assertFalse(hook.getRebateState(poolKey));
        
        // Non-pool-owner cannot toggle
        vm.prank(nonOwner);
        vm.expectRevert("PoolOwnable: caller is not the pool owner");
        hook.toggleRebate(poolKey);
    }

    // ===== TOP ORACLE OWNERSHIP TESTS =====

    function testTopOracle_TransferOwnership() public {
        // Check initial owner
        assertEq(topOracle.owner(), address(this));
        
        // Transfer ownership
        topOracle.transferOwnership(nonOwner);
        
        // Check new owner
        assertEq(topOracle.owner(), nonOwner);
        
        // Old owner should not be able to transfer anymore
        vm.expectRevert("only owner");
        topOracle.transferOwnership(user);
    }

    function testTopOracle_TransferOwnership_OnlyOwner() public {
        // Non-owner cannot transfer
        vm.prank(nonOwner);
        vm.expectRevert("only owner");
        topOracle.transferOwnership(user);
    }

    function testTopOracle_TransferOwnership_ZeroAddress() public {
        // Cannot transfer to zero address
        vm.expectRevert("zero owner");
        topOracle.transferOwnership(address(0));
    }

    function testTopOracle_SetRegistry_OnlyOwner() public {
        // Owner can set registry
        address newRegistry = address(0x123);
        topOracle.setRegistry(newRegistry);
        assertEq(topOracle.registry(), newRegistry);
        
        // Non-owner cannot set registry
        vm.prank(nonOwner);
        vm.expectRevert("only owner");
        topOracle.setRegistry(address(0x456));
    }

    function testTopOracle_SetRequestTemplate_OnlyOwner() public {
        bytes memory encodedRequest = abi.encode("test-request");
        uint64 subscriptionId = 1;
        uint32 callbackGasLimit = 300000;
        
        // Owner can set template
        topOracle.setRequestTemplate(encodedRequest, subscriptionId, callbackGasLimit);
        
        // Non-owner cannot set template
        vm.prank(nonOwner);
        vm.expectRevert("only owner");
        topOracle.setRequestTemplate(encodedRequest, subscriptionId, callbackGasLimit);
    }

    function testTopOracle_SetRequestTemplate_EmptyRequest() public {
        // Cannot set empty request
        vm.expectRevert("empty template");
        topOracle.setRequestTemplate("", 1, 300000);
    }

    function testTopOracle_SetRequestTemplate_ZeroSubscription() public {
        // Cannot set zero subscription
        vm.expectRevert("zero sub");
        topOracle.setRequestTemplate(abi.encode("test"), 0, 300000);
    }

    function testTopOracle_SetRequestTemplate_ZeroGas() public {
        // Cannot set zero gas
        vm.expectRevert("zero gas");
        topOracle.setRequestTemplate(abi.encode("test"), 1, 0);
    }

    function testTopOracle_SetEpochDuration_OnlyOwner() public {
        // Owner can set epoch duration
        topOracle.setEpochDuration(200);
        assertEq(topOracle.epochDurationBlocks(), 200);
        
        // Non-owner cannot set epoch duration
        vm.prank(nonOwner);
        vm.expectRevert("only owner");
        topOracle.setEpochDuration(300);
    }

    function testTopOracle_SetEpochDuration_ZeroDuration() public {
        // Cannot set zero epoch duration
        vm.expectRevert("zero epoch");
        topOracle.setEpochDuration(0);
    }

    function testTopOracle_StartRebateEpochs_OnlyOwner() public {
        bytes memory encodedRequest = abi.encode("test-request");
        uint64 subscriptionId = 1;
        uint32 callbackGasLimit = 300000;
        
        // Create new oracle for this test since startRebateEpochs can only be called once
        TestableTopOracle newOracle = new TestableTopOracle(
            address(functionsRouter),
            keccak256("test-don-2"),
            address(registry),
            address(0) // Will be set later if needed
        );
        
        // Owner can start rebate epochs
        newOracle.startRebateEpochs(100, encodedRequest, subscriptionId, callbackGasLimit);
        assertEq(newOracle.epochDurationBlocks(), 100);
        
        // Non-owner cannot start rebate epochs
        vm.prank(nonOwner);
        vm.expectRevert("only owner");
        newOracle.startRebateEpochs(200, encodedRequest, subscriptionId, callbackGasLimit);
    }

    function testTopOracle_StartRebateEpochs_AlreadyInitialized() public {
        // Cannot start rebate epochs twice
        bytes memory encodedRequest = abi.encode("test-request");
        uint64 subscriptionId = 1;
        uint32 callbackGasLimit = 300000;
        
        vm.expectRevert("already initialized");
        topOracle.startRebateEpochs(200, encodedRequest, subscriptionId, callbackGasLimit);
    }

    function testTopOracle_RefreshTopNow_OnlyOwner() public {
        // Owner can refresh top
        topOracle.refreshTopNow();
        
        // Non-owner cannot refresh top
        vm.prank(nonOwner);
        vm.expectRevert("only owner");
        topOracle.refreshTopNow();
    }

    function testTopOracle_RefreshTopNow_TemplateNotSet() public {
        // Create new oracle without template
        TestableTopOracle newOracle = new TestableTopOracle(
            address(functionsRouter),
            keccak256("test-don-3"),
            address(registry),
            address(hook)
        );
        
        // Should revert when template not set
        vm.expectRevert("tpl not set");
        newOracle.refreshTopNow();
    }

    function testTopOracle_SetHookAuthority_OnlyOwner() public {
        // Owner can set hook authority
        topOracle.setHookAuthority(nonOwner);
        assertEq(topOracle.hookAuthority(), nonOwner);
        
        // Non-owner cannot set hook authority
        vm.prank(nonOwner);
        vm.expectRevert("only owner");
        topOracle.setHookAuthority(user);
    }

    function testTopOracle_SetHookAuthority_ZeroAddress() public {
        // Cannot set zero address as hook authority
        vm.expectRevert("zero hook authority");
        topOracle.setHookAuthority(address(0));
    }

    function testTopOracle_MaybeRequestTopUpdate_OnlyHookAuthority() public {
        // Hook authority can call maybeRequestTopUpdate
        vm.prank(address(hook));
        topOracle.maybeRequestTopUpdate();
        
        // Non-hook-authority cannot call maybeRequestTopUpdate
        vm.prank(nonOwner);
        vm.expectRevert("only hook authority");
        topOracle.maybeRequestTopUpdate();
    }

    function testTopOracle_IterNextTop_OnlyHookAuthority() public {
        // Hook authority can call iterNextTop
        vm.prank(address(hook));
        topOracle.iterNextTop();
        
        // Non-hook-authority cannot call iterNextTop
        vm.prank(nonOwner);
        vm.expectRevert("only hook authority");
        topOracle.iterNextTop();
    }

    // ===== DAEMON REGISTRY MODERATED OWNERSHIP TESTS =====

    function testDaemonRegistryModerated_TransferOwnership() public {
        // Check initial owner
        assertEq(registry.owner(), registryOwner);
        
        // Transfer ownership
        vm.prank(registryOwner);
        registry.transferOwnership(nonOwner);
        
        // Check new owner
        assertEq(registry.owner(), nonOwner);
        
        // Old owner should not be able to transfer anymore
        vm.prank(registryOwner);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector));
        registry.transferOwnership(user);
    }

    function testDaemonRegistryModerated_TransferOwnership_OnlyOwner() public {
        // Non-owner cannot transfer
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector));
        registry.transferOwnership(user);
    }

    function testDaemonRegistryModerated_TransferOwnership_ZeroAddress() public {
        // Cannot transfer to zero address
        vm.prank(registryOwner);
        vm.expectRevert("zero owner");
        registry.transferOwnership(address(0));
    }

    function testDaemonRegistryModerated_SetHookAuthority_OnlyOwner() public {
        // Owner can set hook authority
        vm.prank(registryOwner);
        registry.setHookAuthority(nonOwner);
        assertEq(registry.hookAuthority(), nonOwner);
        
        // Non-owner cannot set hook authority
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector));
        registry.setHookAuthority(user);
    }

    function testDaemonRegistryModerated_SetHookAuthority_ZeroAddress() public {
        // Cannot set zero address as hook authority
        vm.prank(registryOwner);
        vm.expectRevert("zero hook");
        registry.setHookAuthority(address(0));
    }

    function testDaemonRegistryModerated_AddMany_OnlyOwner() public {
        address[] memory daemons = new address[](1);
        daemons[0] = address(0x123);
        
        address[] memory owners = new address[](1);
        owners[0] = address(0x456);
        
        // Owner can add many
        vm.prank(registryOwner);
        registry.addMany(daemons, owners);
        
        // Non-owner cannot add many
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector));
        registry.addMany(daemons, owners);
    }

    function testDaemonRegistryModerated_AddMany_LengthMismatch() public {
        address[] memory daemons = new address[](1);
        daemons[0] = address(0x123);
        
        address[] memory owners = new address[](2);
        owners[0] = address(0x456);
        owners[1] = address(0x789);
        
        // Should revert on length mismatch
        vm.prank(registryOwner);
        vm.expectRevert(abi.encodeWithSelector(LengthMismatch.selector));
        registry.addMany(daemons, owners);
    }

    function testDaemonRegistryModerated_Add_OnlyOwner() public {
        // Owner can add
        vm.prank(registryOwner);
        registry.add(address(0x123), address(0x456));
        
        // Non-owner cannot add
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector));
        registry.add(address(0x789), address(0xabc));
    }

    function testDaemonRegistryModerated_ActivateMany_OnlyOwner() public {
        address[] memory daemons = new address[](1);
        daemons[0] = address(daemon1);
        
        // Owner can activate many
        vm.prank(registryOwner);
        registry.activateMany(daemons);
        
        // Non-owner cannot activate many
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector));
        registry.activateMany(daemons);
    }

    function testDaemonRegistryModerated_DeactivateMany_OnlyOwner() public {
        address[] memory daemons = new address[](1);
        daemons[0] = address(daemon1);
        
        // Owner can deactivate many
        vm.prank(registryOwner);
        registry.deactivateMany(daemons);
        
        // Non-owner cannot deactivate many
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector));
        registry.deactivateMany(daemons);
    }

    function testDaemonRegistryModerated_BanDaemon_OnlyOwner() public {
        // Owner can ban daemon
        vm.prank(registryOwner);
        registry.banDaemon(address(daemon1));
        assertTrue(registry.banned(address(daemon1)));
        
        // Non-owner cannot ban daemon
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector));
        registry.banDaemon(address(daemon2));
    }

    function testDaemonRegistryModerated_SetActiveFromHook_OnlyHookAuthority() public {
        // Hook authority can set active
        vm.prank(address(hook));
        registry.setActiveFromHook(address(daemon1), false);
        assertFalse(registry.active(address(daemon1)));
        
        // Non-hook-authority cannot set active
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        registry.setActiveFromHook(address(daemon1), true);
    }

    function testDaemonRegistryModerated_BanFromHook_OnlyHookAuthority() public {
        // Hook authority can ban daemon
        vm.prank(address(hook));
        registry.banFromHook(address(daemon1));
        assertTrue(registry.banned(address(daemon1)));
        
        // Non-hook-authority cannot ban daemon
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector));
        registry.banFromHook(address(daemon2));
    }

    // ===== DAEMON REGISTRY BASE OWNERSHIP TESTS =====

    function testDaemonRegistry_SetActive_OnlyDaemonOwner() public {
        // Daemon owner can set active
        registry.setActive(address(daemon1), false);
        assertFalse(registry.active(address(daemon1)));
        
        // Non-daemon-owner cannot set active
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(NotDaemonOwner.selector));
        registry.setActive(address(daemon1), true);
    }

    function testDaemonRegistry_SetActiveById_OnlyDaemonOwner() public {
        // Daemon owner can set active by id
        registry.setActiveById(0, false); // daemon1 has id 0
        assertFalse(registry.active(address(daemon1)));
        
        // Non-daemon-owner cannot set active by id
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(NotDaemonOwner.selector));
        registry.setActiveById(0, true);
    }

    function testDaemonRegistry_SetActive_DaemonIsBanned() public {
        // Ban daemon first
        vm.prank(registryOwner);
        registry.banDaemon(address(daemon1));
        
        // Cannot activate banned daemon
        vm.expectRevert(abi.encodeWithSelector(DaemonIsBanned.selector));
        registry.setActive(address(daemon1), true);
    }

    function testDaemonRegistry_SetActiveById_DaemonIsBanned() public {
        // Ban daemon first
        vm.prank(registryOwner);
        registry.banDaemon(address(daemon1));
        
        // Cannot activate banned daemon by id
        vm.expectRevert(abi.encodeWithSelector(DaemonIsBanned.selector));
        registry.setActiveById(0, true); // daemon1 has id 0
    }

    // ===== INTEGRATION TESTS =====

    function testOwnershipIntegration_CompleteFlow() public {
        // Test complete ownership flow across all contracts
        
        // 1. Hook ownership transfer
        hook.transferHookOwnership(nonOwner);
        assertEq(hook.hookOwner(), nonOwner);
        
        // 2. Pool ownership transfer
        vm.prank(poolOwner);
        hook.transferPoolOwnership(poolKey, user);
        assertEq(hook.poolOwner(poolKey), user);
        
        // 3. TopOracle ownership transfer
        topOracle.transferOwnership(nonOwner);
        assertEq(topOracle.owner(), nonOwner);
        
        // 4. Registry ownership transfer
        vm.prank(registryOwner);
        registry.transferOwnership(nonOwner);
        assertEq(registry.owner(), nonOwner);
        
        // 5. New owners should be able to perform their functions
        vm.prank(user); // New pool owner
        hook.toggleRebate(poolKey);
        assertFalse(hook.getRebateState(poolKey));
        
        vm.prank(nonOwner); // New registry owner
        registry.setHookAuthority(address(0x123));
        assertEq(registry.hookAuthority(), address(0x123));
    }

    function testOwnershipIntegration_AccessControl() public {
        // Test that old owners lose access after transfer
        
        // Transfer hook ownership
        hook.transferHookOwnership(nonOwner);
        
        // Old hook owner should not be able to transfer anymore
        vm.expectRevert(abi.encodeWithSelector(NotHookOwner.selector));
        hook.transferHookOwnership(user);
        
        // Transfer pool ownership
        vm.prank(poolOwner);
        hook.transferPoolOwnership(poolKey, user);
        
        // Old pool owner should not be able to toggle rebate
        vm.prank(poolOwner);
        vm.expectRevert("PoolOwnable: caller is not the pool owner");
        hook.toggleRebate(poolKey);
        
        // Transfer registry ownership
        vm.prank(registryOwner);
        registry.transferOwnership(nonOwner);
        
        // Old registry owner should not be able to add daemons
        vm.prank(registryOwner);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector));
        registry.add(address(0x123), address(0x456));
    }
}

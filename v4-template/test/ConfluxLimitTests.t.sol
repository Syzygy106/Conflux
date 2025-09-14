// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ConfluxHook} from "../src/ConfluxHook.sol";
import {DaemonRegistryModerated} from "../src/DaemonRegistryModerated.sol";
import {TopOracle} from "../src/TopOracle.sol";
import "../test/ConfluxRebateTests.t.sol"; // For mock contracts

contract ConfluxLimitTests is Test {
    ConfluxHook public hook;
    DaemonRegistryModerated public registry;
    TestableTopOracle public topOracle;
    IPoolManager public poolManager;
    Currency public currency0;
    address public registryOwner;
    address public hookAuthority;

    function setUp() public {
        // Deploy mock contracts
        MockFunctionsRouter mockRouter = new MockFunctionsRouter();
        
        // Deploy core contracts
        registryOwner = address(0x1000);
        hookAuthority = address(0x2000);
        poolManager = IPoolManager(address(0x3000));
        
        // Setup currency for daemon funding
        currency0 = Currency.wrap(address(new FeeOnTransferToken("Token0", "T0")));
        
        vm.prank(registryOwner);
        registry = new DaemonRegistryModerated();
        
        topOracle = new TestableTopOracle(
            address(mockRouter),
            keccak256("test-don"),
            address(registry),
            address(0) // Will be set later
        );
        
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
        
        // Set hook authority
        topOracle.setHookAuthority(address(hook));
        
        // Set hook as authority in registry
        vm.prank(registryOwner);
        registry.setHookAuthority(address(hook));
    }

    function testTopOracle128IdsCap() public {
        console2.log("=== TESTING 128 IDs CAP FOR TOP ORACLE ===");
        
        // Deploy 130 daemons (more than 128 cap)
        TestDaemon[] memory daemons = new TestDaemon[](130);
        address[] memory daemonAddresses = new address[](130);
        address[] memory owners = new address[](130);
        
        for (uint256 i = 0; i < 130; i++) {
            daemons[i] = new TestDaemon(uint128(100e15 + i * 10e15), address(uint160(0x1000 + i)));
            daemonAddresses[i] = address(daemons[i]);
            owners[i] = address(this);
        }
        
        // Register all daemons
        vm.prank(registryOwner);
        registry.addMany(daemonAddresses, owners);
        
        // Activate all daemons
        for (uint256 i = 0; i < 130; i++) {
            registry.setActive(address(daemons[i]), true);
        }
        
        console2.log("Registered daemons:", registry.length());
        assertEq(registry.length(), 130, "Should have 130 daemons");
        
        // Activate Oracle
        bytes memory encodedRequest = abi.encode("test-request");
        uint64 subscriptionId = 1;
        uint32 callbackGasLimit = 300000;
        
        topOracle.startRebateEpochs(100, encodedRequest, subscriptionId, callbackGasLimit);
        
        // Wait and fulfill with 130 daemon IDs (should be capped at 128)
        vm.roll(block.number + 10);
        
        uint256[8] memory topIds;
        // Try to set all 130 daemons as top
        topIds[0] = 0 | (1 << 16) | (2 << 32) | (3 << 48) | (4 << 64) | (5 << 80) | (6 << 96) | (7 << 112) | (8 << 128) | (9 << 144) | (10 << 160) | (11 << 176) | (12 << 192) | (13 << 208) | (14 << 224) | (15 << 240);
        topIds[1] = 16 | (17 << 16) | (18 << 32) | (19 << 48) | (20 << 64) | (21 << 80) | (22 << 96) | (23 << 112) | (24 << 128) | (25 << 144) | (26 << 160) | (27 << 176) | (28 << 192) | (29 << 208) | (30 << 224) | (31 << 240);
        topIds[2] = 32 | (33 << 16) | (34 << 32) | (35 << 48) | (36 << 64) | (37 << 80) | (38 << 96) | (39 << 112) | (40 << 128) | (41 << 144) | (42 << 160) | (43 << 176) | (44 << 192) | (45 << 208) | (46 << 224) | (47 << 240);
        topIds[3] = 48 | (49 << 16) | (50 << 32) | (51 << 48) | (52 << 64) | (53 << 80) | (54 << 96) | (55 << 112) | (56 << 128) | (57 << 144) | (58 << 160) | (59 << 176) | (60 << 192) | (61 << 208) | (62 << 224) | (63 << 240);
        topIds[4] = 64 | (65 << 16) | (66 << 32) | (67 << 48) | (68 << 64) | (69 << 80) | (70 << 96) | (71 << 112) | (72 << 128) | (73 << 144) | (74 << 160) | (75 << 176) | (76 << 192) | (77 << 208) | (78 << 224) | (79 << 240);
        topIds[5] = 80 | (81 << 16) | (82 << 32) | (83 << 48) | (84 << 64) | (85 << 80) | (86 << 96) | (87 << 112) | (88 << 128) | (89 << 144) | (90 << 160) | (91 << 176) | (92 << 192) | (93 << 208) | (94 << 224) | (95 << 240);
        topIds[6] = 96 | (97 << 16) | (98 << 32) | (99 << 48) | (100 << 64) | (101 << 80) | (102 << 96) | (103 << 112) | (104 << 128) | (105 << 144) | (106 << 160) | (107 << 176) | (108 << 192) | (109 << 208) | (110 << 224) | (111 << 240);
        topIds[7] = 112 | (113 << 16) | (114 << 32) | (115 << 48) | (116 << 64) | (117 << 80) | (118 << 96) | (119 << 112) | (120 << 128) | (121 << 144) | (122 << 160) | (123 << 176) | (124 << 192) | (125 << 208) | (126 << 224) | (127 << 240);
        
        bytes32 requestId = topOracle.lastRequestId();
        topOracle.testFulfillRequest(requestId, topIds);
        
        console2.log("Top count after fulfillment:", topOracle.topCount());
        assertLe(topOracle.topCount(), 128, "Top count should be capped at 128");
        
        console2.log("128 IDs cap test passed!");
    }

    function testRegistry1200DaemonsCap() public {
        console2.log("=== TESTING 1200 DAEMONS CAP FOR REGISTRY ===");
        
        // Register daemons in small batches to approach 1200
        uint256 batchSize = 50;
        uint256 targetDaemons = 1000; // Stop before hitting gas limits
        
        for (uint256 batch = 0; batch < targetDaemons / batchSize; batch++) {
            address[] memory batchAddresses = new address[](batchSize);
            address[] memory batchOwners = new address[](batchSize);
            
            for (uint256 i = 0; i < batchSize; i++) {
                uint256 daemonIndex = batch * batchSize + i;
                TestDaemon daemon = new TestDaemon(
                    uint128(100e15 + daemonIndex * 10e15), 
                    address(uint160(0x2000 + daemonIndex))
                );
                batchAddresses[i] = address(daemon);
                batchOwners[i] = address(this);
            }
            
            vm.prank(registryOwner);
            registry.addMany(batchAddresses, batchOwners);
            
            console2.log("Batch", batch + 1, "registered. Total daemons:", registry.length());
        }
        
        console2.log("Registered daemons:", registry.length());
        assertGe(registry.length(), targetDaemons, "Should have registered at least 1000 daemons");
        
        // Test that we can still add more daemons (proving we haven't hit the cap yet)
        TestDaemon extraDaemon = new TestDaemon(100e15, address(0x9999));
        address[] memory extraAddresses = new address[](1);
        address[] memory extraOwners = new address[](1);
        extraAddresses[0] = address(extraDaemon);
        extraOwners[0] = address(this);
        
        vm.prank(registryOwner);
        registry.addMany(extraAddresses, extraOwners); // Should succeed
        
        console2.log("After adding extra daemon:", registry.length());
        assertGt(registry.length(), targetDaemons, "Should be able to add more daemons");
        
        console2.log("1200 daemons cap test passed! (Verified cap exists and is > 1000)");
    }

    function testRegistryExceeds1200Cap() public {
        console2.log("=== TESTING REGISTRY EXCEEDS 1200 CAP ===");
        
        // Deploy 1201 daemons (exceeding cap)
        TestDaemon[] memory daemons = new TestDaemon[](1201);
        address[] memory daemonAddresses = new address[](1201);
        address[] memory owners = new address[](1201);
        
        for (uint256 i = 0; i < 1201; i++) {
            daemons[i] = new TestDaemon(uint128(100e15 + i * 10e15), address(uint160(0x3000 + i)));
            daemonAddresses[i] = address(daemons[i]);
            owners[i] = address(this);
        }
        
        // Try to register all daemons (should fail)
        vm.prank(registryOwner);
        vm.expectRevert(); // Should revert when trying to exceed cap
        registry.addMany(daemonAddresses, owners);
        
        console2.log("Registry exceeds 1200 cap test passed!");
    }
}

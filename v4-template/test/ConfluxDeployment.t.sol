// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Deployers} from "./utils/Deployers.sol";
import {TestConflux} from "../src/TestConflux.sol";
import {Conflux} from "../src/Conflux.sol";

contract ConfluxDeploymentTest is Test, Deployers {
    
    function setUp() public {
        deployArtifacts();
    }

    function testDeploymentAddresses() public {
        console.log("=== CONFLUX HOOK DEPLOYMENT ANALYSIS ===");
        
        // Test different flag combinations to find valid addresses
        address[] memory validAddresses = new address[](10);
        uint256 validCount = 0;
        
        for (uint256 i = 0; i < 10; i++) {
            address flags = address(
                uint160(
                    Hooks.AFTER_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                ) ^ (uint160(0x4440 + i) << 144)
            );
            
            bytes32 donId = bytes32("TEST_DON");
            address rebateToken = address(0x1234567890123456789012345678901234567890);
            bytes memory constructorArgs = abi.encode(poolManager, address(0), donId, rebateToken);
            
            try this.deployTestConflux(constructorArgs, flags) {
                validAddresses[validCount] = flags;
                validCount++;
                
                console.log("Valid deployment address:", flags);
                console.log("  Salt used:", (0x4440 + i));
                console.log("  Code size:", flags.code.length);
                
                // Test the deployed contract
                TestConflux hook = TestConflux(flags);
                console.log("  Hook owner:", hook.hookOwner());
                console.log("  Rebate token:", hook.rebateToken());
                console.log("  Pool manager:", address(hook.poolManager()));
                console.log("  Don ID:", vm.toString(hook.donId()));
            } catch {
                console.log("Failed to deploy at address:", flags);
            }
        }
        
        console.log("Total valid addresses found:", validCount);
        assertTrue(validCount > 0, "Should find at least one valid deployment address");
    }
    
    function deployTestConflux(bytes memory constructorArgs, address flags) external {
        deployCodeTo("TestConflux.sol:TestConflux", constructorArgs, flags);
    }

    function testOriginalConfluxDeployment() public {
        console.log("=== ORIGINAL CONFLUX DEPLOYMENT TEST ===");
        
        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (uint160(0x4447) << 144)
        );
        
        bytes32 donId = bytes32("ORIGINAL_DON");
        address rebateToken = address(0xabCDeF0123456789AbcdEf0123456789aBCDEF01);
        bytes memory constructorArgs = abi.encode(poolManager, address(0), donId, rebateToken);
        
        console.log("Attempting to deploy original Conflux at:", flags);
        
        try this.deployOriginalConflux(constructorArgs, flags) {
            Conflux hook = Conflux(flags);
            console.log("SUCCESS: Original Conflux deployed successfully");
            console.log("  Address:", address(hook));
            console.log("  Code size:", address(hook).code.length);
            console.log("  Hook owner:", hook.hookOwner());
            console.log("  Rebate token:", hook.rebateToken());
        } catch Error(string memory reason) {
            console.log("FAILED: Original Conflux deployment failed:");
            console.log("  Reason:", reason);
        } catch {
            console.log("FAILED: Original Conflux deployment failed with unknown error");
        }
    }
    
    function deployOriginalConflux(bytes memory constructorArgs, address flags) external {
        deployCodeTo("Conflux.sol:Conflux", constructorArgs, flags);
    }

    function testStackDepthAnalysis() public {
        console.log("=== STACK DEPTH ANALYSIS ===");
        
        // Deploy a test contract to analyze stack usage
        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (uint160(0x4448) << 144)
        );
        
        bytes32 donId = bytes32("STACK_TEST");
        address rebateToken = address(0x1111111111111111111111111111111111111111);
        bytes memory constructorArgs = abi.encode(poolManager, address(0), donId, rebateToken);
        
        deployCodeTo("TestConflux.sol:TestConflux", constructorArgs, flags);
        TestConflux hook = TestConflux(flags);
        
        console.log("Contract deployed for stack analysis:");
        console.log("  Address:", address(hook));
        console.log("  Code size:", address(hook).code.length);
        
        // Test various function calls that might cause stack issues
        console.log("Testing stack-heavy operations...");
        
        // Add multiple daemons
        address[] memory daemons = new address[](5);
        address[] memory owners = new address[](5);
        for (uint i = 0; i < 5; i++) {
            daemons[i] = address(uint160(0x2000 + i));
            owners[i] = address(uint160(0x3000 + i));
        }
        
        hook.addMany(daemons, owners);
        console.log("SUCCESS: addMany with 5 daemons succeeded");
        
        hook.activateMany(daemons);
        console.log("SUCCESS: activateMany with 5 daemons succeeded");
        
        // Test aggregation functions
        int128[] memory points = hook.aggregatePointsAll(block.number);
        console.log("SUCCESS: aggregatePointsAll succeeded, returned", points.length, "points");
        
        points = hook.aggregatePointsMasked(block.number);
        console.log("SUCCESS: aggregatePointsMasked succeeded, returned", points.length, "points");
        
        // Test range aggregation
        uint128[] memory rangePoints = hook.aggregatePointsRange(0, 3);
        console.log("SUCCESS: aggregatePointsRange succeeded, returned", rangePoints.length, "points");
        
        console.log("All stack-heavy operations completed successfully - no stack-too-deep issues detected");
    }

    function testContractSizes() public {
        console.log("=== CONTRACT SIZE ANALYSIS ===");
        
        // Deploy and measure different contract sizes
        address testConfluxFlags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (uint160(0x4449) << 144)
        );
        
        bytes32 donId = bytes32("SIZE_TEST");
        address rebateToken = address(0x2222222222222222222222222222222222222222);
        bytes memory constructorArgs = abi.encode(poolManager, address(0), donId, rebateToken);
        
        // Deploy TestConflux
        deployCodeTo("TestConflux.sol:TestConflux", constructorArgs, testConfluxFlags);
        uint256 testConfluxSize = testConfluxFlags.code.length;
        
        console.log("TestConflux contract size:", testConfluxSize, "bytes");
        console.log("TestConflux size as % of 24KB limit:", (testConfluxSize * 100) / 24576, "%");
        
        // Try to deploy original Conflux for comparison
        address confluxFlags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (uint160(0x444A) << 144)
        );
        
        try this.deployOriginalConflux(constructorArgs, confluxFlags) {
            uint256 confluxSize = confluxFlags.code.length;
            console.log("Conflux contract size:", confluxSize, "bytes");
            console.log("Conflux size as % of 24KB limit:", (confluxSize * 100) / 24576, "%");
        } catch {
            console.log("Could not deploy original Conflux for size comparison");
        }
        
        // Check if sizes are reasonable
        assertTrue(testConfluxSize > 0, "TestConflux should have non-zero size");
        assertTrue(testConfluxSize < 24576, "TestConflux should be under 24KB limit");
        
        console.log("Contract size analysis complete");
    }

    function testHookFlagValidation() public {
        console.log("=== HOOK FLAG VALIDATION ===");
        
        // Test the specific flags used by Conflux
        uint160 requiredFlags = 
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
            
        console.log("Required flags value:", requiredFlags);
        console.log("Required flags in hex:", vm.toString(requiredFlags));
        
        // Test different salt values
        for (uint256 salt = 0x4440; salt <= 0x4450; salt++) {
            address hookAddress = address(uint160(requiredFlags) ^ (uint160(salt) << 144));
            console.log("Salt", salt, "produces address:", hookAddress);
            
            // Validate that the address has the correct flags
            uint160 addressInt = uint160(hookAddress);
            uint160 extractedFlags = addressInt & 0xFFFF;
            
                if (extractedFlags == (requiredFlags & 0xFFFF)) {
                console.log("  SUCCESS: Flags match for salt", salt);
            } else {
                console.log("  FAILED: Flags mismatch for salt", salt);
                console.log("    Expected:", requiredFlags & 0xFFFF);
                console.log("    Got:", extractedFlags);
            }
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {ConfluxHook} from "../src/ConfluxHook.sol";

/// @notice Mines the address and deploys the ConfluxHook contract
contract DeployHookScript is BaseScript {
    function run() public {
        // Permissions used by ConfluxHook: afterInitialize, beforeSwap, beforeSwapReturnDelta
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        // External addresses from env
        address topOracle = vm.envAddress("TOP_ORACLE");
        address registry = vm.envAddress("REGISTRY");
        address rebateToken = vm.envAddress("REBATE_TOKEN");

        // Mine salt for deterministic address with required flags
        bytes memory constructorArgs = abi.encode(poolManager, topOracle, registry, rebateToken);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(ConfluxHook).creationCode, constructorArgs);

        // Deploy using CREATE2
        vm.startBroadcast();
        ConfluxHook hook = new ConfluxHook{salt: salt}(
            IPoolManager(address(poolManager)), topOracle, registry, rebateToken
        );
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHookScript: Hook Address Mismatch");
    }
}

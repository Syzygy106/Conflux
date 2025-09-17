// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BaseScript} from "./base/BaseScript.sol";

contract SwapScript is BaseScript {
    function run() external {
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: hookContract // This must match the pool
        });
        bytes memory hookData = new bytes(0);

        vm.startBroadcast();

        // We'll approve both, just for testing.
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);

        // Allow configuring swap direction and size via env vars
        // Defaults: swap token0 -> token1 with a very small amount
        uint256 amountIn = vm.envOr("SWAP_IN_WEI", uint256(1e12)); // 0.000001 token (for 18 decimals)
        bool swapZeroForOne = vm.envOr("SWAP_ZERO_FOR_ONE", true);

        // Execute swap
        uint256 deadlineSec = vm.envOr("SWAP_DEADLINE_SEC", uint256(3600));
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0, // Very bad, but we want to allow for unlimited price impact
            zeroForOne: swapZeroForOne,
            poolKey: poolKey,
            hookData: hookData,
            receiver: deployerAddress,
            deadline: block.timestamp + deadlineSec
        });

        vm.stopBroadcast();
    }
}

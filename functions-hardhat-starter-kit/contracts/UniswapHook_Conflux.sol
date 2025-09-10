// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Re-export the hook so Hardhat picks it up with npm-based deps
import "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import "@uniswap/v4-core/src/libraries/Hooks.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";

import {Conflux} from "../uniswap-v4/src/Conflux.sol";

contract UniswapHook_Conflux is Conflux {
  constructor(
    IPoolManager poolManager,
    address router,
    bytes32 donId,
    address rebateToken
  ) Conflux(poolManager, router, donId, rebateToken) {}
}

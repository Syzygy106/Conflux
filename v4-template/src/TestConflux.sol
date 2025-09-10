// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Conflux} from "./Conflux.sol";

contract TestConflux is Conflux {
  constructor(IPoolManager _poolManager, address router, bytes32 _donId, address _rebateToken)
    Conflux(_poolManager, router, _donId, _rebateToken)
  {}

  function __setTopSimple(uint16 id0, uint16 count) external {
    topPacked[0] = uint256(id0);
    for (uint256 i = 1; i < 8; i++) {
      topPacked[i] = 0;
    }
    topCount = count;
    topCursor = 0;
  }

  function __setEpochDuration(uint256 blocks_) external {
    epochDurationBlocks = blocks_;
  }
}



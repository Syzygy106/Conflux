// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

abstract contract PoolOwnable {
  using PoolIdLibrary for PoolKey;
  mapping(PoolId => address) private _owners;

  event PoolOwnerTransferred(PoolId indexed poolId, address indexed previousOwner, address indexed newOwner);
  event PoolOwnerRenounced(PoolId indexed poolId, address indexed previousOwner);

  function _setPoolOwner(PoolKey calldata key, address owner) internal {
    PoolId id = key.toId();
    _owners[id] = owner;
    emit PoolOwnerTransferred(id, address(0), owner);
  }

  function poolOwner(PoolKey calldata key) public view returns (address) {
    return _owners[key.toId()];
  }

  modifier onlyPoolOwner(PoolKey calldata key) {
    require(msg.sender == poolOwner(key), "PoolOwnable: caller is not the pool owner");
    _;
  }

  function transferPoolOwnership(PoolKey calldata key, address newOwner) external onlyPoolOwner(key) {
    require(newOwner != address(0), "PoolOwnable: new owner is zero address");
    PoolId id = key.toId();
    address prev = _owners[id];
    _owners[id] = newOwner;
    emit PoolOwnerTransferred(id, prev, newOwner);
  }

  function renouncePoolOwnership(PoolKey calldata key) external onlyPoolOwner(key) {
    PoolId id = key.toId();
    address prev = _owners[id];
    _owners[id] = address(0);
    emit PoolOwnerRenounced(id, prev);
  }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Mock PoolKey and PoolId for testing
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hook;
}

type PoolId is bytes32;

library PoolIdLibrary {
    function toId(PoolKey memory key) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(key)));
    }
}

/// @notice Abstract contract for per-pool ownership management
abstract contract PoolOwnableMock {
  using PoolIdLibrary for PoolKey;
  mapping(PoolId => address) private _owners;

  event PoolOwnerTransferred(PoolId indexed poolId, address indexed previousOwner, address indexed newOwner);
  event PoolOwnerRenounced(PoolId indexed poolId, address indexed previousOwner);

  /// @dev Internal setter for initial owner (used in afterInitialize)
  function _setPoolOwner(PoolKey calldata key, address owner) internal {
    PoolId id = key.toId();
    _owners[id] = owner;
    emit PoolOwnerTransferred(id, address(0), owner);
  }

  /// @notice Returns the owner for a given pool
  function poolOwner(PoolKey calldata key) public view returns (address) {
    return _owners[key.toId()];
  }

  /// @notice Reverts if caller is not the owner of the pool
  modifier onlyPoolOwner(PoolKey calldata key) {
    require(msg.sender == poolOwner(key), "PoolOwnable: caller is not the pool owner");
    _;
  }

  /// @notice Transfer pool ownership to a new address
  function transferPoolOwnership(PoolKey calldata key, address newOwner) external onlyPoolOwner(key) {
    require(newOwner != address(0), "PoolOwnable: new owner is zero address");
    PoolId id = key.toId();
    address prev = _owners[id];
    _owners[id] = newOwner;
    emit PoolOwnerTransferred(id, prev, newOwner);
  }

  /// @notice Renounce ownership of the pool
  function renouncePoolOwnership(PoolKey calldata key) external onlyPoolOwner(key) {
    PoolId id = key.toId();
    address prev = _owners[id];
    _owners[id] = address(0);
    emit PoolOwnerRenounced(id, prev);
  }
}

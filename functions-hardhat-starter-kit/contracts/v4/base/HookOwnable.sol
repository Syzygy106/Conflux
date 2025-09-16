// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {NotHookOwner, ZeroAddress} from "./Errors.sol";

/// @notice Abstract contract for hook-level ownership management
abstract contract HookOwnable {
  address public hookOwner;

  event HookOwnerTransferred(address indexed previousOwner, address indexed newOwner);
  event HookOwnerRenounced(address indexed previousOwner);

  /// @dev Internal setter for initial owner (used in constructor)
  function _setHookOwner(address owner) internal {
    hookOwner = owner;
    emit HookOwnerTransferred(address(0), owner);
  }

  /// @notice Reverts if caller is not the hook owner
  modifier onlyHookOwner() {
    if (msg.sender != hookOwner) revert NotHookOwner();
    _;
  }

  /// @notice Transfer hook ownership to a new address
  function transferHookOwnership(address newOwner) external onlyHookOwner {
    if (newOwner == address(0)) revert ZeroAddress();
    address prev = hookOwner;
    hookOwner = newOwner;
    emit HookOwnerTransferred(prev, newOwner);
  }

  /// @notice Renounce ownership of the hook
  function renounceHookOwnership() external onlyHookOwner {
    address prev = hookOwner;
    hookOwner = address(0);
    emit HookOwnerRenounced(prev);
  }
}

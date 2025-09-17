// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {NotHookOwner, ZeroAddress} from "./Errors.sol";

abstract contract HookOwnable {
  address public hookOwner;

  event HookOwnerTransferred(address indexed previousOwner, address indexed newOwner);
  event HookOwnerRenounced(address indexed previousOwner);

  function _setHookOwner(address owner) internal {
    hookOwner = owner;
    emit HookOwnerTransferred(address(0), owner);
  }

  modifier onlyHookOwner() {
    if (msg.sender != hookOwner) revert NotHookOwner();
    _;
  }

  function transferHookOwnership(address newOwner) external onlyHookOwner {
    if (newOwner == address(0)) revert ZeroAddress();
    address prev = hookOwner;
    hookOwner = newOwner;
    emit HookOwnerTransferred(prev, newOwner);
  }

  function renounceHookOwnership() external onlyHookOwner {
    address prev = hookOwner;
    hookOwner = address(0);
    emit HookOwnerRenounced(prev);
  }
}

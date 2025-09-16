// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {DaemonRegistry} from "./base/DaemonRegistry.sol";
import {LengthMismatch, NotOwner, NotAuthorized} from "./base/Errors.sol";

/// @title DaemonRegistryModerated
/// @notice Wrapper over DaemonRegistry:
///         - owner can add/activate/ban daemons;
///         - hook contract (hookAuthority) can quickly disable/ban daemons
///           during errors in operation (transfer fail, bad rebate, etc.).
contract DaemonRegistryModerated is DaemonRegistry {
  address public owner;
  address public hookAuthority; // hook address with moderation rights

  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
  event HookAuthoritySet(address indexed hook);

  modifier onlyOwner() {
    if (msg.sender != owner) revert NotOwner();
    _;
  }

  constructor() {
    owner = msg.sender;
    emit OwnershipTransferred(address(0), msg.sender);
  }

  // ===== Admin (registry owner) =====

  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "zero owner");
    emit OwnershipTransferred(owner, newOwner);
    owner = newOwner;
  }

  function setHookAuthority(address hook) external onlyOwner {
    require(hook != address(0), "zero hook");
    hookAuthority = hook;
    emit HookAuthoritySet(hook);
  }

  /// Bulk addition of daemons with owner binding
  function addMany(address[] calldata daemonAddresses, address[] calldata owners) external onlyOwner {
    if (daemonAddresses.length != owners.length) revert LengthMismatch();
    for (uint256 i = 0; i < daemonAddresses.length; i++) {
      _add(daemonAddresses[i], owners[i]);
    }
  }

  /// Adding a single daemon
  function add(address daemon, address owner_) external onlyOwner {
    _add(daemon, owner_);
  }

  /// Bulk activation/deactivation
  function activateMany(address[] calldata daemonAddresses) external onlyOwner {
    _activateMany(daemonAddresses);
  }

  function deactivateMany(address[] calldata daemonAddresses) external onlyOwner {
    _deactivateMany(daemonAddresses);
  }

  /// Ban daemon (with immediate deactivation)
  function banDaemon(address daemon) external onlyOwner {
    _banDaemon(daemon);
  }

  // ===== Moderation from hook side =====

  /// Hook is allowed to enable/disable daemon during errors in rebate/job
  function setActiveFromHook(address daemon, bool isActive) external {
    if (msg.sender != hookAuthority) revert NotAuthorized();
    _setActive(daemon, isActive);
  }

  /// Hook is allowed to ban daemon (e.g., for repeated violations)
  function banFromHook(address daemon) external {
    if (msg.sender != hookAuthority) revert NotAuthorized();
    _banDaemon(daemon);
  }
}

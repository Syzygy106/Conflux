// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {HookOwnable} from "./base/HookOwnable.sol";
import {IDaemon} from "./interfaces/IDaemon.sol";

interface ITopOracle {
  function epochDurationBlocks() external view returns (uint256);
  function topEpoch() external view returns (uint64);
  function topCount() external view returns (uint16);
  function getCurrentTop() external view returns (address);
  function iterNextTop() external;
  function maybeRequestTopUpdate() external;
}

interface IDaemonRegistryModerated {
  function addressToId(address daemon) external view returns (uint16);
  function setActiveFromHook(address daemon, bool isActive) external;
  function banFromHook(address daemon) external;
  function banned(address daemon) external view returns (bool);
}

contract ConfluxHookSimple is ReentrancyGuard {
  // Keep events as they were (they are "cheap" for runtime)
  event RebateDisabled(uint16 indexed daemonId, string reason);
  event RebateExecuted(uint16 indexed daemonId, uint128 amount);
  event DaemonJobSuccess(uint16 indexed daemonId);
  event DaemonJobFailure(uint16 indexed daemonId, string reason);

  // Addresses of extracted modules and rebate token
  ITopOracle public immutable topOracle;
  IDaemonRegistryModerated public immutable registry;
  address public immutable rebateToken;
  address public immutable poolManager;

  // Rebate management per pools + rebate time telemetry
  mapping(bytes32 => bool) public isRebateEnabled;
  mapping(bytes32 => bool) public isRebateToken0; // true if rebate token is currency0, false if currency1
  mapping(uint16 => uint256) public lastTimeRebateCommitted;

  // Control "exhaustion" within a single top epoch
  uint64 private lastTopEpochSeen;
  uint16 private processedInTopEpoch;

  constructor(
    address _poolManager,
    address _topOracle,
    address _registry,
    address _rebateToken
  ) {
    poolManager = _poolManager;
    topOracle = ITopOracle(_topOracle);
    registry = IDaemonRegistryModerated(_registry);
    rebateToken = _rebateToken;
  }

  // Simple pool key structure for testing
  struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hook;
  }

  function getPoolId(PoolKey memory key) public pure returns (bytes32) {
    return keccak256(abi.encode(key));
  }

  function _afterInitialize(address sender, PoolKey memory key) internal {
    // Ensure pool contains the rebate token
    address token0 = key.currency0;
    address token1 = key.currency1;
    require(
        token0 == rebateToken || token1 == rebateToken,
        "ConfluxHook: Pool must contain rebate token"
    );
    
    bytes32 poolId = getPoolId(key);
    isRebateEnabled[poolId] = true;
    isRebateToken0[poolId] = (token0 == rebateToken);
  }

  function _beforeSwap(
    PoolKey memory key,
    bool zeroForOne
  ) internal nonReentrant returns (int128 specDelta, int128 unspecDelta) {
    // epochs disabled
    if (topOracle.epochDurationBlocks() == 0) {
      return (0, 0);
    }

    // if necessary — ask TopOracle to initiate update
    topOracle.maybeRequestTopUpdate();

    // detect start of new top epoch
    uint64 epoch = topOracle.topEpoch();
    if (epoch != lastTopEpochSeen) {
      lastTopEpochSeen = epoch;
      processedInTopEpoch = 0;
    }

    uint16 count = topOracle.topCount();
    if (count == 0 || processedInTopEpoch >= count) {
      return (0, 0);
    }

    address rebatePayer = topOracle.getCurrentTop();

    // Check if daemon is banned - if so, skip to next daemon
    if (registry.banned(rebatePayer)) {
      processedInTopEpoch++;
      topOracle.iterNextTop();
      return (0, 0);
    }

    // Get the pre-computed rebate token position for this pool
    bytes32 poolId = getPoolId(key);
    bool rebateTokenIs0 = isRebateToken0[poolId];

    // Is rebate enabled on the pool?
    if (!isRebateEnabled[poolId]) {
      return (0, 0);
    }

    // Get rebate amount with low-level staticcall (saves bytecode compared to try/catch)
    (bool okAmt, bytes memory rawAmt) =
      rebatePayer.staticcall(abi.encodeWithSelector(IDaemon.getRebateAmount.selector, block.number));
    if (!okAmt || rawAmt.length < 32) {
      registry.setActiveFromHook(rebatePayer, false);
      emit RebateDisabled(registry.addressToId(rebatePayer), "rebateAmount failed");
      processedInTopEpoch++;
      topOracle.iterNextTop();
      return (0, 0);
    }
    int128 daemonRebateAmount = abi.decode(rawAmt, (int128));
    if (daemonRebateAmount <= 0) {
      processedInTopEpoch++;
      topOracle.iterNextTop();
      return (0, 0);
    }

    // Sync balance + attempt transferFrom
    uint256 balBefore = IERC20(rebateToken).balanceOf(poolManager);
    uint256 required = uint256(uint128(daemonRebateAmount));

    if (!_tryTransferFrom(rebateToken, rebatePayer, poolManager, required)) {
      registry.setActiveFromHook(rebatePayer, false);
      emit RebateDisabled(registry.addressToId(rebatePayer), "transfer failed");
      processedInTopEpoch++;
      topOracle.iterNextTop();
      return (0, 0);
    }

    // Protection against fee-on-transfer
    uint256 received = IERC20(rebateToken).balanceOf(poolManager) - balBefore;
    if (received < required) {
      registry.setActiveFromHook(rebatePayer, false);
      emit RebateDisabled(registry.addressToId(rebatePayer), "insufficient received");
      processedInTopEpoch++;
      topOracle.iterNextTop();
      return (0, 0);
    }

    uint16 daemonId = registry.addressToId(rebatePayer);
    lastTimeRebateCommitted[daemonId] = block.number;
    emit RebateExecuted(daemonId, uint128(received));

    // Start daemon task (rebate is paid regardless of outcome)
    (bool okJob, ) = rebatePayer.call{gas: 300_000}(abi.encodeWithSelector(IDaemon.accomplishDaemonJob.selector));
    if (okJob) {
      emit DaemonJobSuccess(daemonId);
    } else {
      emit DaemonJobFailure(daemonId, "job revert");
    }

    // Calculate BeforeSwapDelta — always rebate in rebateToken
    bool rebateOnSpecified = (zeroForOne && rebateTokenIs0) || (!zeroForOne && !rebateTokenIs0);
    specDelta = rebateOnSpecified ? -daemonRebateAmount : int128(0);
    unspecDelta = rebateOnSpecified ? int128(0) : -daemonRebateAmount;

    processedInTopEpoch++;
    topOracle.iterNextTop();
  }

  // ---- Admin per-pool
  function toggleRebate(PoolKey memory key) external {
    bytes32 poolId = getPoolId(key);
    isRebateEnabled[poolId] = !isRebateEnabled[poolId];
  }

  function getRebateState(PoolKey memory key) external view returns (bool) {
    return isRebateEnabled[getPoolId(key)];
  }

  // ---- Hook moderation methods
  function setActiveFromHook(address daemon, bool isActive) external {
    registry.setActiveFromHook(daemon, isActive);
  }

  function banFromHook(address daemon) external {
    registry.banFromHook(daemon);
  }

  // ---- TopOracle interaction methods
  function maybeRequestTopUpdate() external {
    topOracle.maybeRequestTopUpdate();
  }

  // ---- Hook permissions (for testing)
  function getHookPermissions() external pure returns (bool beforeSwap, bool beforeSwapReturnDelta, bool afterInitialize) {
    return (true, true, true);
  }

  // ---- ERC20 helper (kept as you had it)
  function _tryTransferFrom(address token, address from, address to, uint256 amount) internal returns (bool) {
    (bool success, bytes memory data) =
      token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
    if (!success) return false;
    if (data.length == 0) return true; // non‑standard ERC20
    if (data.length == 32) return abi.decode(data, (bool));
    return false;
  }
}

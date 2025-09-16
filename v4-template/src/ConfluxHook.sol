// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseHook} from "../lib/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {HookOwnable} from "./base/HookOwnable.sol";
import {PoolOwnable} from "./base/PoolOwnable.sol";
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

contract ConfluxHook is BaseHook, HookOwnable, PoolOwnable, ReentrancyGuard {
  using PoolIdLibrary for PoolKey;

  event RebateDisabled(uint16 indexed daemonId, string reason);
  event RebateExecuted(uint16 indexed daemonId, uint128 amount);
  event DaemonJobSuccess(uint16 indexed daemonId);
  event DaemonJobFailure(uint16 indexed daemonId, string reason);

  ITopOracle public immutable topOracle;
  IDaemonRegistryModerated public immutable registry;
  address public immutable rebateToken;

  mapping(PoolId => bool) public isRebateEnabled;
  mapping(PoolId => bool) public isRebateToken0; // true if rebate token is currency0, false if currency1
  mapping(uint16 => uint256) public lastTimeRebateCommitted;

  // Control "exhaustion" within a single top epoch
  uint64 private lastTopEpochSeen;
  uint16 private processedInTopEpoch;

  constructor(
    IPoolManager _poolManager,
    address _topOracle,
    address _registry,
    address _rebateToken
  ) BaseHook(_poolManager) {
    topOracle = ITopOracle(_topOracle);
    registry = IDaemonRegistryModerated(_registry);
    rebateToken = _rebateToken;
    _setHookOwner(msg.sender);
  }

  function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
      beforeInitialize: false,
      afterInitialize: true,
      beforeAddLiquidity: false,
      afterAddLiquidity: false,
      beforeRemoveLiquidity: false,
      afterRemoveLiquidity: false,
      beforeSwap: true,
      afterSwap: false,
      beforeDonate: false,
      afterDonate: false,
      beforeSwapReturnDelta: true,
      afterSwapReturnDelta: false,
      afterAddLiquidityReturnDelta: false,
      afterRemoveLiquidityReturnDelta: false
    });
  }

  function _afterInitialize(address sender, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
    // Ensure pool contains the rebate token
    address token0 = Currency.unwrap(key.currency0);
    address token1 = Currency.unwrap(key.currency1);
    require(
        token0 == rebateToken || token1 == rebateToken,
        "ConfluxHook: Pool must contain rebate token"
    );
    
    _setPoolOwner(key, sender);
    isRebateEnabled[key.toId()] = true;
    isRebateToken0[key.toId()] = (token0 == rebateToken);
    return BaseHook.afterInitialize.selector;
  }

  function _beforeSwap(
    address,
    PoolKey calldata key,
    SwapParams calldata params,
    bytes calldata
  ) internal override nonReentrant returns (bytes4, BeforeSwapDelta, uint24) {
    // epochs disabled
    if (topOracle.epochDurationBlocks() == 0) {
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
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
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    address rebatePayer = topOracle.getCurrentTop();

    // Check if daemon is banned - if so, skip to next daemon
    if (registry.banned(rebatePayer)) {
      processedInTopEpoch++;
      topOracle.iterNextTop();
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Get the pre-computed rebate token position for this pool
    bool rebateTokenIs0 = isRebateToken0[key.toId()];

    // Is rebate enabled on the pool?
    if (!isRebateEnabled[key.toId()]) {
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    (bool okAmt, bytes memory rawAmt) =
      rebatePayer.staticcall(abi.encodeWithSelector(IDaemon.getRebateAmount.selector, block.number));
    if (!okAmt || rawAmt.length < 32) {
      registry.setActiveFromHook(rebatePayer, false);
      emit RebateDisabled(registry.addressToId(rebatePayer), "rebateAmount failed");
      processedInTopEpoch++;
      topOracle.iterNextTop();
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
    int128 daemonRebateAmount = abi.decode(rawAmt, (int128));
    if (daemonRebateAmount <= 0) {
      processedInTopEpoch++;
      topOracle.iterNextTop();
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Sync balance + attempt transferFrom
    poolManager.sync(Currency.wrap(rebateToken));
    uint256 balBefore = IERC20(rebateToken).balanceOf(address(poolManager));
    uint256 required = uint256(uint128(daemonRebateAmount));

    if (!_tryTransferFrom(rebateToken, rebatePayer, address(poolManager), required)) {
      registry.setActiveFromHook(rebatePayer, false);
      emit RebateDisabled(registry.addressToId(rebatePayer), "transfer failed");
      processedInTopEpoch++;
      topOracle.iterNextTop();
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    uint256 received = IERC20(rebateToken).balanceOf(address(poolManager)) - balBefore;
    if (received < required) {
      registry.setActiveFromHook(rebatePayer, false);
      emit RebateDisabled(registry.addressToId(rebatePayer), "insufficient received");
      processedInTopEpoch++;
      topOracle.iterNextTop();
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    poolManager.settle();
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
    bool rebateOnSpecified = (params.zeroForOne && rebateTokenIs0) || (!params.zeroForOne && !rebateTokenIs0);
    int128 specDelta = rebateOnSpecified ? -daemonRebateAmount : int128(0);
    int128 unspecDelta = rebateOnSpecified ? int128(0) : -daemonRebateAmount;

    processedInTopEpoch++;
    topOracle.iterNextTop();
    return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(specDelta, unspecDelta), 0);
  }

  // ---- Admin per-pool
  function toggleRebate(PoolKey calldata key) external onlyPoolOwner(key) {
    PoolId id = key.toId();
    isRebateEnabled[id] = !isRebateEnabled[id];
  }

  function getRebateState(PoolKey calldata key) external view returns (bool) {
    return isRebateEnabled[key.toId()];
  }

  function _tryTransferFrom(address token, address from, address to, uint256 amount) internal returns (bool) {
    (bool success, bytes memory data) =
      token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
    if (!success) return false;
    if (data.length == 0) return true; // non‑standard ERC20
    if (data.length == 32) return abi.decode(data, (bool));
    return false;
  }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DaemonRegistry} from "./base/DaemonRegistry.sol";
import {HookOwnable} from "./base/HookOwnable.sol";
import {PoolOwnable} from "./base/PoolOwnable.sol";
import {ChainLinkConsumer} from "./base/ChainLinkConsumer.sol";
import {IDaemon} from "./interfaces/IDaemon.sol";
import {LengthMismatch} from "./base/Errors.sol";

contract Conflux is BaseHook, DaemonRegistry, ChainLinkConsumer, HookOwnable, PoolOwnable {
  using PoolIdLibrary for PoolKey;

  // NOTE: ---------------------------------------------------------
  // state variables should typically be unique to a pool
  // a single hook contract should be able to service multiple pools
  // ---------------------------------------------------------------

  event RebateDisabled(uint16 indexed daemonId, string reason);
  event RebateExecuted(uint16 indexed daemonId, uint128 amount);
  event DaemonJobSuccess(uint16 indexed daemonId);
  event DaemonJobFailure(uint16 indexed daemonId, string reason);

  mapping(PoolId => uint256 count) public beforeSwapCount;
  mapping(PoolId => uint256 count) public afterSwapCount;

  mapping(PoolId => uint256 count) public beforeAddLiquidityCount;
  mapping(PoolId => uint256 count) public beforeRemoveLiquidityCount;

  // Per-pool rebate control
  mapping(PoolId => bool) public isRebateEnabled;
  mapping(uint16 => uint256 blockNumber) public lastTimeRebateCommitted; // daemon id -> block number

  address public immutable rebateToken; // Address of using stablecoin in current hook

  // Exhaustion control over a single top epoch
  uint64 private lastTopEpochSeen;
  uint16 private processedInTopEpoch;

  constructor(
    IPoolManager _poolManager,
    address router,
    bytes32 _donId,
    address _rebateToken
  ) BaseHook(_poolManager) ChainLinkConsumer(router, _donId) {
    rebateToken = _rebateToken;
    _setHookOwner(msg.sender);
  }

  function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return
      Hooks.Permissions({
        beforeInitialize: false,
        afterInitialize: true,
        beforeAddLiquidity: true,
        afterAddLiquidity: false,
        beforeRemoveLiquidity: true,
        afterRemoveLiquidity: false,
        beforeSwap: true,
        afterSwap: true,
        beforeDonate: false,
        afterDonate: false,
        beforeSwapReturnDelta: false,
        afterSwapReturnDelta: false,
        afterAddLiquidityReturnDelta: false,
        afterRemoveLiquidityReturnDelta: false
      });
  }

  // -----------------------------------------------
  // NOTE: see IHooks.sol for function documentation
  // -----------------------------------------------

  function _afterInitialize(address sender, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
    _setPoolOwner(key, sender);
    // Enable rebate for this pool by default on initialization
    isRebateEnabled[key.toId()] = true;
    return BaseHook.afterInitialize.selector;
  }

  function _beforeSwap(
    address,
    PoolKey calldata key,
    SwapParams calldata params,
    bytes calldata
  ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
    //
    // Should return DAEMON ADDRESS with TOP REBATE AMOUNT within current ERA
    // If epochs disabled (duration == 0), do not rebate
    if (epochDurationBlocks == 0) {
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Block-based epoch expiration: if expired, request refresh but continue using current top
    _maybeRequestTopUpdate();

    // Reset per-epoch counter on new top epoch
    if (topEpoch != lastTopEpochSeen) {
      lastTopEpochSeen = topEpoch;
      processedInTopEpoch = 0;
    }

    if (topCount == 0 || processedInTopEpoch >= topCount) {
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
    address rebate_payer = getCurrentTop();
    int128 daemonRebateAmount;

    // Add fetch_current top. If rebate was successful -> iter to next top id

    // ------------------------------------------------------

    PoolId id = key.toId();

    // Ensure pool contains the rebate token; otherwise do nothing gracefully
    address token0 = Currency.unwrap(key.currency0);
    address token1 = Currency.unwrap(key.currency1);
    if (!(token0 == rebateToken || token1 == rebateToken)) {
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
    bool isRebateToken0 = (token0 == rebateToken);

    // 1-st check that current pool allows rebate
    if (!isRebateEnabled[id]) {
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // 2-nd check that current daemon has valid rebate amount
    try IDaemon(rebate_payer).getRebateAmount(block.number) returns (int128 amount) {
      if (amount <= 0) {
        processedInTopEpoch++;
        iterNextTop();
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
      }
      daemonRebateAmount = amount;
    } catch {
      _setActive(rebate_payer, false);
      emit RebateDisabled(addressToId[rebate_payer], "Failed to fetch rebate amount");
      processedInTopEpoch++;
      iterNextTop();
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Now we don't need a separate delay options, because we define the needed delay as
    // rebateAmount = 0 (would be sorted at JS Chainlink Functions side)

    // Sync PoolManager's balance and check before transfer
    poolManager.sync(Currency.wrap(rebateToken));
    uint256 balanceBefore = IERC20(rebateToken).balanceOf(address(poolManager));
    uint256 requiredAmount = uint256(uint128(daemonRebateAmount));

    // Pull tokens into PoolManager with error handling (supports non-standard ERC20s)
    bool transferred = _tryTransferFrom(rebateToken, rebate_payer, address(poolManager), requiredAmount);
    if (!transferred) {
      _setActive(rebate_payer, false);
      emit RebateDisabled(addressToId[rebate_payer], "Transfer failed");
      processedInTopEpoch++;
      iterNextTop();
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Check actual received (fee-on-transfer guard)
    uint256 actualReceived = IERC20(rebateToken).balanceOf(address(poolManager)) - balanceBefore;
    if (actualReceived < requiredAmount) {
      _setActive(rebate_payer, false);
      emit RebateDisabled(addressToId[rebate_payer], "Insufficient rebate amount given");
      processedInTopEpoch++;
      iterNextTop();
      return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Settle with PoolManager and update state
    poolManager.settle();
    lastTimeRebateCommitted[addressToId[rebate_payer]] = block.number;
    emit RebateExecuted(addressToId[rebate_payer], uint128(actualReceived));

    // Execute daemon job with 300k gas stipend; rebate is paid regardless of outcome
    try IDaemon(rebate_payer).accomplishDaemonJob{gas: 300_000}() {
      emit DaemonJobSuccess(addressToId[rebate_payer]);
    } catch Error(string memory reason) {
      emit DaemonJobFailure(addressToId[rebate_payer], reason);
    } catch {
      emit DaemonJobFailure(addressToId[rebate_payer], "unknown error");
    }

    // Calculate deltas based on swap direction
    // Always rebate in rebateToken regardless of swap direction
    bool rebateOnSpecified = (params.zeroForOne && isRebateToken0) || (!params.zeroForOne && !isRebateToken0);
    int128 specDelta = rebateOnSpecified ? -daemonRebateAmount : int128(0);
    int128 unspecDelta = rebateOnSpecified ? int128(0) : -daemonRebateAmount;

    processedInTopEpoch++;
    iterNextTop();
    return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(specDelta, unspecDelta), 0);
  }

  function _afterSwap(
    address,
    PoolKey calldata key,
    SwapParams calldata,
    BalanceDelta,
    bytes calldata
  ) internal override returns (bytes4, int128) {
    afterSwapCount[key.toId()]++;
    return (BaseHook.afterSwap.selector, 0);
  }

  function _beforeAddLiquidity(
    address,
    PoolKey calldata key,
    ModifyLiquidityParams calldata,
    bytes calldata
  ) internal override returns (bytes4) {
    beforeAddLiquidityCount[key.toId()]++;
    return BaseHook.beforeAddLiquidity.selector;
  }

  function _beforeRemoveLiquidity(
    address,
    PoolKey calldata key,
    ModifyLiquidityParams calldata,
    bytes calldata
  ) internal override returns (bytes4) {
    beforeRemoveLiquidityCount[key.toId()]++;
    return BaseHook.beforeRemoveLiquidity.selector;
  }

  // ---- Internal helpers ----
  function _tryTransferFrom(address token, address from, address to, uint256 amount) internal returns (bool) {
    (bool success, bytes memory data) = token.call(
      abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
    );
    if (!success) return false;
    if (data.length == 0) return true; // non-standard ERC20
    if (data.length == 32) return abi.decode(data, (bool));
    return false;
  }

  // ---- Admin APIs (hook owner) and user-facing single-activation ----
  // Initialize consumer via hook owner
  function startRebateEpochs(
    uint256 initialEpochDurationBlocks,
    string calldata source,
    FunctionsRequest.Location secretsLocation,
    bytes calldata encryptedSecretsReference,
    string[] calldata args,
    bytes[] calldata bytesArgs,
    uint64 subscriptionId,
    uint32 callbackGasLimit
  ) external onlyHookOwner {
    _startRebateEpochs(
      initialEpochDurationBlocks,
      source,
      secretsLocation,
      encryptedSecretsReference,
      args,
      bytesArgs,
      subscriptionId,
      callbackGasLimit
    );
  }

  // Set epoch length (in blocks) with hook-owner restriction
  function setEpochLength(uint256 blocks_) external onlyHookOwner {
    setEpochDurationBlocks(blocks_);
  }

  // Add many daemons with their owners (admin only)
  function addMany(address[] calldata daemonAddresses, address[] calldata owners) external onlyHookOwner {
    if (daemonAddresses.length != owners.length) revert LengthMismatch();
    for (uint256 i = 0; i < daemonAddresses.length; i++) {
      _add(daemonAddresses[i], owners[i]);
    }
  }

  // Add single daemon with its owner (admin only)
  function add(address daemon, address owner) external onlyHookOwner {
    _add(daemon, owner);
  }

  // Bulk activate/deactivate by admin owner
  function activateMany(address[] calldata daemonAddresses) external onlyHookOwner {
    _activateMany(daemonAddresses);
  }

  function deactivateMany(address[] calldata daemonAddresses) external onlyHookOwner {
    _deactivateMany(daemonAddresses);
  }

  // Ban daemon (admin only): disables and prevents future activation by owner
  function banDaemon(address daemon) external onlyHookOwner {
    _banDaemon(daemon);
  }

  // Note: single activation functions are inherited:
  // - setActive(address daemon, bool isActive) -> only daemon owner
  // - setActiveById(uint16 daemonId, bool isActive) -> only daemon owner

  // ---- Per-pool rebate admin ----
  function toggleRebate(PoolKey calldata key) external onlyPoolOwner(key) {
    PoolId id = key.toId();
    bool newState = !isRebateEnabled[id];
    isRebateEnabled[id] = newState;
  }

  function getRebateState(PoolKey calldata key) external view returns (bool) {
    return isRebateEnabled[key.toId()];
  }
}

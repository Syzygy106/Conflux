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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDaemonManager} from "./interfaces/IDaemonManager.sol";
import {IChainlinkOracle} from "./interfaces/IChainlinkOracle.sol";
import {IDaemon} from "./interfaces/IDaemon.sol";
import {HookOwnable} from "./base/HookOwnable.sol";
import {PoolOwnable} from "./base/PoolOwnable.sol";

contract ConfluxModular is BaseHook, HookOwnable, PoolOwnable {
    using PoolIdLibrary for PoolKey;

    // Events
    event RebateDisabled(uint16 indexed daemonId, string reason);
    event RebateExecuted(uint16 indexed daemonId, uint128 amount);
    event DaemonJobSuccess(uint16 indexed daemonId);
    event DaemonJobFailure(uint16 indexed daemonId, string reason);

    // Hook counters
    mapping(PoolId => uint256) public beforeSwapCount;
    mapping(PoolId => uint256) public afterSwapCount;
    mapping(PoolId => uint256) public beforeAddLiquidityCount;
    mapping(PoolId => uint256) public beforeRemoveLiquidityCount;

    // Per-pool rebate control
    mapping(PoolId => bool) public isRebateEnabled;
    mapping(uint16 => uint256) public lastTimeRebateCommitted; // daemon id -> block number

    // External contracts
    IDaemonManager public immutable daemonManager;
    IChainlinkOracle public immutable chainlinkOracle;
    address public immutable rebateToken;

    // Exhaustion control over a single top epoch
    uint64 private lastTopEpochSeen;
    uint16 private processedInTopEpoch;

    constructor(
        IPoolManager _poolManager,
        address _daemonManager,
        address _chainlinkOracle,
        address _rebateToken
    ) BaseHook(_poolManager) {
        daemonManager = IDaemonManager(_daemonManager);
        chainlinkOracle = IChainlinkOracle(_chainlinkOracle);
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

    function _afterInitialize(address sender, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        _setPoolOwner(key, sender);
        isRebateEnabled[key.toId()] = true;
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Note: beforeSwapCount is NOT incremented in original Conflux
        
        // Check if epochs are enabled
        if (chainlinkOracle.getEpochDurationBlocks() == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Maybe request top update
        chainlinkOracle.maybeRequestTopUpdate();

        // Reset per-epoch counter on new top epoch
        uint64 currentTopEpoch = chainlinkOracle.getTopEpoch();
        if (currentTopEpoch != lastTopEpochSeen) {
            lastTopEpochSeen = currentTopEpoch;
            processedInTopEpoch = 0;
        }

        uint16 topCount = chainlinkOracle.getTopCount();
        if (topCount == 0 || processedInTopEpoch >= topCount) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        address rebatePayer = chainlinkOracle.getCurrentTopDaemon();
        
        PoolId id = key.toId();

        // Ensure pool contains the rebate token
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        if (!(token0 == rebateToken || token1 == rebateToken)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        bool isRebateToken0 = (token0 == rebateToken);

        // Check that current pool allows rebate
        if (!isRebateEnabled[id]) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Check that current daemon has valid rebate amount
        int128 daemonRebateAmount;
        try IDaemon(rebatePayer).getRebateAmount(block.number) returns (int128 amount) {
            if (amount <= 0) {
                processedInTopEpoch++;
                chainlinkOracle.iterateToNextTop();
                return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
            daemonRebateAmount = amount;
        } catch {
            uint16 daemonId = daemonManager.getDaemonId(rebatePayer);
            emit RebateDisabled(daemonId, "Failed to fetch rebate amount");
            processedInTopEpoch++;
            chainlinkOracle.iterateToNextTop();
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Execute rebate transfer
        poolManager.sync(Currency.wrap(rebateToken));
        uint256 balanceBefore = IERC20(rebateToken).balanceOf(address(poolManager));
        uint256 requiredAmount = uint256(uint128(daemonRebateAmount));

        bool transferred = _tryTransferFrom(rebateToken, rebatePayer, address(poolManager), requiredAmount);
        if (!transferred) {
            uint16 daemonId = daemonManager.getDaemonId(rebatePayer);
            emit RebateDisabled(daemonId, "Transfer failed");
            processedInTopEpoch++;
            chainlinkOracle.iterateToNextTop();
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 actualReceived = IERC20(rebateToken).balanceOf(address(poolManager)) - balanceBefore;
        if (actualReceived < requiredAmount) {
            uint16 daemonId = daemonManager.getDaemonId(rebatePayer);
            emit RebateDisabled(daemonId, "Insufficient rebate amount given");
            processedInTopEpoch++;
            chainlinkOracle.iterateToNextTop();
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        poolManager.settle();
        uint16 daemonId = daemonManager.getDaemonId(rebatePayer);
        lastTimeRebateCommitted[daemonId] = block.number;
        emit RebateExecuted(daemonId, uint128(actualReceived));

        // Execute daemon job
        try IDaemon(rebatePayer).accomplishDaemonJob{gas: 300_000}() {
            emit DaemonJobSuccess(daemonId);
        } catch Error(string memory reason) {
            emit DaemonJobFailure(daemonId, reason);
        } catch {
            emit DaemonJobFailure(daemonId, "unknown error");
        }

        // Calculate deltas
        bool rebateOnSpecified = (params.zeroForOne && isRebateToken0) || (!params.zeroForOne && !isRebateToken0);
        int128 specDelta = rebateOnSpecified ? -daemonRebateAmount : int128(0);
        int128 unspecDelta = rebateOnSpecified ? int128(0) : -daemonRebateAmount;

        processedInTopEpoch++;
        chainlinkOracle.iterateToNextTop();
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

    function _tryTransferFrom(address token, address from, address to, uint256 amount) internal returns (bool) {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        if (!success) return false;
        if (data.length == 0) return true;
        if (data.length == 32) return abi.decode(data, (bool));
        return false;
    }

    // Pool rebate management
    function toggleRebate(PoolKey calldata key) external onlyPoolOwner(key) {
        PoolId id = key.toId();
        isRebateEnabled[id] = !isRebateEnabled[id];
    }

    function getRebateState(PoolKey calldata key) external view returns (bool) {
        return isRebateEnabled[key.toId()];
    }
}

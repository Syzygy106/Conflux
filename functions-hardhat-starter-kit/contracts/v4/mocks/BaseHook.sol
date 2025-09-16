// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Mock BaseHook for testing purposes
abstract contract BaseHook {
    address public immutable poolManager;
    
    constructor(address _poolManager) {
        poolManager = _poolManager;
    }
    
    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);
    
    // Hook function selectors
    bytes4 public constant beforeInitialize = bytes4(keccak256("beforeInitialize(address,PoolKey,uint160,int24)"));
    bytes4 public constant afterInitialize = bytes4(keccak256("afterInitialize(address,PoolKey,uint160,int24)"));
    bytes4 public constant beforeAddLiquidity = bytes4(keccak256("beforeAddLiquidity(address,PoolKey,ModifyLiquidityParams,bytes)"));
    bytes4 public constant afterAddLiquidity = bytes4(keccak256("afterAddLiquidity(address,PoolKey,ModifyLiquidityParams,bytes)"));
    bytes4 public constant beforeRemoveLiquidity = bytes4(keccak256("beforeRemoveLiquidity(address,PoolKey,ModifyLiquidityParams,bytes)"));
    bytes4 public constant afterRemoveLiquidity = bytes4(keccak256("afterRemoveLiquidity(address,PoolKey,ModifyLiquidityParams,bytes)"));
    bytes4 public constant beforeSwap = bytes4(keccak256("beforeSwap(address,PoolKey,SwapParams,bytes)"));
    bytes4 public constant afterSwap = bytes4(keccak256("afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes)"));
    bytes4 public constant beforeDonate = bytes4(keccak256("beforeDonate(address,PoolKey,uint256,uint256,bytes)"));
    bytes4 public constant afterDonate = bytes4(keccak256("afterDonate(address,PoolKey,uint256,uint256,bytes)"));
    bytes4 public constant beforeSwapReturnDelta = bytes4(keccak256("beforeSwapReturnDelta(address,PoolKey,SwapParams,bytes)"));
    bytes4 public constant afterSwapReturnDelta = bytes4(keccak256("afterSwapReturnDelta(address,PoolKey,SwapParams,BalanceDelta,bytes)"));
    bytes4 public constant afterAddLiquidityReturnDelta = bytes4(keccak256("afterAddLiquidityReturnDelta(address,PoolKey,ModifyLiquidityParams,bytes)"));
    bytes4 public constant afterRemoveLiquidityReturnDelta = bytes4(keccak256("afterRemoveLiquidityReturnDelta(address,PoolKey,ModifyLiquidityParams,bytes)"));
}

// Mock Hooks library
library Hooks {
    struct Permissions {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeAddLiquidity;
        bool afterAddLiquidity;
        bool beforeRemoveLiquidity;
        bool afterRemoveLiquidity;
        bool beforeSwap;
        bool afterSwap;
        bool beforeDonate;
        bool afterDonate;
        bool beforeSwapReturnDelta;
        bool afterSwapReturnDelta;
        bool afterAddLiquidityReturnDelta;
        bool afterRemoveLiquidityReturnDelta;
    }
}

// Mock types
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hook;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
}

struct BalanceDelta {
    int128 amount0;
    int128 amount1;
}

struct BeforeSwapDelta {
    int128 amount0Delta;
    int128 amount1Delta;
}

library BeforeSwapDeltaLibrary {
    function ZERO_DELTA() internal pure returns (BeforeSwapDelta memory) {
        return BeforeSwapDelta(0, 0);
    }
}

function toBeforeSwapDelta(int128 amount0Delta, int128 amount1Delta) pure returns (BeforeSwapDelta memory) {
    return BeforeSwapDelta(amount0Delta, amount1Delta);
}

// Mock Currency
type Currency is address;

// Mock PoolId
type PoolId is bytes32;

library PoolIdLibrary {
    function toId(PoolKey memory key) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(key)));
    }
}

// Mock IPoolManager
interface IPoolManager {
    function sync(Currency currency) external;
    function settle() external;
}

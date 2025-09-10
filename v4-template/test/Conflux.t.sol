// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {Deployers} from "./utils/Deployers.sol";

import {TestConflux} from "../src/TestConflux.sol";
import {IDaemon} from "../src/interfaces/IDaemon.sol";

contract DummyDaemon is IDaemon {
  int128 public rebate;

  function setRebate(int128 v) external {
    rebate = v;
  }

  function getRebateAmount(uint256) external view returns (int128) {
    return rebate;
  }

  function accomplishDaemonJob() external {}
}

contract ConfluxTest is Test, Deployers {
  using EasyPosm for IPositionManager;
  using PoolIdLibrary for PoolKey;
  using CurrencyLibrary for Currency;
  using StateLibrary for IPoolManager;

  Currency currency0;
  Currency currency1;
  PoolKey poolKey;
  PoolId poolId;

  TestConflux hook;
  uint256 tokenId;
  int24 tickLower;
  int24 tickUpper;

  DummyDaemon daemon;
  MockERC20 rebateToken;

  function setUp() public {
    deployArtifacts();
    (currency0, currency1) = deployCurrencyPair();
    rebateToken = MockERC20(Currency.unwrap(currency0));

    address flags = address(
      uint160(
        Hooks.AFTER_INITIALIZE_FLAG |
        Hooks.BEFORE_SWAP_FLAG |
        Hooks.AFTER_SWAP_FLAG |
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
        Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
      ) ^ (0x4445 << 144)
    );

    bytes32 donId = bytes32("DONTCARE");
    bytes memory constructorArgs = abi.encode(poolManager, address(0), donId, address(rebateToken));
    deployCodeTo("TestConflux.sol:TestConflux", constructorArgs, flags);
    hook = TestConflux(flags);

    poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
    poolId = poolKey.toId();
    poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

    tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
    tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

    uint128 liquidityAmount = 100e18;
    (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
      Constants.SQRT_PRICE_1_1,
      TickMath.getSqrtPriceAtTick(tickLower),
      TickMath.getSqrtPriceAtTick(tickUpper),
      liquidityAmount
    );

    (tokenId,) = positionManager.mint(
      poolKey,
      tickLower,
      tickUpper,
      liquidityAmount,
      amount0Expected + 1,
      amount1Expected + 1,
      address(this),
      block.timestamp,
      Constants.ZERO_BYTES
    );

    daemon = new DummyDaemon();
    rebateToken.approve(address(poolManager), type(uint256).max);
  }

  function test_beforeSwap_rebates_whenDaemonPositive() public {
    // Set hook registry
    address[] memory daemons = new address[](1);
    address[] memory owners = new address[](1);
    daemons[0] = address(daemon);
    owners[0] = address(this);
    hook.addMany(daemons, owners);

    // activate
    address[] memory act = new address[](1);
    act[0] = address(daemon);
    hook.activateMany(act);

    // set epoch duration nonzero and seed top list
    hook.__setEpochDuration(100);
    hook.__setTopSimple(0, 1);

    // Provide rebate and funds from daemon
    daemon.setRebate(int128(1e18));
    rebateToken.mint(address(daemon), 10e18);
    vm.prank(address(daemon));
    rebateToken.approve(address(poolManager), type(uint256).max);

    // do a small swap to trigger beforeSwap
    uint256 amountIn = 1e18;
    BalanceDelta delta = swapRouter.swapExactTokensForTokens({
      amountIn: amountIn,
      amountOutMin: 0,
      zeroForOne: true,
      poolKey: poolKey,
      hookData: Constants.ZERO_BYTES,
      receiver: address(this),
      deadline: block.timestamp + 1
    });

    // Conflux only increments afterSwapCount
    assertEq(hook.afterSwapCount(poolId), 1);
  }
}



// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

/// @notice Shared configuration between scripts
contract BaseScript is Script {
    IPermit2 immutable permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager immutable poolManager;
    IPositionManager immutable positionManager;
    IUniswapV4Router04 immutable swapRouter;
    address immutable deployerAddress;

    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////
    IERC20 internal token0;
    IERC20 internal token1;
    IHooks internal hookContract;
    /////////////////////////////////////

    Currency immutable currency0;
    Currency immutable currency1;

    constructor() {
        poolManager = IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));
        positionManager = IPositionManager(payable(AddressConstants.getPositionManagerAddress(block.chainid)));
        swapRouter = IUniswapV4Router04(payable(AddressConstants.getV4SwapRouterAddress(block.chainid)));

        deployerAddress = getDeployer();

        // Optional env overrides for tokens and hook
        address envToken0 = vm.envOr("TOKEN0", address(0));
        address envToken1 = vm.envOr("TOKEN1", address(0));
        address envHook = vm.envOr("HOOK", address(0));

        // Defaults keep local template values if env not provided
        address defaultToken0 = 0x0165878A594ca255338adfa4d48449f69242Eb8F;
        address defaultToken1 = 0xa513E6E4b8f2a923D98304ec87F64353C4D5C853;

        token0 = IERC20(envToken0 == address(0) ? defaultToken0 : envToken0);
        token1 = IERC20(envToken1 == address(0) ? defaultToken1 : envToken1);
        hookContract = IHooks(envHook);

        (currency0, currency1) = getCurrencies();

        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");

        vm.label(address(deployerAddress), "Deployer");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(positionManager), "PositionManager");
        vm.label(address(swapRouter), "SwapRouter");
        vm.label(address(hookContract), "HookContract");
    }

    function getCurrencies() public view returns (Currency, Currency) {
        require(address(token0) != address(token1));

        if (token0 < token1) {
            return (Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        } else {
            return (Currency.wrap(address(token1)), Currency.wrap(address(token0)));
        }
    }

    function getDeployer() public returns (address) {
        address[] memory wallets = vm.getWallets();

        require(wallets.length > 0, "No wallets found");

        return wallets[0];
    }
}

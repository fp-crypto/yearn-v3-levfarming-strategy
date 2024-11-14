// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ICLPool} from "@slipstream/core/interfaces/ICLPool.sol";
import {ICLFactory} from "@slipstream/core/interfaces/ICLFactory.sol";
import {Simulate, TickMath} from "./CLSwapSimulatorCore.sol";
import {ISwapRouter} from "@slipstream/periphery/interfaces/ISwapRouter.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

interface ISwapRouterWithFactory is ISwapRouter {
    function factory() external view returns (address);
}

/// @title Library for simulating swaps on CL aka slipstream (Uniswap v3 fork)
library CLSwapSimulator {
    function simulateExactInputSingle(
        ISwapRouter router,
        ISwapRouter.ExactInputSingleParams memory params
    ) internal view returns (uint256 amountOut) {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        ICLPool pool = getPool(router, params.tokenIn, params.tokenOut, 1);
        (int256 _amount0, int256 _amount1) = Simulate.simulateSwap(
            pool,
            zeroForOne,
            int256(params.amountIn),
            params.sqrtPriceLimitX96 == 0
                ? (
                    zeroForOne
                        ? TickMath.MIN_SQRT_RATIO + 1
                        : TickMath.MAX_SQRT_RATIO - 1
                )
                : params.sqrtPriceLimitX96
        );
        return uint256(-(zeroForOne ? _amount1 : _amount0));
    }

    function getPool(
        ISwapRouter router,
        address tokenA,
        address tokenB,
        int24 tickSpacing
    ) private view returns (ICLPool) {
        return
            ICLPool(
                computeAddressPoolAddress(
                    ISwapRouterWithFactory(address(router)).factory(),
                    getPoolKey(tokenA, tokenB, tickSpacing)
                )
            );
    }

    struct PoolKey {
        address token0;
        address token1;
        int24 tickSpacing;
    }

    /// @notice Returns PoolKey: the ordered tokens with the matched fee levels
    /// @param tokenA The first token of a pool, unsorted
    /// @param tokenB The second token of a pool, unsorted
    /// @param tickSpacing The tick spacing of the pool
    /// @return Poolkey The pool details with ordered token0 and token1 assignments
    function getPoolKey(
        address tokenA,
        address tokenB,
        int24 tickSpacing
    ) internal pure returns (PoolKey memory) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return
            PoolKey({token0: tokenA, token1: tokenB, tickSpacing: tickSpacing});
    }

    /// @notice Deterministically computes the pool address given the factory and PoolKey
    /// @param factory The CL factory contract address
    /// @param key The PoolKey
    /// @return pool The contract address of the V3 pool
    function computeAddressPoolAddress(
        address factory,
        PoolKey memory key
    ) internal view returns (address pool) {
        require(key.token0 < key.token1);
        pool = Clones.predictDeterministicAddress(
            ICLFactory(factory).poolImplementation(),
            keccak256(abi.encode(key.token0, key.token1, key.tickSpacing)),
            factory
        );
    }
}

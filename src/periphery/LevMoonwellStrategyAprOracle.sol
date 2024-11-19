// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {LevCompStrategyAprOracle, ERC20} from "./LevCompStrategyAprOracle.sol";
import {ILevMoonwellStrategyInterface} from "../interfaces/ILevMoonwellStrategyInterface.sol";
import {IMultiRewardDistributor} from "../interfaces/moonwell/IMultiRewardDistributor.sol";
import {CTokenI} from "../interfaces/compound/CTokenI.sol";
import {ComptrollerI} from "../interfaces/moonwell/ComptrollerI.sol";
import {IRouter as IAeroRouter} from "../interfaces/velo/IRouter.sol";
import {CLSwapSimulator, ISwapRouter} from "../libraries/CLSwapSimulator.sol";

contract LevMoonwellStrategyAprOracle is LevCompStrategyAprOracle {
    ERC20 public constant WETH =
        ERC20(0x4200000000000000000000000000000000000006);
    ERC20 public constant USDC =
        ERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    ERC20 public constant WELL =
        ERC20(0xA88594D404727625A9437C3f886C7643872296AE);
    IAeroRouter public constant AERODROME_ROUTER =
        IAeroRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);
    ISwapRouter public constant SLIPSTREAM_ROUTER =
        ISwapRouter(0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5);
    address private constant AERODROME_FACTORY =
        0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    constructor() LevCompStrategyAprOracle() {}

    function getAprFromRewards(
        address _strategy,
        uint256 _ourSupply,
        uint256 _ourBorrows,
        uint256 _cash,
        uint256 _totalBorrows
    ) internal view override returns (uint256 _apr) {
        CTokenI cToken = CTokenI(
            ILevMoonwellStrategyInterface(_strategy).C_TOKEN()
        );

        IMultiRewardDistributor _rewardDistributor = ComptrollerI(
            ILevMoonwellStrategyInterface(_strategy).COMPTROLLER()
        ).rewardDistributor();

        IMultiRewardDistributor.MarketConfig
            memory _marketConfigWeth = _rewardDistributor.getConfigForMarket(
                cToken,
                address(WELL)
            );

        if (
            _marketConfigWeth.supplyEmissionsPerSec != 0 ||
            _marketConfigWeth.borrowEmissionsPerSec != 0
        ) {
            uint256 _wellPerSecond = (_ourSupply *
                _marketConfigWeth.supplyEmissionsPerSec) /
                (_cash + _totalBorrows - cToken.totalReserves());
            _wellPerSecond +=
                (_ourBorrows * _marketConfigWeth.borrowEmissionsPerSec) /
                _totalBorrows;

            uint256 _wethRewardsInAssetPerYear = ((estimatedWellInAsset(
                _wellPerSecond * 7 days,
                ILevMoonwellStrategyInterface(_strategy).asset(),
                ILevMoonwellStrategyInterface(_strategy)
                    .wethToAssetSwapTickSpacing()
            ) * 365 days) / 7 days);

            _apr = (_wethRewardsInAssetPerYear * 1e18) / (_ourSupply - _ourBorrows);
        }

        IMultiRewardDistributor.MarketConfig
            memory _marketConfgidUsdc = _rewardDistributor.getConfigForMarket(
                cToken,
                address(USDC)
            );

        if (_marketConfgidUsdc.supplyEmissionsPerSec != 0 || _marketConfgidUsdc.borrowEmissionsPerSec != 0) {
            uint256 _usdcPerSecond = (_ourSupply *
                _marketConfgidUsdc.supplyEmissionsPerSec) /
                (_cash + _totalBorrows - cToken.totalReserves());
            _usdcPerSecond +=
                (_ourBorrows * _marketConfgidUsdc.borrowEmissionsPerSec) /
                _totalBorrows;

            uint256 _usdcRewardsInAssetPerYear;

            if (
                ILevMoonwellStrategyInterface(_strategy).asset() ==
                address(USDC)
            ) {
                _usdcRewardsInAssetPerYear = _usdcPerSecond * 365 days;
            } else {
                _usdcRewardsInAssetPerYear =
                    (estimatedUsdcInAsset(
                        _usdcPerSecond * 7 days,
                        ILevMoonwellStrategyInterface(_strategy).asset(),
                        ILevMoonwellStrategyInterface(_strategy)
                            .wethToAssetSwapTickSpacing()
                    ) * 365 days) /
                    7 days;
            }

            _apr += (_usdcRewardsInAssetPerYear * 1e18) / (_ourSupply - _ourBorrows);
        }
    }

    function estimatedWellInAsset(
        uint256 _wellAmount,
        address _asset,
        int24 _tickSpacing
    ) private view returns (uint256) {
        if (_wellAmount == 0 || _tickSpacing == 0) {
            return 0;
        }

        IAeroRouter.Route[] memory routes = new IAeroRouter.Route[](1);
        routes[0].from = address(WELL);
        routes[0].to = address(WETH);
        routes[0].factory = AERODROME_FACTORY;

        uint256[] memory outs = AERODROME_ROUTER.getAmountsOut(
            _wellAmount,
            routes
        );

        if (_asset == address(WETH)) return outs[outs.length - 1];
        if (outs[outs.length - 1] == 0) return 0;

        return
            CLSwapSimulator.simulateExactInputSingle(
                ISwapRouter(SLIPSTREAM_ROUTER),
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(WETH),
                    tokenOut: _asset,
                    tickSpacing: _tickSpacing,
                    recipient: address(0),
                    deadline: block.timestamp,
                    amountIn: outs[outs.length - 1],
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    function estimatedUsdcInAsset(
        uint256 _usdcAmount,
        address _asset,
        int24 _tickSpacing
    ) private view returns (uint256) {
        if (_usdcAmount == 0 || _tickSpacing == 0) {
            return 0;
        }

        return
            CLSwapSimulator.simulateExactInputSingle(
                ISwapRouter(SLIPSTREAM_ROUTER),
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(USDC),
                    tokenOut: _asset,
                    tickSpacing: _tickSpacing,
                    recipient: address(0),
                    deadline: block.timestamp,
                    amountIn: _usdcAmount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
    }
}

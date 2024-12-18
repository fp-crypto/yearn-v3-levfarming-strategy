// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {LevCompStrategyAprOracle} from "./LevCompStrategyAprOracle.sol";
import {ILevMoonwellStrategyInterface} from "../interfaces/ILevMoonwellStrategyInterface.sol";
import {IMultiRewardDistributor} from "../interfaces/moonwell/IMultiRewardDistributor.sol";
import {CTokenI} from "../interfaces/compound/CTokenI.sol";
import {ComptrollerI} from "../interfaces/moonwell/ComptrollerI.sol";
import {IRouter as IAeroRouter} from "../interfaces/velo/IRouter.sol";
import {CLSwapSimulator, ISwapRouter} from "../libraries/CLSwapSimulator.sol";

import "forge-std/console.sol";

contract LevMoonwellStrategyAprOracle is LevCompStrategyAprOracle {
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WELL = 0xA88594D404727625A9437C3f886C7643872296AE;
    IAeroRouter public constant AERODROME_ROUTER =
        IAeroRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);
    ISwapRouter public constant SLIPSTREAM_ROUTER =
        ISwapRouter(0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5);
    address private constant AERODROME_FACTORY =
        0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    constructor() LevCompStrategyAprOracle() {
        name = "LevMoonwell APR Oracle";
    }

    function getAprFromRewards(
        address _strategy,
        uint256 _ourSupply,
        uint256 _ourBorrows,
        uint256 _cash,
        uint256 _totalBorrows
    ) internal view override returns (uint256 _apr) {
        CTokenI _cToken = CTokenI(
            ILevMoonwellStrategyInterface(_strategy).C_TOKEN()
        );

        IMultiRewardDistributor _rewardDistributor = ComptrollerI(
            ILevMoonwellStrategyInterface(_strategy).COMPTROLLER()
        ).rewardDistributor();

        uint256 _totalReserves = _cToken.totalReserves();

        IMultiRewardDistributor.MarketConfig
            memory _marketConfig = _rewardDistributor.getConfigForMarket(
                _cToken,
                WELL
            );

        _apr += _getRewardApr(
            _strategy,
            _marketConfig,
            WELL,
            ILevMoonwellStrategyInterface(_strategy)
                .wethToAssetSwapTickSpacing(),
            _ourSupply,
            _ourBorrows,
            _cash,
            _totalBorrows,
            _totalReserves
        );

        _marketConfig = _rewardDistributor.getConfigForMarket(_cToken, USDC);

        _apr += _getRewardApr(
            _strategy,
            _marketConfig,
            USDC,
            ILevMoonwellStrategyInterface(_strategy)
                .usdcToAssetSwapTickSpacing(),
            _ourSupply,
            _ourBorrows,
            _cash,
            _totalBorrows,
            _totalReserves
        );
    }

    function _getRewardApr(
        address _asset,
        IMultiRewardDistributor.MarketConfig memory _marketConfig,
        address _rewardToken,
        int24 _rewardSwapTickSpacing,
        uint256 _ourSupply,
        uint256 _ourBorrows,
        uint256 _cash,
        uint256 _totalBorrows,
        uint256 _totalReserves
    ) private view returns (uint256) {
        return 0;

        // if (
        //     _marketConfig.supplyEmissionsPerSec == 0 &&
        //     _marketConfig.borrowEmissionsPerSec == 0
        // ) return 0;

        // uint256 _rewardInAssetPerYear;

        // uint256 _rewardPerSecond = (_ourSupply *
        //     _marketConfig.supplyEmissionsPerSec) /
        //     (_cash + _totalBorrows - _totalReserves);
        // _rewardPerSecond +=
        //     (_ourBorrows * _marketConfig.borrowEmissionsPerSec) /
        //     _totalBorrows;

        // if (_asset == _rewardToken) {
        //     _rewardInAssetPerYear = _rewardPerSecond * 365 days;
        // } else {
        //     _rewardInAssetPerYear =
        //         (estimatedRewardInAsset(
        //             _rewardToken,
        //             _rewardPerSecond * 7 days,
        //             _asset,
        //             _rewardSwapTickSpacing
        //         ) * 365 days) /
        //         7 days;
        // }

        // return (_rewardInAssetPerYear * 1e18) / (_ourSupply - _ourBorrows);
    }

    function estimatedRewardInAsset(
        address _rewardToken,
        uint256 _rewardAmount,
        address _asset,
        int24 _tickSpacing
    ) private view returns (uint256) {
        if (_rewardToken == WELL) {
            return estimatedWellInAsset(_rewardAmount, _asset, _tickSpacing);
        } else {
            return estimatedUsdcInAsset(_rewardAmount, _asset, _tickSpacing);
        }
    }

    function estimatedWellInAsset(
        uint256 _wellAmount,
        address _asset,
        int24 _tickSpacing
    ) private view returns (uint256) {
        if (_wellAmount == 0) {
            return 0;
        }

        IAeroRouter.Route[] memory routes = new IAeroRouter.Route[](1);
        routes[0].from = WELL;
        routes[0].to = WETH;
        routes[0].factory = AERODROME_FACTORY;

        uint256[] memory outs = AERODROME_ROUTER.getAmountsOut(
            _wellAmount,
            routes
        );

        if (_asset == WETH) return outs[outs.length - 1];
        if (outs[outs.length - 1] == 0 || _tickSpacing == 0) return 0;

        return
            CLSwapSimulator.simulateExactInputSingle(
                ISwapRouter(SLIPSTREAM_ROUTER),
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: WETH,
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
                    tokenIn: USDC,
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

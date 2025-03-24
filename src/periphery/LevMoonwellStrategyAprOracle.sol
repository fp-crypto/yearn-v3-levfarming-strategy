// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {LevCompStrategyAprOracle} from "./LevCompStrategyAprOracle.sol";
import {ILevMoonwellStrategyInterface} from "../interfaces/ILevMoonwellStrategyInterface.sol";
import {IMultiRewardDistributor} from "../interfaces/moonwell/IMultiRewardDistributor.sol";
import {CErc20I} from "../interfaces/compound/CErc20I.sol";
import {ComptrollerI} from "../interfaces/moonwell/ComptrollerI.sol";
import {IRouter as IAeroRouter} from "../interfaces/velo/IRouter.sol";
import {CLSwapSimulator, ISwapRouter} from "../libraries/CLSwapSimulator.sol";

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
        AprFromRewardsParams memory _params
    ) internal view override returns (uint256 _apr) {
        CErc20I _cToken = CErc20I(_params.cToken);

        IMultiRewardDistributor _rewardDistributor = ComptrollerI(
            _cToken.comptroller()
        ).rewardDistributor();

        RewardAprParams memory rewardAprParams = RewardAprParams({
            asset: CErc20I(_params.cToken).underlying(),
            marketConfig: _rewardDistributor.getConfigForMarket(_cToken, WELL),
            rewardToken: WELL,
            rewardSwapTickSpacing: ILevMoonwellStrategyInterface(
                _params.strategy
            ).wethToAssetSwapTickSpacing(),
            ourSupply: _params.ourSupply,
            ourBorrows: _params.ourBorrows,
            cash: _params.cash,
            totalBorrows: _params.totalBorrows,
            totalReserves: _cToken.totalReserves()
        });

        _apr += _getRewardApr(rewardAprParams);

        rewardAprParams.marketConfig = _rewardDistributor.getConfigForMarket(
            _cToken,
            USDC
        );
        rewardAprParams.rewardToken = USDC;
        rewardAprParams.rewardSwapTickSpacing = ILevMoonwellStrategyInterface(
            _params.strategy
        ).usdcToAssetSwapTickSpacing();

        _apr += _getRewardApr(rewardAprParams);
    }

    struct RewardAprParams {
        address asset;
        IMultiRewardDistributor.MarketConfig marketConfig;
        address rewardToken;
        int24 rewardSwapTickSpacing;
        uint256 ourSupply;
        uint256 ourBorrows;
        uint256 cash;
        uint256 totalBorrows;
        uint256 totalReserves;
    }

    function _getRewardApr(
        RewardAprParams memory _params
    ) private view returns (uint256) {
        if (
            _params.marketConfig.supplyEmissionsPerSec == 0 &&
            _params.marketConfig.borrowEmissionsPerSec == 0
        ) return 0;

        uint256 _rewardPerSecond = (_params.ourSupply *
            _params.marketConfig.supplyEmissionsPerSec) /
            (_params.cash + _params.totalBorrows - _params.totalReserves);
        _rewardPerSecond +=
            (_params.ourBorrows * _params.marketConfig.borrowEmissionsPerSec) /
            _params.totalBorrows;

        uint256 _rewardInAssetPerYear;

        if (_params.asset == _params.rewardToken) {
            _rewardInAssetPerYear = _rewardPerSecond * 365 days;
        } else {
            _rewardInAssetPerYear =
                (estimatedRewardInAsset(
                    _params.rewardToken,
                    _rewardPerSecond * 7 days,
                    _params.asset,
                    _params.rewardSwapTickSpacing
                ) * 365 days) /
                7 days;
        }

        return
            (_rewardInAssetPerYear * 1e18) /
            (_params.ourSupply - _params.ourBorrows);
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

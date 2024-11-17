// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseLevFarmingStrategy, ERC20, LevCompStrategy, SafeERC20} from "./LevCompStrategy.sol";
import {ComptrollerI as MoonwellComptrollerI} from "./interfaces/moonwell/ComptrollerI.sol";
import {IMultiRewardDistributor} from "./interfaces/moonwell/IMultiRewardDistributor.sol";
import {IRouter as IAeroRouter} from "./interfaces/velo/IRouter.sol";
import {CLSwapSimulator, ISwapRouter} from "./libraries/CLSwapSimulator.sol";

/// @title Leveraged Moonwell (Compound V2) Strategy
/// @notice A strategy that uses Moonwell for leveraged lending/borrowing
/// @dev Implements flash loans and leveraged positions using Aave V3 protocol
/// @author Generic Leverage Farming Strategy Team
contract LevMoonwellStrategy is LevCompStrategy {
    using SafeERC20 for ERC20;

    ERC20 public constant WETH =
        ERC20(0x4200000000000000000000000000000000000006);
    ERC20 public constant WELL =
        ERC20(0xA88594D404727625A9437C3f886C7643872296AE);
    IAeroRouter public constant AERODROME_ROUTER =
        IAeroRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);
    ISwapRouter public constant SLIPSTREAM_ROUTER =
        ISwapRouter(0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5);
    address private constant AERODROME_FACTORY =
        0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    int24 public wethToAssetSwapTickSpacing = 1;


    /// @notice Initializes the strategy with required addresses and settings
    /// @param _cToken The ctoken to use
    /// @param _name The name of the strategy
    constructor(
        address _cToken,
        string memory _name
    ) LevCompStrategy(_cToken, _name) {
        maxIterations = 30;

        WELL.safeApprove(address(AERODROME_ROUTER), type(uint256).max);
        WETH.safeApprove(address(SLIPSTREAM_ROUTER), type(uint256).max);
    }

    /// @notice Sets tick spacing for WETH -> Asset swap 
    /// @param _wethToAssetSwapTickSpacing Tick spacing
    /// @dev Only callable by management
    function setWethToAssetSwapTickSpacing(
        int24 _wethToAssetSwapTickSpacing
    ) external onlyManagement {
        wethToAssetSwapTickSpacing = _wethToAssetSwapTickSpacing;
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _claimRewards() internal override {
        if (dontClaimComp) {
            return;
        }
        address[] memory tokens = new address[](1);
        tokens[0] = address(C_TOKEN);

        MoonwellComptrollerI(address(COMPTROLLER)).claimReward(
            address(this),
            tokens
        );
    }

    // /// @inheritdoc BaseLevFarmingStrategy
    function _sellRewards() internal override {
        uint256 _rewardsBalance = WELL.balanceOf(address(this));

        if (_rewardsBalance < minRewardSell) return;

        IAeroRouter.Route[] memory routes = new IAeroRouter.Route[](1);
        routes[0].from = address(WELL);
        routes[0].to = address(WETH);
        routes[0].factory = AERODROME_FACTORY;

        AERODROME_ROUTER.swapExactTokensForTokens(
            _rewardsBalance,
            0, // amountOutMin,
            routes,
            address(this),
            block.timestamp
        );

        if (address(asset) == address(WETH)) return;

        ISwapRouter(SLIPSTREAM_ROUTER).exactInputSingle(
            getSwapRouterInput(WETH.balanceOf(address(this)))
        );
    }

    function _maxBorrow() internal view override returns (uint256) {
        uint256 _borrowCap = MoonwellComptrollerI(address(COMPTROLLER))
            .borrowCaps(address(C_TOKEN));
        uint256 _totalBorrows = C_TOKEN.totalBorrows();
        if (_totalBorrows >= _borrowCap) return 0;
        return _borrowCap - _totalBorrows;
    }

    function _maxSupply() internal view override returns (uint256) {
        uint256 _supplyCap = MoonwellComptrollerI(address(COMPTROLLER))
            .supplyCaps(address(C_TOKEN));
        uint256 _totalSupplied = C_TOKEN.getCash() +
            C_TOKEN.totalBorrows() -
            C_TOKEN.totalReserves();
        if (_totalSupplied >= _supplyCap) return 0;
        return _supplyCap - _totalSupplied;
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function estimatedRewardsInAsset() public view override returns (uint256) {
        uint256 _rewardBalance = WELL.balanceOf(address(this)) +
            getOutstandingRewards();
        if (_rewardBalance == 0) {
            return 0;
        }

        IAeroRouter.Route[] memory routes = new IAeroRouter.Route[](1);
        routes[0].from = address(WELL);
        routes[0].to = address(WETH);
        routes[0].factory = AERODROME_FACTORY;

        uint256[] memory outs = AERODROME_ROUTER.getAmountsOut(
            _rewardBalance,
            routes
        );

        if (address(asset) == address(WETH)) return outs[outs.length - 1];
        if (outs[outs.length - 1] == 0) return 0;

        return
            CLSwapSimulator.simulateExactInputSingle(
                ISwapRouter(SLIPSTREAM_ROUTER),
                getSwapRouterInput(outs[outs.length - 1])
            );
    }

    function getOutstandingRewards()
        internal
        view
        returns (uint256 _outstandingRewards)
    {
        IMultiRewardDistributor _rewardDistributor = MoonwellComptrollerI(
            address(COMPTROLLER)
        ).rewardDistributor();
        IMultiRewardDistributor.RewardInfo[]
            memory rewardInfo = _rewardDistributor.getOutstandingRewardsForUser(
                C_TOKEN,
                address(this)
            );

        for (uint8 i; i < rewardInfo.length; ++i) {
            if (rewardInfo[i].emissionToken != address(WELL)) continue;
            _outstandingRewards += rewardInfo[i].totalAmount;
        }
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function getProtocolLTVs()
        internal
        view
        virtual
        override
        returns (uint256 ltv, uint256 liquidationThreshold)
    {
        (, ltv) = MoonwellComptrollerI(address(COMPTROLLER)).markets(
            address(C_TOKEN)
        );
        liquidationThreshold = ltv;
    }

    function getSwapRouterInput(
        uint256 _amountIn
    ) private view returns (ISwapRouter.ExactInputSingleParams memory) {
        return
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(WETH),
                tokenOut: address(asset),
                tickSpacing: wethToAssetSwapTickSpacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
    }
}

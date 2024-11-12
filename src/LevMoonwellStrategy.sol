// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseLevFarmingStrategy, ERC20, LevCompStrategy} from "./LevCompStrategy.sol";
import {ComptrollerI} from "./interfaces/compound/ComptrollerI.sol";
import {CTokenI} from "./interfaces/compound/CTokenI.sol";
import {IRouter as IAeroRouter} from "./interfaces/velo/IRouter.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";

interface MoonwellComptrollerI is ComptrollerI {
    function claimReward(address holder, CTokenI[] memory mTokens) external;
}

/// @title Leveraged Moonwell (Compound V2) Strategy
/// @notice A strategy that uses Moonwell for leveraged lending/borrowing
/// @dev Implements flash loans and leveraged positions using Aave V3 protocol
/// @author Generic Leverage Farming Strategy Team
contract LevMoonwellStrategy is LevCompStrategy, UniswapV3Swapper {
    ERC20 public constant WETH =
        ERC20(0x4200000000000000000000000000000000000006);
    ERC20 public constant WELL =
        ERC20(0xA88594D404727625A9437C3f886C7643872296AE);
    IAeroRouter public constant AERODROME_ROUTER =
        IAeroRouter(0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5);
    address private constant AERODROME_FACTORY =
        0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    /// @notice Initializes the strategy with required addresses and settings
    /// @param _asset The underlying asset token address
    /// @param _name The name of the strategy
    /// @param _cToken The ctoken to use
    constructor(
        address _asset,
        string memory _name,
        address _cToken
    ) LevCompStrategy(_asset, _name, _cToken) {
        router = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5; // aerodrome slipstream router
        base = address(WETH);
    }

    // /// @inheritdoc BaseLevFarmingStrategy
    // function _leverUpTo(
    //     uint256 totalAmountToBorrow,
    //     uint256 assetBalance,
    //     uint256 deposits,
    //     uint256 borrows
    // ) internal override {
    //     if (!flashloanEnabled)
    //         return
    //             super._leverUpTo(
    //                 totalAmountToBorrow,
    //                 assetBalance,
    //                 deposits,
    //                 borrows
    //             );
    //     _flashloan(totalAmountToBorrow);
    // }

    // /// @inheritdoc BaseLevFarmingStrategy
    // function _leverDownTo(
    //     uint256 _targetAmountBorrowed,
    //     uint256 /*_deposits*/,
    //     uint256 _borrows
    // ) internal override {
    // }

    /// @inheritdoc BaseLevFarmingStrategy
    function _claimRewards() internal override {
        if (dontClaimComp) {
            return;
        }
        CTokenI[] memory tokens = new CTokenI[](1);
        tokens[0] = C_TOKEN;

        MoonwellComptrollerI(address(COMPTOLLER)).claimReward(
            address(this),
            tokens
        );
    }

    // /// @inheritdoc BaseLevFarmingStrategy
    function _sellRewards() internal override {
        IAeroRouter.Route[] memory routes = new IAeroRouter.Route[](1);
        routes[0].from = address(WELL);
        routes[0].to = address(WETH);
        routes[0].factory = AERODROME_FACTORY;

        AERODROME_ROUTER.swapExactTokensForTokens(
            WELL.balanceOf(address(this)), // amountIn
            0, // amountOutMin,
            routes,
            address(this),
            type(uint256).max
        );

        if (address(asset) == address(WETH)) return;

        _swapFrom(
            address(WETH),
            address(asset),
            WETH.balanceOf(address(this)),
            0
        );
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function estimatedRewardsInAsset()
        public
        view
        override
        returns (uint256 _rewardsInAsset)
    {
        IAeroRouter.Route[] memory routes = new IAeroRouter.Route[](1);
        routes[0].from = address(WELL);
        routes[0].to = address(WETH);
        routes[0].factory = AERODROME_FACTORY;

        uint256[] memory outs = AERODROME_ROUTER.getAmountsOut(
            WELL.balanceOf(address(this)), // amountIn
            routes
        );


    }
}

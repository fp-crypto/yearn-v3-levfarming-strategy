// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseLevFarmingStrategy, ERC20, LevCompStrategy, SafeERC20} from "./LevCompStrategy.sol";
import {ComptrollerI as MoonwellComptrollerI} from "./interfaces/moonwell/ComptrollerI.sol";
import {IWETH} from "./interfaces/IWETH.sol";
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
    ERC20 public constant USDC =
        ERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IAeroRouter public constant AERODROME_ROUTER =
        IAeroRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);
    ISwapRouter public constant SLIPSTREAM_ROUTER =
        ISwapRouter(0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5);
    address private constant AERODROME_FACTORY =
        0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    int24 public wethToAssetSwapTickSpacing;
    int24 public usdcToAssetSwapTickSpacing;

    /// @notice Initializes the strategy with required addresses and settings
    /// @param _cToken The ctoken to use
    /// @param _name The name of the strategy
    constructor(
        address _cToken,
        string memory _name,
        int24 _wethToAssetSwapTickSpacing,
        int24 _usdcToAssetSwapTickSpacing
    ) LevCompStrategy(_cToken, _name) {
        maxIterations = 30;

        wethToAssetSwapTickSpacing = _wethToAssetSwapTickSpacing;
        usdcToAssetSwapTickSpacing = _usdcToAssetSwapTickSpacing;

        WELL.safeApprove(address(AERODROME_ROUTER), type(uint256).max);
        if (address(asset) != address(WETH))
            WETH.safeApprove(address(SLIPSTREAM_ROUTER), type(uint256).max);
        if (address(asset) != address(USDC))
            USDC.safeApprove(address(SLIPSTREAM_ROUTER), type(uint256).max);
    }

    /// @notice Sets tick spacing for WETH -> Asset swap
    /// @param _wethToAssetSwapTickSpacing Tick spacing
    /// @dev Only callable by management
    function setWethToAssetSwapTickSpacing(
        int24 _wethToAssetSwapTickSpacing
    ) external onlyManagement {
        wethToAssetSwapTickSpacing = _wethToAssetSwapTickSpacing;
    }

    /// @notice Sets tick spacing for USDC -> Asset swap
    /// @param _usdcToAssetSwapTickSpacing Tick spacing
    /// @dev Only callable by management
    function setUsdcToAssetSwapTickSpacing(
        int24 _usdcToAssetSwapTickSpacing
    ) external onlyManagement {
        usdcToAssetSwapTickSpacing = _usdcToAssetSwapTickSpacing;
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

        if (_rewardsBalance >= minRewardSell) {
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

            if (address(asset) != address(WETH)) {
                ISwapRouter(SLIPSTREAM_ROUTER).exactInputSingle(
                    getSwapRouterInput(
                        address(WETH),
                        WETH.balanceOf(address(this))
                    )
                );
            }
        }

        if (address(asset) == address(USDC) || usdcToAssetSwapTickSpacing == 0)
            return;

        uint256 _usdcBalance = USDC.balanceOf(address(this));

        if (_usdcBalance >= 1e6) {
            ISwapRouter(SLIPSTREAM_ROUTER).exactInputSingle(
                getSwapRouterInput(address(USDC), _usdcBalance)
            );
        }
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _maxBorrow() internal view override returns (uint256) {
        uint256 _borrowCap = MoonwellComptrollerI(address(COMPTROLLER))
            .borrowCaps(address(C_TOKEN));
        uint256 _totalBorrows = C_TOKEN.totalBorrows();
        if (_totalBorrows >= _borrowCap) return 0;
        return _borrowCap - _totalBorrows;
    }

    /// @inheritdoc BaseLevFarmingStrategy
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
    function estimatedRewardsInAsset()
        public
        view
        override
        returns (uint256 _rewardsInAsset)
    {
        (uint256 _wellPending, uint256 _usdcPending) = getOutstandingRewards();

        uint256 _wellBalance = WELL.balanceOf(address(this)) + _wellPending;

        if (_wellBalance != 0) {
            IAeroRouter.Route[] memory routes = new IAeroRouter.Route[](1);
            routes[0].from = address(WELL);
            routes[0].to = address(WETH);
            routes[0].factory = AERODROME_FACTORY;

            uint256[] memory outs = AERODROME_ROUTER.getAmountsOut(
                _wellBalance,
                routes
            );

            if (address(asset) == address(WETH)) {
                _rewardsInAsset += outs[outs.length - 1];
            } else {
                uint256 _wethBalance = WETH.balanceOf(address(this));
                if (_wethBalance != 0) {
                    _rewardsInAsset += CLSwapSimulator.simulateExactInputSingle(
                        ISwapRouter(SLIPSTREAM_ROUTER),
                        getSwapRouterInput(address(WETH), _wethBalance)
                    );
                }
            }
        }

        if (address(asset) == address(USDC)) {
            _rewardsInAsset += _usdcPending;
        } else if (usdcToAssetSwapTickSpacing != 0) {
            uint256 _usdcBalance = USDC.balanceOf(address(this));
            if (_usdcBalance >= 1e6) {
                _rewardsInAsset += CLSwapSimulator.simulateExactInputSingle(
                    ISwapRouter(SLIPSTREAM_ROUTER),
                    getSwapRouterInput(address(USDC), _usdcBalance)
                );
            }
        }
    }

    /// @notice Gets the outstanding rewards for WELL and USDC tokens
    /// @return _outstandingRewardsWeth Amount of outstanding WELL rewards
    /// @return _outstandingRewardsUsdc Amount of outstanding USDC rewards
    function getOutstandingRewards()
        internal
        view
        returns (
            uint256 _outstandingRewardsWeth,
            uint256 _outstandingRewardsUsdc
        )
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
            if (rewardInfo[i].emissionToken == address(WELL))
                _outstandingRewardsWeth += rewardInfo[i].totalAmount;
            if (rewardInfo[i].emissionToken == address(USDC))
                _outstandingRewardsUsdc += rewardInfo[i].totalAmount;
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

    /// @notice Creates swap parameters for Slipstream router
    /// @param _tokenIn Address of input token (WETH or USDC)
    /// @param _amountIn Amount of input tokens to swap
    /// @return Swap parameters struct for Slipstream router
    function getSwapRouterInput(
        address _tokenIn,
        uint256 _amountIn
    ) private view returns (ISwapRouter.ExactInputSingleParams memory) {
        return
            ISwapRouter.ExactInputSingleParams({
                tokenIn: _tokenIn,
                tokenOut: address(asset),
                tickSpacing: _tokenIn == address(WETH)
                    ? wethToAssetSwapTickSpacing
                    : usdcToAssetSwapTickSpacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
    }

    /// @notice Allows management to sweep stuck tokens
    /// @param _token Address of token to sweep
    /// @param _amount Amount of tokens to sweep
    /// @dev Cannot sweep strategy asset, cToken, or WELL token
    function sweep(address _token, uint256 _amount) external onlyManagement {
        require(address(asset) != _token, "!asset");
        require(address(C_TOKEN) != _token, "!ctoken");
        require(address(WELL) != _token, "!well");
        ERC20(_token).safeTransfer(TokenizedStrategy.management(), _amount);
    }

    /// @notice Handles native ETH received by the contract
    /// @dev Automatically wraps any received ETH to WETH
    receive() external payable {
        if (address(this).balance != 0) {
            IWETH(address(WETH)).deposit{value: address(this).balance}();
        }
    }
}

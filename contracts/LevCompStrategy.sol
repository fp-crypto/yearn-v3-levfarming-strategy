// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import "./BaseLevFarmingStrategy.sol";
import "./interfaces/compound/CErc20I.sol";
import "./interfaces/compound/ComptrollerI.sol";
import "./interfaces/uniswap/IUniswapV2Router02.sol";

contract LevCompStrategy is BaseLevFarmingStrategy {
    address public constant comp = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    address public constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    ComptrollerI public constant compound =
        ComptrollerI(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);
    CErc20I public cToken;

    bool public dontClaimComp;

    IUniswapV2Router02 public currentRouter =
        IUniswapV2Router02(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F); //uni v2 forks only

    constructor(
        address _asset,
        string memory _name,
        address _cToken
    ) BaseLevFarmingStrategy(_asset, _name) {
        _initStrategy(_asset, _cToken);
    }

    function _initStrategy(address _asset, address _cToken) internal {
        super._initStrategy(_asset);
        require(address(cToken) == address(0), "!already initialized");
        cToken = CErc20I(_cToken);
        require(cToken.underlying() == asset);

        (, uint256 collateralFactorMantissa, ) = compound.markets(
            address(cToken)
        );
        targetCollatRatio =
            collateralFactorMantissa -
            DEFAULT_COLLAT_TARGET_MARGIN;
        maxBorrowCollatRatio =
            collateralFactorMantissa -
            DEFAULT_COLLAT_MAX_MARGIN;
        maxCollatRatio = maxBorrowCollatRatio;

        ERC20(asset).approve(address(cToken), type(uint256).max);
        ERC20(comp).approve(address(currentRouter), type(uint256).max);
    }

    function _deposit(uint256 _amount) internal override {
        require(cToken.mint(_amount) == 0);
    }

    function _withdraw(uint256 _amount) internal override returns (uint256) {
        require(cToken.redeemUnderlying(_amount) == 0);
        return _amount;
    }

    function _borrow(uint256 _amount) internal override {
        require(cToken.borrow(_amount) == 0);
    }

    function _repay(uint256 _amount) internal override returns (uint256) {
        require(cToken.repayBorrow(_amount) == 0);
        return _amount;
    }

    function _claimRewards() internal override {
        if (dontClaimComp) {
            return;
        }
        CTokenI[] memory tokens = new CTokenI[](1);
        tokens[0] = cToken;

        compound.claimComp(address(this), tokens);
    }

    function _sellRewards() internal override {
        uint256 _compAmount = ERC20(comp).balanceOf(address(this));
        if (_compAmount < minRewardSell) {
            return;
        }

        currentRouter.swapExactTokensForTokens(
            _compAmount,
            0,
            getTokenOutPathV2(address(comp), address(asset)),
            address(this),
            block.timestamp
        );
    }

    function estimatedPosition()
        public
        view
        override
        returns (uint256 deposits, uint256 borrows)
    {
        (
            ,
            uint256 cTokenBalance,
            uint256 borrowBalance,
            uint256 exchangeRate
        ) = cToken.getAccountSnapshot(address(this));
        borrows = borrowBalance;
        deposits = (cTokenBalance * exchangeRate) / 1e18;
    }

    function livePosition()
        public
        override
        returns (uint256 deposits, uint256 borrows)
    {
        deposits = cToken.balanceOfUnderlying(address(this));
        //we can use non state changing now because we updated state with balanceOfUnderlying call
        borrows = cToken.borrowBalanceStored(address(this));
    }

    function getTokenOutPathV2(
        address _tokenIn,
        address _tokenOut
    ) internal view returns (address[] memory _path) {
        bool isWeth = _tokenIn == address(weth) || _tokenOut == address(weth);
        _path = new address[](isWeth ? 2 : 3);
        _path[0] = _tokenIn;

        if (isWeth) {
            _path[1] = _tokenOut;
        } else {
            _path[1] = address(weth);
            _path[2] = _tokenOut;
        }
    }

    function _estimateTokenToAsset(
        address _from,
        uint256 _amount
    ) internal view override returns (uint256) {
        if (_amount == 0) {
            return 0;
        }
        address[] memory path = getTokenOutPathV2(_from, asset);
        uint256[] memory amounts = IUniswapV2Router02(currentRouter)
            .getAmountsOut(_amount, path);
        return amounts[amounts.length - 1];
    }

    function estimatedRewardsInAsset()
        public
        view
        override
        returns (uint256 _rewardsInAsset)
    {
        uint256 _claimableComp = predictCompAccrued();
        uint256 currentComp = ERC20(comp).balanceOf(address(this));

        _rewardsInAsset= _estimateTokenToAsset(
            asset,
            _claimableComp + currentComp
        );
    }

    function predictCompAccrued() public view returns (uint256) {
        (uint256 deposits, uint256 borrows) = estimatedPosition();
        if (deposits == 0) {
            return 0; // should be impossible to have 0 balance and positive comp accrued
        }
        uint256 secondsPerBlock = 12;

        uint256 distributionPerBlockSupply = compound.compSupplySpeeds(address(cToken));
        uint256 distributionPerBlockBorrow = compound.compBorrowSpeeds(address(cToken));

        uint256 totalBorrow = cToken.totalBorrows();

        //total supply needs to be echanged to underlying using exchange rate
        uint256 totalSupplyCtoken = cToken.totalSupply();
        uint256 totalSupply = totalSupplyCtoken * cToken.exchangeRateStored() / 1e18;

        uint256 blockShareSupply = 0;
        if (totalSupply > 0) {
            blockShareSupply = deposits* distributionPerBlockSupply / totalSupply;
        }

        uint256 blockShareBorrow = 0;
        if (totalBorrow > 0) {
            blockShareBorrow = borrows * distributionPerBlockBorrow / totalBorrow;
        }

        //how much we expect to earn per block
        uint256 blockShare = blockShareSupply + blockShareBorrow;

        //last time we ran harvest
        uint256 lastReport = TokenizedStrategy.lastReport();
        uint256 blocksSinceLast = (block.timestamp - lastReport) / secondsPerBlock; 

        return blocksSinceLast * blockShare;
    }
}

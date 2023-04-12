// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import "./BaseLevFarmingStrategy.sol";
import "./interfaces/compound/CErc20I.sol";
import "./interfaces/compound/ComptrollerI.sol";
import "./interfaces/uniswap/IUniswapV2Router02.sol";

contract LevCompStrategy is BaseLevFarmingStrategy {
    address public comp;
    address public weth;
    CErc20I public cToken;
    ComptrollerI public compound;

    bool public dontClaimComp;
    uint256 public minCompToSell;

    IUniswapV2Router02 public currentRouter; //uni v2 forks only

    constructor(
        address _asset,
        string memory _name
    ) BaseLevFarmingStrategy(_asset, _name) {}

    function _deposit(uint256 _amount) internal override {
        require(cToken.mint(_amount) == 0);
    }

    function _withdraw(uint256 _amount) internal override returns (uint256) {
        require(cToken.redeemUnderlying(_amount) == 0);
    }

    function _borrow(uint256 _amount) internal override {
        require(cToken.borrow(_amount) == 0);
    }

    function _repay(uint256 _amount) internal override returns (uint256) {
        require(cToken.repayBorrow(_amount) == 0);
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
        if (_compAmount < minCompToSell) {
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

    function currentPosition()
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
}

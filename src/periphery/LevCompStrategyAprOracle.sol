// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {InterestRateModel} from "../interfaces/compound/InterestRateModel.sol";
import {CTokenI} from "../interfaces/compound/CTokenI.sol";
import {ILevCompStrategyInterface} from "../interfaces/ILevCompStrategyInterface.sol";

contract LevCompStrategyAprOracle is AprOracleBase {
    constructor() AprOracleBase("LevComp Strategy Apr Oracle", msg.sender) {}

    /**
     * @notice Will return the expected Apr of a strategy post a debt change.
     * @param _strategy The token to get the apr for.
     * @param _delta The difference in debt.
     * @return _apr The expected apr for the strategy represented as 1e18.
     */
    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view override returns (uint256) {
        return
            aprAfterDebtChange(
                _strategy,
                _delta,
                uint256(ILevCompStrategyInterface(_strategy).targetLTV())
            );
    }

    /**
     * @notice Will return the expected Apr of a strategy post a debt change.
     * @param _strategy The token to get the apr for.
     * @param _delta The difference in debt.
     * @param _ltv The target loan-to-value in WAD.
     * @return _apr The expected apr for the strategy represented as 1e18.
     */
    function aprAfterDebtChange(
        address _strategy,
        int256 _delta,
        uint256 _ltv
    ) public view returns (uint256) {
        (
            uint256 currentSupply,
            uint256 currentBorrow
        ) = ILevCompStrategyInterface(_strategy).estimatedPosition();

        int256 netAssets = int256(currentSupply - currentBorrow) + _delta;

        if (netAssets <= 0) return 0;
        
        CTokenI cToken = CTokenI(
            ILevCompStrategyInterface(_strategy).C_TOKEN()
        );

        AprFromRewardsParams memory _aprFromRewardsParams;
        _aprFromRewardsParams.cToken = address(cToken);

        (
            _aprFromRewardsParams.ourSupply,
            _aprFromRewardsParams.ourBorrows
        ) = _getSupplyBorrowFromLTV(uint256(netAssets), _ltv);



        _aprFromRewardsParams.cash = uint256(int256(cToken.getCash()) + _delta);
        _aprFromRewardsParams.totalBorrows = uint256(
            int256(cToken.totalBorrows()) +
                int256(_aprFromRewardsParams.ourBorrows) -
                int256(currentBorrow)
        );

        return _cTokenAprWithRewards(_aprFromRewardsParams);
    }

    function cTokenAprWithRewards(
        address _cToken,
        uint256 _assetAmount,
        uint256 _ltv
    ) internal view returns (uint256) {
        if (_assetAmount == 0) return 0;

        AprFromRewardsParams memory _aprFromRewardsParams;
        _aprFromRewardsParams.cToken = _cToken;

        (
            _aprFromRewardsParams.ourSupply,
            _aprFromRewardsParams.ourBorrows
        ) = _getSupplyBorrowFromLTV(uint256(_assetAmount), _ltv);

        CTokenI cToken = CTokenI(ILevCompStrategyInterface(_cToken).C_TOKEN());

        _aprFromRewardsParams.cash = cToken.getCash() + _assetAmount;
        _aprFromRewardsParams.totalBorrows = uint256(
            int256(cToken.totalBorrows()) +
                int256(_aprFromRewardsParams.ourBorrows)
        );

        return _cTokenAprWithRewards(_aprFromRewardsParams);
    }

    function _cTokenAprWithRewards(
        AprFromRewardsParams memory _aprFromRewardsParams
    ) internal view returns (uint256) {
        CTokenI cToken = CTokenI(ILevCompStrategyInterface(_aprFromRewardsParams.cToken).C_TOKEN());

        (
            uint256 supplyRatePerSec,
            uint256 borrowRatePerSec
        ) = _getSupplyBorrowRatePerSec(
                cToken,
                _aprFromRewardsParams.cash,
                _aprFromRewardsParams.totalBorrows
            );

        int256 _netApr = ((int256(
            supplyRatePerSec * _aprFromRewardsParams.ourSupply
        ) - int256(borrowRatePerSec * _aprFromRewardsParams.ourBorrows)) *
            365 days) /
            int256(_aprFromRewardsParams.ourSupply -
                _aprFromRewardsParams.ourBorrows);

        uint256 _rewardsApr = getAprFromRewards(_aprFromRewardsParams);

        _netApr += int256(_rewardsApr);

        return _netApr > 0 ? uint256(_netApr) : 0;
    }

    function _getSupplyBorrowRatePerSec(
        CTokenI _cToken,
        uint256 _cash,
        uint256 _totalBorrows
    )
        internal
        view
        returns (uint256 _supplyRatePerSec, uint256 _borrowRatePerSec)
    {
        InterestRateModel irm = InterestRateModel(_cToken.interestRateModel());
        uint256 reserves = _cToken.totalReserves();
        uint256 reserveFactorMantissa = _cToken.reserveFactorMantissa();

        _supplyRatePerSec = irm.getSupplyRate(
            _cash,
            _totalBorrows,
            reserves,
            reserveFactorMantissa
        );
        _borrowRatePerSec = irm.getBorrowRate(_cash, _totalBorrows, reserves);
    }

    function _getSupplyBorrowFromLTV(
        uint256 _netSupply,
        uint256 _ltv
    ) internal pure returns (uint256 _supply, uint256 _borrow) {
        uint256 leverage = 1e36 / (1e18 - _ltv);
        _supply = (_netSupply * leverage) / 1e18;
        _borrow = (_netSupply * (leverage - 1e18)) / 1e18;
    }

    struct AprFromRewardsParams {
        address cToken;
        uint256 ourSupply;
        uint256 ourBorrows;
        uint256 cash;
        uint256 totalBorrows;
    }

    function getAprFromRewards(
        AprFromRewardsParams memory /*_params*/
    ) internal view virtual returns (uint256) {
        return 0;
    }
}

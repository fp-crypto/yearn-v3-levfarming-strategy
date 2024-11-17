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
    ) external view override returns (uint256 _apr) {
        (
            uint256 currentSupply,
            uint256 currentBorrow
        ) = ILevCompStrategyInterface(_strategy).estimatedPosition();
        uint256 netAssets = uint256(
            int256(currentSupply - currentBorrow) + _delta
        );
        if (int256(netAssets) <= -_delta) return 0;

        (uint256 futureSupply, uint256 futureBorrow) = getSupplyBorrowFromLTV(
            netAssets,
            uint256(ILevCompStrategyInterface(_strategy).targetLTV())
        );

        CTokenI cToken = CTokenI(
            ILevCompStrategyInterface(_strategy).C_TOKEN()
        );

        uint256 cash = uint256(int256(cToken.getCash()) + _delta);
        uint256 borrows = uint256(
            int256(cToken.totalBorrows()) +
                int256(futureBorrow) -
                int256(currentBorrow)
        );

        (
            uint256 supplyRatePerSec,
            uint256 borrowRatePerSec
        ) = getSupplyBorrowRatePerSec(
                cToken,
                cash,
                borrows
            );

        _apr =
            uint256(
                (int256(supplyRatePerSec * futureSupply) -
                    int256(borrowRatePerSec * futureBorrow)) * 365 days
            ) /
            netAssets;

        _apr += getAprFromRewards(
            _strategy,
            futureSupply,
            futureBorrow,
            cash,
            borrows
        );
    }

    function getSupplyBorrowRatePerSec(
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

    function getSupplyBorrowFromLTV(
        uint256 cash,
        uint256 ltv
    ) internal view returns (uint256 supply, uint256 borrow) {
        uint256 leverage = 1e36 / (1e18 - ltv);
        supply = (cash * leverage) / 1e18;
        borrow = (cash * (leverage - 1e18)) / 1e18;
    }

    function getAprFromRewards(
        address _strategy,
        uint256 _ourSupply,
        uint256 _ourBorrows,
        uint256 _cash,
        uint256 _totalBorrows
    ) internal view virtual returns (uint256 _apr) {}
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {BaseTokenizedStrategy} from "@tokenized-strategy/BaseTokenizedStrategy.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

/**
 * The `TokenizedStrategy` variable can be used to retrieve the strategies
 * specifc storage data your contract.
 *
 *       i.e. uint256 totalAssets = TokenizedStrategy.totalAssets()
 *
 * This can not be used for write functions. Any TokenizedStrategy
 * variables that need to be udpated post deployement will need to
 * come from an external call from the strategies specific `management`.
 */

// NOTE: To implement permissioned functions you can use the onlyManagement and onlyKeepers modifiers

abstract contract BaseLevFarmingStrategy is BaseTokenizedStrategy {
    using SafeERC20 for ERC20;

    // Basic constants
    uint256 internal constant MAX_BPS = 1e4;
    uint256 internal constant WAD_BPS_RATIO = 1e14;
    uint256 internal constant COLLATERAL_RATIO_PRECISION = 1 ether;
    uint256 internal constant PESSIMISM_FACTOR = 1000;

    // OPS State Variables
    uint256 private constant DEFAULT_COLLAT_TARGET_MARGIN = 0.02 ether;
    uint256 private constant DEFAULT_COLLAT_MAX_MARGIN = 0.005 ether;
    uint256 private constant LIQUIDATION_WARNING_THRESHOLD = 0.01 ether;

    uint256 public maxBorrowCollatRatio; // The maximum the protocol will let us borrow
    uint256 public targetCollatRatio; // The LTV we are levering up to
    uint256 public maxCollatRatio; // Closest to liquidation we'll risk

    uint256 public minWant;
    uint256 public minRatio;
    uint256 public minRewardToSell;

    uint8 public maxIterations;

    constructor(
        address _asset,
        string memory _name
    ) BaseTokenizedStrategy(_asset, _name) {}

    /**
     * @dev Should invest up to '_amount' of 'asset'.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permsionless and thus can be sandwhiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy should attempt
     * to deposit in the yield source.
     */
    function _invest(uint256 _amount) internal override {
        uint256 wantBalance = balanceOfWant();
        // deposit available want as collateral
        if (wantBalance > minWant) {
            _deposit(wantBalance);
        }

        // check current LTV
        uint256 _currentCollatRatio = currentCollatRatio();

        // we should lever up
        if (
            targetCollatRatio > _currentCollatRatio &&
            targetCollatRatio - _currentCollatRatio > minRatio
        ) {
            _leverMax();
        }
    }

    /**
     * @dev Will attempt to free the '_amount' of 'asset'.
     *
     * The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permsionless and thus can be sandwhiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting puroposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) return;

        (uint256 deposits, uint256 borrows) = currentPosition();

        if (borrows == 0) {
            _withdraw(Math.min(_amount, deposits));
            return;
        }

        uint256 realAssets = deposits - borrows;
        uint256 amountRequired = Math.min(_amount, realAssets);
        uint256 newSupply = realAssets - amountRequired;
        uint256 newBorrow = getBorrowFromSupply(newSupply, targetCollatRatio);

        // repay required amount
        _leverDownTo(newBorrow, borrows);
    }

    /**
     * @dev Internal non-view function to harvest all rewards, reinvest
     * and return the accurate amount of funds currently held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * reinvesting etc. to get the most accurate view of current assets.
     *
     * All applicable assets including loose assets should be accounted
     * for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be reinvested
     * or simply realize any profits/losses.
     *
     * @return _invested A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds.
     */
    function _totalInvested() internal override returns (uint256 _invested) {
        _claimRewards();
        _sellRewards();

        _invested = ERC20(asset).balanceOf(address(this));
        (uint256 deposits, uint256 borrows) = currentPosition();
        _invested += deposits - borrows;
    }

    function _deposit(uint256 _amount) internal virtual {}

    function _withdraw(uint256 _amount) internal virtual returns (uint256) {}

    function _borrow(uint256 _mount) internal virtual {}

    function _repay(uint256 _amount) internal virtual returns (uint256) {}

    function _claimRewards() internal virtual {}

    function _sellRewards() internal virtual {}

    function _leverMax() internal {
        (uint256 deposits, uint256 borrows) = currentPosition();
        uint256 wantBalance = balanceOfWant();

        uint256 realSupply = deposits - borrows + wantBalance;
        uint256 newBorrow = getBorrowFromSupply(realSupply, targetCollatRatio);
        uint256 totalAmountToBorrow = newBorrow - borrows;

        uint8 _maxIterations = maxIterations;
        uint256 _minWant = minWant;

        for (
            uint8 i = 0;
            i < _maxIterations && totalAmountToBorrow > _minWant;
            i++
        ) {
            uint256 amount = totalAmountToBorrow;

            // calculate how much borrow to take
            uint256 canBorrow = getBorrowFromDeposit(
                deposits + wantBalance,
                maxBorrowCollatRatio
            );

            if (canBorrow <= borrows) {
                break;
            }
            canBorrow = canBorrow - borrows;

            if (canBorrow < amount) {
                amount = canBorrow;
            }

            // deposit available want as collateral
            _deposit(wantBalance);

            // borrow available amount
            _borrow(amount);

            (deposits, borrows) = currentPosition();
            wantBalance = balanceOfWant();

            totalAmountToBorrow = totalAmountToBorrow - amount;
        }

        if (wantBalance >= minWant) {
            _deposit(wantBalance);
        }
    }

    function _leverDownTo(
        uint256 newAmountBorrowed,
        uint256 currentBorrowed
    ) internal {
        (uint256 deposits, uint256 borrows) = currentPosition();

        if (currentBorrowed > newAmountBorrowed) {
            uint256 wantBalance = balanceOfWant();
            uint256 totalRepayAmount = currentBorrowed - newAmountBorrowed;

            uint256 _maxCollatRatio = maxCollatRatio;

            for (
                uint8 i = 0;
                i < maxIterations && totalRepayAmount > minWant;
                i++
            ) {
                uint256 withdrawn = _withdrawExcessCollateral(
                    _maxCollatRatio,
                    deposits,
                    borrows
                );
                wantBalance = wantBalance + withdrawn; // track ourselves to save gas
                uint256 toRepay = totalRepayAmount;
                if (toRepay > wantBalance) {
                    toRepay = wantBalance;
                }
                uint256 repaid = _repay(toRepay);

                // track ourselves to save gas
                deposits = deposits - withdrawn;
                wantBalance = wantBalance - repaid;
                borrows = borrows - repaid;

                totalRepayAmount = totalRepayAmount - repaid;
            }
        }

        (deposits, borrows) = currentPosition();
        // deposit back to get targetCollatRatio (we always need to leave this in this ratio)
        uint256 _targetCollatRatio = targetCollatRatio;
        uint256 targetDeposit = getDepositFromBorrow(
            borrows,
            _targetCollatRatio
        );
        if (targetDeposit > deposits) {
            uint256 toDeposit = targetDeposit - deposits;
            if (toDeposit > minWant) {
                _deposit(Math.min(toDeposit, balanceOfWant()));
            }
        } else {
            _withdrawExcessCollateral(_targetCollatRatio, deposits, borrows);
        }
    }

    function _withdrawExcessCollateral(
        uint256 collatRatio,
        uint256 deposits,
        uint256 borrows
    ) internal returns (uint256 amount) {
        uint256 theoDeposits = getDepositFromBorrow(borrows, collatRatio);
        if (deposits > theoDeposits) {
            uint256 toWithdraw = deposits - theoDeposits;
            return _withdraw(toWithdraw);
        }
    }

    function balanceOfWant() internal view returns (uint256) {
        return ERC20(asset).balanceOf(address(this));
    }

    function currentPosition()
        public
        view
        virtual
        returns (uint256 deposits, uint256 borrows)
    {}

    function currentCollatRatio()
        public
        view
        returns (uint256 _currentCollatRatio)
    {
        (uint256 deposits, uint256 borrows) = currentPosition();

        if (deposits > 0 && borrows != 0) {
            _currentCollatRatio =
                (borrows * COLLATERAL_RATIO_PRECISION) /
                deposits;
        }
    }

    // Section: LTV Math

    function getBorrowFromDeposit(
        uint256 deposit,
        uint256 collatRatio
    ) internal pure returns (uint256) {
        if (collatRatio == 0) return 0;
        return (deposit * collatRatio) / COLLATERAL_RATIO_PRECISION;
    }

    function getDepositFromBorrow(
        uint256 borrow,
        uint256 collatRatio
    ) internal pure returns (uint256) {
        if (collatRatio == 0) return type(uint256).max;
        return (borrow * COLLATERAL_RATIO_PRECISION) / collatRatio;
    }

    function getBorrowFromSupply(
        uint256 supply,
        uint256 collatRatio
    ) internal pure returns (uint256) {
        if (collatRatio == 0) return 0;
        return
            (supply * collatRatio) / (COLLATERAL_RATIO_PRECISION - collatRatio);
    }
}

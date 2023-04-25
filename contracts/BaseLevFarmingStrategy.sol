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
    uint256 internal constant DEFAULT_COLLAT_TARGET_MARGIN = 0.02 ether;
    uint256 internal constant DEFAULT_COLLAT_MAX_MARGIN = 0.005 ether;
    uint256 internal constant LIQUIDATION_WARNING_THRESHOLD = 0.01 ether;

    uint256 public maxBorrowCollatRatio; // The maximum the protocol will let us borrow
    uint256 public targetCollatRatio; // The LTV we are levering up to
    uint256 public maxCollatRatio; // Closest to liquidation we'll risk

    uint256 public minAsset;
    uint256 public minRatio;
    uint256 public minRewardSell;
    uint8 public maxIterations;

    bool public initialized;

    constructor(
        address _asset,
        string memory _name
    ) BaseTokenizedStrategy(_asset, _name) {}

    function _initStrategy(address _asset) internal virtual {
        require(!initialized, "already initialized");

        // initialize operational state
        maxIterations = 12;

        // mins
        minAsset = 100;
        minRatio = 0.005 ether;
        minRewardSell = 1e15;

        initialized = true;
    }

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
        uint256 assetBalance = balanceOfAsset();
        // deposit available asset as collateral
        if (assetBalance > minAsset) {
            _deposit(assetBalance);
        }

        // check current LTV
        uint256 _liveCollatRatio = liveCollatRatio();

        // we should lever up
        if (
            targetCollatRatio > _liveCollatRatio &&
            targetCollatRatio - _liveCollatRatio > minRatio
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

        (uint256 deposits, uint256 borrows) = livePosition();

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

        uint256 assetBalance = balanceOfAsset();
        // deposit available asset as collateral
        if (assetBalance > minAsset) {
            _deposit(assetBalance);
        }

        // check current position
        (uint256 deposits, uint256 borrows) = livePosition();
        uint256 _currentCollatRatio = getCollatRatio(deposits, borrows);

        if (_currentCollatRatio < targetCollatRatio) {
            // we should lever up
            if (targetCollatRatio - _currentCollatRatio > minRatio) {
                // we only act on relevant differences
                _leverMax();
            }
        } else if (_currentCollatRatio > targetCollatRatio) {
            if (_currentCollatRatio - targetCollatRatio > minRatio) {
                uint256 newBorrow = getBorrowFromSupply(
                    deposits - borrows,
                    targetCollatRatio
                );
                _leverDownTo(newBorrow, borrows);
            }
        }

        _invested = ERC20(asset).balanceOf(address(this));
        (deposits, borrows) = livePosition();
        _invested += deposits - borrows;
    }

    function _deposit(uint256 _amount) internal virtual {}

    function _withdraw(uint256 _amount) internal virtual returns (uint256) {}

    function _borrow(uint256 _amount) internal virtual {}

    function _repay(uint256 _amount) internal virtual returns (uint256) {}

    function _claimRewards() internal virtual {}

    function _sellRewards() internal virtual {}

    function _estimateTokenToAsset(
        address _token,
        uint256 _amount
    ) internal view virtual returns (uint256) {}

    function _leverMax() internal {
        (uint256 deposits, uint256 borrows) = livePosition();
        uint256 assetBalance = balanceOfAsset();

        uint256 realSupply = deposits - borrows + assetBalance;
        uint256 newBorrow = getBorrowFromSupply(realSupply, targetCollatRatio);
        uint256 totalAmountToBorrow = newBorrow - borrows;

        uint8 _maxIterations = maxIterations;
        uint256 _minAsset = minAsset;

        for (
            uint8 i = 0;
            i < _maxIterations && totalAmountToBorrow > _minAsset;
            i++
        ) {
            uint256 amount = totalAmountToBorrow;

            // calculate how much borrow to take
            uint256 canBorrow = getBorrowFromDeposit(
                deposits + assetBalance,
                maxBorrowCollatRatio
            );

            if (canBorrow <= borrows) {
                break;
            }
            canBorrow = canBorrow - borrows;

            if (canBorrow < amount) {
                amount = canBorrow;
            }

            // deposit available asset as collateral
            _deposit(assetBalance);

            // borrow available amount
            _borrow(amount);

            (deposits, borrows) = livePosition();
            assetBalance = balanceOfAsset();

            totalAmountToBorrow = totalAmountToBorrow - amount;
        }

        if (assetBalance >= minAsset) {
            _deposit(assetBalance);
        }
    }

    function _leverDownTo(
        uint256 newAmountBorrowed,
        uint256 currentBorrowed
    ) internal {
        (uint256 deposits, uint256 borrows) = livePosition();

        if (currentBorrowed > newAmountBorrowed) {
            uint256 assetBalance = balanceOfAsset();
            uint256 remainingRepayAmount = currentBorrowed - newAmountBorrowed;

            uint256 _maxCollatRatio = maxCollatRatio;

            for (
                uint8 i = 0;
                i < maxIterations && remainingRepayAmount > minAsset;
                i++
            ) {
                uint256 withdrawn = _withdrawExcessCollateral(
                    _maxCollatRatio,
                    deposits,
                    borrows
                );
                assetBalance = assetBalance + withdrawn; // track ourselves to save gas
                uint256 toRepay = remainingRepayAmount;
                if (toRepay > assetBalance) {
                    toRepay = assetBalance;
                }
                uint256 repaid = _repay(toRepay);

                // track ourselves to save gas
                deposits = deposits - withdrawn;
                assetBalance = assetBalance - repaid;
                borrows = borrows - repaid;

                remainingRepayAmount = remainingRepayAmount - repaid;
            }
        }

        //(deposits, borrows) = livePosition();
        // deposit back to get targetCollatRatio (we always need to leave this in this ratio)
        uint256 _targetCollatRatio = targetCollatRatio;
        uint256 targetDeposit = getDepositFromBorrow(
            borrows,
            _targetCollatRatio
        );
        if (targetDeposit > deposits) {
            uint256 toDeposit = targetDeposit - deposits;
            if (toDeposit > minAsset) {
                _deposit(Math.min(toDeposit, balanceOfAsset()));
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

    function balanceOfAsset() internal view returns (uint256) {
        return ERC20(asset).balanceOf(address(this));
    }

    function estimatedPosition()
        public
        view
        virtual
        returns (uint256 deposits, uint256 borrows)
    {}

    function livePosition()
        public
        virtual
        returns (uint256 deposits, uint256 borrows)
    {}

    function estimatedCollatRatio()
        public
        view
        returns (uint256 _estimatedCollatRatio)
    {
        (uint256 deposits, uint256 borrows) = estimatedPosition();
        _estimatedCollatRatio = getCollatRatio(deposits, borrows);
    }

    function liveCollatRatio()
        public
        returns (uint256 _liveCollatRatio)
    {
        (uint256 deposits, uint256 borrows) = livePosition();
        _liveCollatRatio = getCollatRatio(deposits, borrows);
    }

    function estimatedTotalAssets() public view returns (uint256 _totalAssets) {
        _totalAssets += balanceOfAsset();
        (uint256 deposits, uint256 borrows) = estimatedPosition();
        _totalAssets += deposits - borrows;
        _totalAssets += (estimatedRewardsInAsset() * 9000) / 10000;
    }

    function estimatedRewardsInAsset()
        public
        view
        virtual
        returns (uint256 _rewardsInWant)
    {}

    // Section: LTV Math

    function getCollatRatio(
        uint256 deposits,
        uint256 borrows
    ) internal pure returns (uint256) {
        if (deposits == 0 || borrows == 0) {
            return 0;
        }
        return (borrows * COLLATERAL_RATIO_PRECISION) / deposits;
    }

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

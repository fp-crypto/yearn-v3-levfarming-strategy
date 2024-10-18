// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {BaseHealthCheck} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "forge-std/console.sol"; // TODO: DELETE

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

abstract contract BaseLevFarmingStrategy is BaseHealthCheck {
    using SafeERC20 for ERC20;

    // Basic constants
    uint256 internal constant WAD_BPS_RATIO = 1e14;
    uint256 internal constant COLLATERAL_RATIO_PRECISION = 1e18;
    uint256 internal constant PESSIMISM_FACTOR = 1000;

    // OPS State Variables
    uint256 internal constant DEFAULT_COLLAT_TARGET_MARGIN = 0.02e18;
    uint256 internal constant DEFAULT_COLLAT_MAX_MARGIN = 0.005e18;
    uint256 internal constant LIQUIDATION_WARNING_THRESHOLD = 0.01e18;

    uint256 public targetCollatRatio; // The LTV we are levering up to
    uint256 public maxBorrowCollatRatio; // The maximum the protocol will let us borrow
    uint256 public maxCollatRatio; // Closest to liquidation we'll risk

    uint256 public minAsset;
    uint256 public minRatio;
    uint256 public minRewardSell;
    uint8 public maxIterations;

    bool public initialized;

    constructor(
        address _asset,
        string memory _name
    ) BaseHealthCheck(_asset, _name) {}

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

    function setCollatRatios(
        uint256 _targetCollatRatio,
        uint256 _maxBorrowCollatRatio,
        uint256 _maxCollatRatio
    ) external virtual onlyManagement {
        targetCollatRatio = _targetCollatRatio;
        maxBorrowCollatRatio = _maxBorrowCollatRatio;
        maxCollatRatio = _maxCollatRatio;
    }

    /**
     * @dev Should deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy should attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
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

        (uint256 _deposits, uint256 _borrows) = livePosition();

        if (_borrows == 0) {
            _withdraw(Math.min(_amount, _deposits));
            return;
        }

        uint256 _currentSupply = _deposits - _borrows;
        uint256 _amountRequired = Math.min(_amount, _currentSupply);
        uint256 _newSupply = _currentSupply - _amountRequired;
        uint256 _targetCollatRatio = targetCollatRatio;
        uint256 _newBorrow = getBorrowFromSupply(
            _newSupply,
            _targetCollatRatio
        );

        if (_newBorrow < _borrows) {
            _leverDownTo(_newBorrow, _deposits, _borrows);
            (_deposits, _borrows) = livePosition();
            _withdrawExcessCollateral(_targetCollatRatio, _deposits, _borrows);
        } else {
            _withdraw(_amount);
        }
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        _claimRewards();
        _sellRewards();

        _tend(balanceOfAsset());

        _totalAssets = balanceOfAsset();
        (uint256 _deposits, uint256 _borrows) = livePosition();
        _totalAssets += _deposits - _borrows;
    }

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
     */
    function _tend(uint256 _totalIdle) internal override {
        // deposit available asset as collateral
        if (_totalIdle > minAsset) {
            _deposit(_totalIdle);
        }

        (uint256 _deposits, uint256 _borrows) = livePosition();
        uint256 _currentCollatRatio = getCollatRatio(_deposits, _borrows);
        uint256 _targetCollatRatio = targetCollatRatio;
        uint256 _minRatio = minRatio;

        if (_currentCollatRatio < _targetCollatRatio) {
            // we should lever up
            if (_targetCollatRatio - _currentCollatRatio > _minRatio) {
                // we only act on relevant differences
                _leverMax();
            }
        } else if (_currentCollatRatio > targetCollatRatio) {
            if (_currentCollatRatio - _targetCollatRatio > _minRatio) {
                uint256 newBorrow = getBorrowFromSupply(
                    _deposits - _borrows,
                    _targetCollatRatio
                );
                _leverDownTo(newBorrow, _deposits, _borrows);
            }
        }
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     *
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        (uint256 _deposits, uint256 _borrows) = livePosition();

        if (_borrows > minAsset) {
            _leverDownTo(0, _deposits, _borrows);
        }
        (_deposits, _borrows) = livePosition();
        if (_borrows == 0) _withdraw(Math.min(_deposits, _amount));
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

        _leverUpTo(totalAmountToBorrow, assetBalance, deposits, borrows);
    }

    function _leverUpTo(
        uint256 totalAmountToBorrow,
        uint256 assetBalance,
        uint256 deposits,
        uint256 borrows
    ) internal virtual {
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
        uint256 _targetAmountBorrowed,
        uint256 _deposits,
        uint256 _borrows
    ) internal virtual {
        uint256 _minAsset = minAsset;

        if (_borrows > _targetAmountBorrowed) {
            uint256 _assetBalance = balanceOfAsset();
            uint256 _remainingRepayAmount = _borrows - _targetAmountBorrowed;

            uint256 _maxCollatRatio = maxCollatRatio;
            uint8 _maxIterations = maxIterations;

            for (
                uint8 i = 0;
                i < _maxIterations && _remainingRepayAmount > _minAsset;
                i++
            ) {
                uint256 _withdrawn = _withdrawExcessCollateral(
                    _maxCollatRatio,
                    _deposits,
                    _borrows
                );
                _assetBalance = _assetBalance + _withdrawn; // track ourselves to save gas
                uint256 _toRepay = _remainingRepayAmount;
                if (_toRepay > _assetBalance) {
                    _toRepay = _assetBalance;
                }
                uint256 _repaid = _repay(_toRepay);

                // track ourselves to save gas
                _deposits = _deposits - _withdrawn;
                _assetBalance = _assetBalance - _repaid;
                _borrows = _borrows - _repaid;

                _remainingRepayAmount = _remainingRepayAmount - _repaid;
            }
        }

        //(deposits, borrows) = livePosition();
        // deposit back to get targetCollatRatio (we always need to leave this in this ratio)
        uint256 _targetCollatRatio = targetCollatRatio;
        uint256 _targetDeposit = getDepositFromBorrow(
            _borrows,
            _targetCollatRatio
        );
        if (_targetDeposit > _deposits) {
            uint256 _toDeposit = _targetDeposit - _deposits;
            if (_toDeposit > _minAsset) {
                _deposit(Math.min(_toDeposit, balanceOfAsset()));
            }
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

    function liveCollatRatio() public returns (uint256 _liveCollatRatio) {
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

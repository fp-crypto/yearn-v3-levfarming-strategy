// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {BaseHealthCheck, BaseStrategy} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Base Leveraged Farming Strategy
 * @notice Abstract base contract for leveraged yield farming strategies
 * @dev Implements core leveraged farming functionality with configurable LTV ratios,
 *      automated position management, and safety checks
 */
abstract contract BaseLevFarmingStrategy is BaseHealthCheck {
    using SafeERC20 for ERC20;

    /// @notice Ratio between WAD (1e18) and BPS (1e4)
    uint256 internal constant WAD_BPS_RATIO = 1e14;

    /// @notice Precision used for collateral ratio calculations (1e18)
    uint256 internal constant COLLATERAL_RATIO_PRECISION = 1e18;

    /// @notice Factor used to add pessimism to calculations
    uint256 internal constant PESSIMISM_FACTOR = 1000;

    /// @notice Default target margin for collateral ratio (2%)
    uint64 internal constant DEFAULT_COLLAT_TARGET_MARGIN = 0.02e18;

    /// @notice Default maximum margin for collateral ratio (0.5%)
    uint64 internal constant DEFAULT_COLLAT_MAX_MARGIN = 0.005e18;

    /// @notice Threshold for liquidation warnings (1%)
    uint64 internal constant LIQUIDATION_WARNING_THRESHOLD = 0.01e18;

    /// @notice Target Loan-to-Value ratio the strategy aims to maintain
    uint64 public targetLTV;

    /// @notice Maximum LTV ratio the protocol allows for borrowing
    uint64 public maxBorrowLTV;

    /// @notice Maximum LTV ratio before risk of liquidation
    uint64 public maxLTV;

    /// @notice Maximum base fee in gwei for tend operations
    uint16 public maxTendBasefeeGwei = 12;

    /// @notice Maximum number of iterations for leveraging operations
    uint8 public maxIterations = 12;

    /// @notice Minimum ratio difference to trigger position adjustments (0.5%)
    uint64 public minAdjustRatio = 0.005 ether;

    /// @notice Minimum amount of asset to process
    uint96 public minAsset = 100;

    /// @notice Minimum amount of rewards to sell
    uint96 public minRewardSell = 1e15;

    constructor(
        address _asset,
        string memory _name
    ) BaseHealthCheck(_asset, _name) {}

    /**
     * @notice Sets the LTV ratios for the strategy
     * @param _targetLTV Target Loan-to-Value ratio to maintain
     * @param _maxBorrowLTV Maximum borrowing LTV allowed by the protocol
     * @param _maxLTV Maximum LTV before liquidation risk
     * @dev Only callable by management
     */
    function setLTVs(
        uint64 _targetLTV,
        uint64 _maxBorrowLTV,
        uint64 _maxLTV
    ) external virtual onlyManagement {
        targetLTV = _targetLTV;
        maxBorrowLTV = _maxBorrowLTV;
        maxLTV = _maxLTV;
    }

    /// @notice Sets maximum base fee in gwei for tend operations
    /// @param _maxTendBasefeeGwei Maximum base fee in gwei
    /// @dev Only callable by management
    function setMaxTendBasefeeGwei(
        uint16 _maxTendBasefeeGwei
    ) external onlyManagement {
        maxTendBasefeeGwei = _maxTendBasefeeGwei;
    }

    /// @notice Sets maximum number of iterations for leveraging operations
    /// @param _maxIterations Maximum number of iterations
    /// @dev Only callable by management
    function setMaxIterations(uint8 _maxIterations) external onlyManagement {
        maxIterations = _maxIterations;
    }

    /// @notice Sets minimum ratio difference to trigger position adjustments
    /// @param _minAdjustRatio Minimum adjustment ratio in WAD (1e18)
    /// @dev Only callable by management
    function setMinAdjustRatio(uint64 _minAdjustRatio) external onlyManagement {
        minAdjustRatio = _minAdjustRatio;
    }

    /// @notice Sets minimum amount of asset to process
    /// @param _minAsset Minimum asset amount
    /// @dev Only callable by management
    function setMinAsset(uint96 _minAsset) external onlyManagement {
        minAsset = _minAsset;
    }

    /// @notice Sets minimum amount of rewards to sell
    /// @param _minRewardSell Minimum reward amount
    /// @dev Only callable by management
    function setMinRewardSell(uint96 _minRewardSell) external onlyManagement {
        minRewardSell = _minRewardSell;
    }

    /// @inheritdoc BaseStrategy
    function _deployFunds(uint256 /*_amount*/) internal override {
        uint256 assetBalance = balanceOfAsset();
        // deposit available asset as collateral
        if (assetBalance > minAsset) {
            _deposit(assetBalance);
        }

        // check current LTV
        uint256 _liveLTV = liveLTV();

        // we should lever up
        if (targetLTV > _liveLTV && targetLTV - _liveLTV > minAdjustRatio) {
            _leverMax();
        }
    }

    /// @inheritdoc BaseStrategy
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
        uint256 _targetLTV = targetLTV;
        uint256 _newBorrow = getBorrowFromSupply(_newSupply, _targetLTV);

        if (_newBorrow < _borrows) {
            _leverDownTo(_newBorrow, _deposits, _borrows);
            (_deposits, _borrows) = livePosition();
            _withdrawExcessCollateral(_targetLTV, _deposits, _borrows);
        } else {
            _withdraw(_amount);
        }
    }

    /// @inheritdoc BaseStrategy
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

    /// @inheritdoc BaseStrategy
    function _tend(uint256 _totalIdle) internal override {
        // deposit available asset as collateral
        if (_totalIdle > minAsset) {
            _deposit(_totalIdle);
        }

        (uint256 _deposits, uint256 _borrows) = livePosition();
        uint256 _currentLTV = getLTV(_deposits, _borrows);
        uint256 _targetLTV = uint256(targetLTV);
        uint256 _minAdjustRatio = uint256(minAdjustRatio);

        if (_currentLTV < _targetLTV) {
            // we should lever up
            if (_targetLTV - _currentLTV > _minAdjustRatio) {
                // we only act on relevant differences
                _leverMax();
            }
        } else if (_currentLTV > targetLTV) {
            if (_currentLTV - _targetLTV > _minAdjustRatio) {
                uint256 newBorrow = getBorrowFromSupply(
                    _deposits - _borrows,
                    _targetLTV
                );
                _leverDownTo(newBorrow, _deposits, _borrows);
            }
        }
    }

    /// @inheritdoc BaseStrategy
    function _tendTrigger() internal view override returns (bool) {
        if (TokenizedStrategy.totalAssets() == 0) {
            return false;
        }

        uint256 _estimatedLTV = estimatedLTV();

        if (_estimatedLTV == 0) {
            return false;
        }

        (, uint256 _liquidationThreshold) = getProtocolLTVs();
        // we must lever down if we are over the max threshold
        if (_estimatedLTV >= maxLTV || _estimatedLTV >= _liquidationThreshold) {
            return true;
        }

        // All other checks can wait for low gas
        if (block.basefee >= uint256(maxTendBasefeeGwei) * 1e9) {
            return false;
        }

        uint256 _targetLTV = uint256(targetLTV);
        uint256 _minAdjustRatio = uint256(minAdjustRatio);

        // Tend if ltv is higher than the target range
        if (_estimatedLTV >= _targetLTV + _minAdjustRatio) {
            return true;
        }

        if (TokenizedStrategy.isShutdown()) {
            return false;
        }

        // Tend if ltv is lower than target range
        if (_estimatedLTV <= _targetLTV - _minAdjustRatio) {
            return true;
        }

        return false;
    }

    /// @inheritdoc BaseStrategy
    function _emergencyWithdraw(uint256 _amount) internal override {
        (uint256 _deposits, uint256 _borrows) = livePosition();

        if (_borrows > minAsset) {
            _leverDownTo(0, _deposits, _borrows);
        }
        (_deposits, _borrows) = livePosition();
        if (_borrows == 0) _withdraw(Math.min(_deposits, _amount));
    }

    /// @notice Deposits asset tokens into the lending platform
    /// @param _amount Amount of asset tokens to deposit
    /// @dev Must be implemented by the specific lending platform integration
    function _deposit(uint256 _amount) internal virtual {}

    /// @notice Withdraws asset tokens from the lending platform
    /// @param _amount Amount of asset tokens to withdraw
    /// @return Amount of asset tokens actually withdrawn
    /// @dev Must be implemented by the specific lending platform integration
    function _withdraw(uint256 _amount) internal virtual returns (uint256) {}

    /// @notice Borrows asset tokens from the lending platform
    /// @param _amount Amount of asset tokens to borrow
    /// @dev Must be implemented by the specific lending platform integration
    function _borrow(uint256 _amount) internal virtual {}

    /// @notice Repays borrowed asset tokens to the lending platform
    /// @param _amount Amount of asset tokens to repay
    /// @return Amount of asset tokens actually repaid
    /// @dev Must be implemented by the specific lending platform integration
    function _repay(uint256 _amount) internal virtual returns (uint256) {}

    /// @notice Claims any available rewards from the lending platform
    /// @dev Must be implemented by the specific lending platform integration
    function _claimRewards() internal virtual {}

    /// @notice Sells claimed reward tokens for the strategy's asset token
    /// @dev Must be implemented by the specific lending platform integration
    function _sellRewards() internal virtual {}

    /// @notice Estimates the value of reward tokens in terms of asset tokens
    /// @param _token Address of the reward token
    /// @param _amount Amount of reward tokens
    /// @return Estimated value in asset tokens
    /// @dev Must be implemented by the specific lending platform integration
    function _estimateTokenToAsset(
        address _token,
        uint256 _amount
    ) internal view virtual returns (uint256) {}

    /// @notice Leverages the position up to the target LTV ratio
    /// @dev Calculates required borrowing and executes leveraging in iterations
    function _leverMax() internal {
        (uint256 deposits, uint256 borrows) = livePosition();
        uint256 assetBalance = balanceOfAsset();

        uint256 realSupply = deposits - borrows + assetBalance;
        uint256 newBorrow = getBorrowFromSupply(realSupply, targetLTV);
        uint256 totalAmountToBorrow = newBorrow - borrows;

        _leverUpTo(totalAmountToBorrow, assetBalance, deposits, borrows);
    }

    /// @notice Executes leveraging up to a target borrowed amount
    /// @param totalAmountToBorrow Total amount to borrow through leveraging
    /// @param assetBalance Current balance of asset token
    /// @param deposits Current deposits in lending platform
    /// @param borrows Current borrows from lending platform
    /// @dev Executes leveraging in iterations up to maxIterations
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
                maxBorrowLTV
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

    /// @notice Reduces leverage down to a target borrowed amount
    /// @param _targetAmountBorrowed Target amount to maintain borrowed
    /// @param _deposits Current deposits in lending platform
    /// @param _borrows Current borrows from lending platform
    /// @dev Executes deleveraging in iterations up to maxIterations
    function _leverDownTo(
        uint256 _targetAmountBorrowed,
        uint256 _deposits,
        uint256 _borrows
    ) internal virtual {
        uint256 _minAsset = minAsset;

        if (_borrows > _targetAmountBorrowed) {
            uint256 _assetBalance = balanceOfAsset();
            uint256 _remainingRepayAmount = _borrows - _targetAmountBorrowed;

            uint256 _maxLTV = maxLTV;
            uint8 _maxIterations = maxIterations;

            for (
                uint8 i = 0;
                i < _maxIterations && _remainingRepayAmount > _minAsset;
                i++
            ) {
                uint256 _withdrawn = _withdrawExcessCollateral(
                    _maxLTV,
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
        // deposit back to get targetLTV (we always need to leave this in this ratio)
        uint256 _targetLTV = targetLTV;
        uint256 _targetDeposit = getDepositFromBorrow(_borrows, _targetLTV);
        if (_targetDeposit > _deposits) {
            uint256 _toDeposit = _targetDeposit - _deposits;
            if (_toDeposit > _minAsset) {
                _deposit(Math.min(_toDeposit, balanceOfAsset()));
            }
        }
    }

    /// @notice Withdraws excess collateral above target ratio
    /// @param collatRatio Target collateral ratio to maintain
    /// @param deposits Current deposits in lending platform
    /// @param borrows Current borrows from lending platform
    /// @return amount Amount of collateral withdrawn
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

    /// @notice Gets the current balance of asset token held by this contract
    /// @return Current balance of asset token
    function balanceOfAsset() internal view returns (uint256) {
        return ERC20(asset).balanceOf(address(this));
    }

    /// @notice Gets the protocol's LTV and liquidation threshold values
    /// @return ltv The loan-to-value ratio in WAD
    /// @return liquidationThreshold The liquidation threshold in WAD
    function getProtocolLTVs()
        internal
        view
        virtual
        returns (uint256 ltv, uint256 liquidationThreshold)
    {}

    /// @notice Returns the estimated deposits and borrows from the lending platform
    /// @return deposits Estimated amount of asset tokens deposited
    /// @return borrows Estimated amount of asset tokens borrowed
    /// @dev Must be implemented by the specific lending platform integration
    ///      Should use view functions to estimate position without state changes
    function estimatedPosition()
        public
        view
        virtual
        returns (uint256 deposits, uint256 borrows)
    {}

    /// @notice Returns the current deposits and borrows from the lending platform
    /// @return deposits Current amount of asset tokens deposited
    /// @return borrows Current amount of asset tokens borrowed
    /// @dev Must be implemented by the specific lending platform integration
    ///      May perform state changes to sync and get accurate position
    function livePosition()
        public
        virtual
        returns (uint256 deposits, uint256 borrows)
    {}

    /// @notice Gets the estimated LTV ratio based on current position
    /// @return _estimatedLTV Current estimated LTV ratio
    function estimatedLTV() public view returns (uint256 _estimatedLTV) {
        (uint256 deposits, uint256 borrows) = estimatedPosition();
        _estimatedLTV = getLTV(deposits, borrows);
    }

    /// @notice Gets the current live LTV ratio by syncing position
    /// @return _liveLTV Current live LTV ratio
    function liveLTV() public returns (uint256 _liveLTV) {
        (uint256 deposits, uint256 borrows) = livePosition();
        _liveLTV = getLTV(deposits, borrows);
    }

    /// @notice Estimates the total assets managed by this strategy
    /// @return _totalAssets Total value of assets in strategy
    function estimatedTotalAssets() public view returns (uint256 _totalAssets) {
        _totalAssets += balanceOfAsset();
        (uint256 deposits, uint256 borrows) = estimatedPosition();
        _totalAssets += deposits - borrows;
        _totalAssets += (estimatedRewardsInAsset() * 9000) / 10000;
    }

    /// @notice Estimates the value of unclaimed rewards in terms of asset tokens
    /// @return _rewardsInWant Estimated value of unclaimed rewards in asset tokens
    /// @dev Must be implemented by the specific lending platform integration
    ///      Should account for all types of rewards and their current market prices
    function estimatedRewardsInAsset()
        public
        view
        virtual
        returns (uint256 _rewardsInWant)
    {}

    // Section: LTV Math

    /// @notice Calculates the Loan-to-Value ratio
    /// @param deposits Amount of deposits
    /// @param borrows Amount of borrows
    /// @return Current LTV ratio in COLLATERAL_RATIO_PRECISION
    function getLTV(
        uint256 deposits,
        uint256 borrows
    ) internal pure returns (uint256) {
        if (deposits == 0 || borrows == 0) {
            return 0;
        }
        return (borrows * COLLATERAL_RATIO_PRECISION) / deposits;
    }

    /// @notice Calculates how much can be borrowed given a deposit amount and collateral ratio
    /// @param deposit Amount of deposits
    /// @param collatRatio Target collateral ratio
    /// @return Maximum amount that can be borrowed
    function getBorrowFromDeposit(
        uint256 deposit,
        uint256 collatRatio
    ) internal pure returns (uint256) {
        if (collatRatio == 0) return 0;
        return (deposit * collatRatio) / COLLATERAL_RATIO_PRECISION;
    }

    /// @notice Calculates required deposit amount for a given borrow amount and collateral ratio
    /// @param borrow Amount borrowed
    /// @param collatRatio Target collateral ratio
    /// @return Required deposit amount
    function getDepositFromBorrow(
        uint256 borrow,
        uint256 collatRatio
    ) internal pure returns (uint256) {
        if (collatRatio == 0) return type(uint256).max;
        return (borrow * COLLATERAL_RATIO_PRECISION) / collatRatio;
    }

    /// @notice Calculates optimal borrow amount given supply and target collateral ratio
    /// @param supply Total supply amount
    /// @param collatRatio Target collateral ratio
    /// @return Optimal borrow amount
    function getBorrowFromSupply(
        uint256 supply,
        uint256 collatRatio
    ) internal pure returns (uint256) {
        if (collatRatio == 0) return 0;
        return
            (supply * collatRatio) / (COLLATERAL_RATIO_PRECISION - collatRatio);
    }
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseLevFarmingStrategy, ERC20, SafeERC20, Math} from "./BaseLevFarmingStrategy.sol";

import {IPoolDataProvider} from "./interfaces/aave/v3/core/IPoolDataProvider.sol";
import {IAToken} from "./interfaces/aave/v3/core/IAToken.sol";
import {IVariableDebtToken} from "./interfaces/aave/v3/core/IVariableDebtToken.sol";
import {IPool} from "./interfaces/aave/v3/core/IPool.sol";
import {IPoolAddressesProvider} from "./interfaces/aave/v3/core/IPoolAddressesProvider.sol";
import {DataTypes} from "./interfaces/aave/v3/core/DataTypes.sol";
import {IFlashLoanReceiver} from "./interfaces/aave/v3/core/IFlashLoanReceiver.sol";
import {IRewardsController} from "./interfaces/aave/v3/periphery/IRewardsController.sol";

import "forge-std/console.sol"; // TODO: DELETE

/// @title Leveraged Aave Strategy
/// @notice A strategy that uses Aave V3 for leveraged lending/borrowing
/// @dev Implements flash loans and leveraged positions using Aave V3 protocol
/// @author Generic Leverage Farming Strategy Team
contract LevAaveStrategy is BaseLevFarmingStrategy, IFlashLoanReceiver {
    using SafeERC20 for ERC20;

    // protocol address
    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;
    IPool public immutable POOL;
    IPoolDataProvider private immutable PROTOCOL_DATA_PROVIDER;
    IRewardsController private immutable REWARDS_CONTROLLER;
    IAToken public immutable A_TOKEN;
    IVariableDebtToken public immutable DEBT_TOKEN;

    bool public flashloanEnabled = true;

    uint16 private constant REFERRAL = 0;

    address[] private rewardTokens;

    /// @notice Initializes the strategy with required addresses and settings
    /// @param _asset The underlying asset token address
    /// @param _name The name of the strategy
    /// @param _addressesProvider The Aave V3 addresses provider contract address
    constructor(
        address _asset,
        string memory _name,
        address _addressesProvider
    ) BaseLevFarmingStrategy(_asset, _name) {
        ADDRESSES_PROVIDER = IPoolAddressesProvider(_addressesProvider);
        POOL = IPool(IPoolAddressesProvider(_addressesProvider).getPool());
        PROTOCOL_DATA_PROVIDER = IPoolDataProvider(
            IPoolAddressesProvider(_addressesProvider).getPoolDataProvider()
        );
        REWARDS_CONTROLLER = IRewardsController(
            IPoolAddressesProvider(_addressesProvider).getAddress(
                keccak256("INCENTIVES_CONTROLLER")
            )
        );

        // Set lending+borrowing tokens
        (address _aToken, , address _debtToken) = PROTOCOL_DATA_PROVIDER
            .getReserveTokensAddresses(address(asset));

        A_TOKEN = IAToken(_aToken);
        DEBT_TOKEN = IVariableDebtToken(_debtToken);

        //_setEMode(true); // use emode if it's available
        // Set collateral targets
        _autoConfigureLTVs();

        // approve spend protocol spend
        ERC20(address(_asset)).safeApprove(address(POOL), type(uint256).max);
        ERC20(address(_aToken)).safeApprove(address(POOL), type(uint256).max);
    }

    /// @notice Sets the Loan-to-Value ratios for the strategy
    /// @dev All values should be in WAD (1e18) format
    /// @param _targetLTV The target LTV ratio to maintain
    /// @param _maxBorrowLTV The maximum LTV ratio for borrowing
    /// @param _maxLTV The maximum allowed LTV ratio
    function setLTVs(
        uint64 _targetLTV,
        uint64 _maxBorrowLTV,
        uint64 _maxLTV
    ) external override onlyManagement {
        (uint256 ltv, uint256 liquidationThreshold) = getProtocolLTVs();
        require(_targetLTV < liquidationThreshold);
        require(_maxLTV < liquidationThreshold);
        require(_targetLTV < _maxLTV);
        require(_maxBorrowLTV < ltv);

        targetLTV = _targetLTV;
        maxBorrowLTV = _maxBorrowLTV;
        maxLTV = _maxLTV;
    }

    /// @notice Enables or disables flash loan functionality
    /// @param _flashloanEnabled True to enable flash loans, false to disable
    function setFlashloanEnabled(
        bool _flashloanEnabled
    ) external onlyManagement {
        flashloanEnabled = _flashloanEnabled;
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _deposit(uint256 _amount) internal override {
        if (_amount == 0) return;
        POOL.supply(address(asset), _amount, address(this), REFERRAL);
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _withdraw(uint256 _amount) internal override returns (uint256) {
        if (_amount == 0) return 0;
        return POOL.withdraw(address(asset), _amount, address(this));
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _borrow(uint256 _amount) internal override {
        if (_amount == 0) return;
        POOL.borrow(address(asset), _amount, 2, REFERRAL, address(this));
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _repay(uint256 _amount) internal override returns (uint256) {
        if (_amount == 0) return 0;
        return POOL.repay(address(asset), _amount, 2, address(this));
    }

    function _repayWithATokens(uint256 _amount) internal returns (uint256) {
        if (_amount == 0) return 0;
        return POOL.repayWithATokens(address(asset), _amount, 2);
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _leverUpTo(
        uint256 totalAmountToBorrow,
        uint256 assetBalance,
        uint256 deposits,
        uint256 borrows
    ) internal override {
        if (!flashloanEnabled)
            return
                super._leverUpTo(
                    totalAmountToBorrow,
                    assetBalance,
                    deposits,
                    borrows
                );
        _flashloan(totalAmountToBorrow);
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _leverDownTo(
        uint256 _targetAmountBorrowed,
        uint256 /*_deposits*/,
        uint256 _borrows
    ) internal override {
        _repayWithATokens(_borrows - _targetAmountBorrowed);
    }

    function _flashloan(uint256 _amount) internal {
        if (_amount == 0) return;
        address[] memory _tokens = new address[](1);
        _tokens[0] = address(asset);
        uint256[] memory _amounts = new uint256[](1);
        _amounts[0] = Math.min(_amount, asset.balanceOf(address(A_TOKEN))); // max loanable is the _amount of asset held by aave
        uint256[] memory _modes = new uint256[](1);
        _modes[0] = 2;
        POOL.flashLoan(
            address(this),
            _tokens,
            _amounts,
            _modes,
            address(this),
            "",
            REFERRAL
        );
    }

    // function _setEMode(bool _enableEmode) internal {
    //     uint8 _emodeCategory;

    //     for (uint8 i = 1; i < 255; i++) {
    //         DataTypes.CollateralConfig memory cfg = pool
    //             .getEModeCategoryCollateralConfig(i);
    //         // check if it is an active eMode
    //         if (cfg.liquidationThreshold != 0) {
    //             EModeConfiguration.isReserveEnabledOnBitmap(
    //                 pool.getEModeCategoryCollateralBitmap(i),
    //                 someReserveIndex
    //             );
    //             EModeConfiguration.isReserveEnabledOnBitmap(
    //                 pool.getEModeCategoryBorrowableBitmap(i),
    //                 someReserveIndex
    //             );
    //         }
    //     }

    //     uint8 _emodeCategory = uint8(
    //         PROTOCOL_DATA_PROVIDER.getReserveEModeCategory(address(asset))
    //     );
    //     if (_emodeCategory == 0) return;
    //     POOL.setUserEMode(_enableEmode ? _emodeCategory : 0);
    // }

    function _autoConfigureLTVs() internal {
        (uint256 ltv, uint256 liquidationThreshold) = getProtocolLTVs();
        require(ltv > DEFAULT_COLLAT_TARGET_MARGIN); // dev: !ltv
        targetLTV = uint64(ltv) - DEFAULT_COLLAT_TARGET_MARGIN;
        maxLTV = uint64(liquidationThreshold) - DEFAULT_COLLAT_MAX_MARGIN;
        maxBorrowLTV = uint64(ltv) - DEFAULT_COLLAT_MAX_MARGIN;
    }

    // flashloan callback

    /// @notice Callback function called by Aave after flash loan
    /// @dev This function is called after your contract has received the flash loaned amount
    /// @param assets The addresses of the assets being flash-borrowed
    /// @param amounts The amounts of the assets being flash-borrowed
    /// @param . The fees to be paid for each asset flash-borrowed
    /// @param initiator The address initiating the flash loan
    /// @param . Arbitrary bytes passed to the flashLoan function
    /// @return success Whether the operation was successful
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata /*premiums*/,
        address initiator,
        bytes calldata /*params*/
    ) external returns (bool) {
        require(address(POOL) == msg.sender); // dev: callers must be the aave pool
        require(initiator == address(this)); // dev: initiator must be this strategy
        require(assets[0] == address(asset)); // dev: loan asset must be asset
        require(amounts.length == 1);
        _deposit(asset.balanceOf(address(this)));
        return true;
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _claimRewards() internal override {
        IRewardsController _rewardsController = REWARDS_CONTROLLER;
        address[] memory assets = new address[](2);
        assets[0] = address(A_TOKEN);
        assets[1] = address(DEBT_TOKEN);
        _rewardsController.claimAllRewards(assets, address(this));
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _sellRewards() internal override {
        // TODO: implement
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function estimatedPosition()
        public
        view
        override
        returns (uint256 deposits, uint256 borrows)
    {
        (deposits, borrows) = _currentPosition();
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function livePosition()
        public
        override
        returns (uint256 deposits, uint256 borrows)
    {
        (deposits, borrows) = _currentPosition();
    }

    function _currentPosition()
        internal
        view
        returns (uint256 deposits, uint256 borrows)
    {
        deposits = A_TOKEN.balanceOf(address(this));
        borrows = ERC20(address(DEBT_TOKEN)).balanceOf(address(this));
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _estimateTokenToAsset(
        address _from,
        uint256 _amount
    ) internal view override returns (uint256) {
        // TODO: Implement
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function estimatedRewardsInAsset()
        public
        view
        override
        returns (uint256 _rewardsInAsset)
    {
        // TODO: Implement
    }

    /// @inheritdoc BaseLevFarmingStrategy
    /// @dev Takes into account E-Mode if enabled
    function getProtocolLTVs()
        internal
        view
        override
        returns (uint256 ltv, uint256 liquidationThreshold)
    {
        uint8 _emodeCategory = uint8(POOL.getUserEMode(address(this)));

        if (_emodeCategory == 0) {
            // emode disabled
            (, ltv, liquidationThreshold, , , , , , , ) = PROTOCOL_DATA_PROVIDER
                .getReserveConfigurationData(address(asset));
        } else {
            DataTypes.EModeCategory memory _eModeCategoryData = POOL
                .getEModeCategoryData(_emodeCategory);
            ltv = uint256(_eModeCategoryData.ltv);
            liquidationThreshold = uint256(
                _eModeCategoryData.liquidationThreshold
            );
        }
        // convert bps to wad
        ltv = ltv * WAD_BPS_RATIO;
        liquidationThreshold = liquidationThreshold * WAD_BPS_RATIO;
    }
}

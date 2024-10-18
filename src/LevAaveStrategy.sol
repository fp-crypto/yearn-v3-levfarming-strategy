// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "./BaseLevFarmingStrategy.sol";

import {IPoolDataProvider} from "./interfaces/aave/v3/core/IPoolDataProvider.sol";
import {IAToken} from "./interfaces/aave/v3/core/IAToken.sol";
import {IVariableDebtToken} from "./interfaces/aave/v3/core/IVariableDebtToken.sol";
import {IPool} from "./interfaces/aave/v3/core/IPool.sol";
import {IPoolAddressesProvider} from "./interfaces/aave/v3/core/IPoolAddressesProvider.sol";
import {DataTypes} from "./interfaces/aave/v3/core/DataTypes.sol";
import {IFlashLoanReceiver} from "./interfaces/aave/v3/core/IFlashLoanReceiver.sol";
import {IRewardsController} from "./interfaces/aave/v3/periphery/IRewardsController.sol";

import "forge-std/console.sol"; // TODO: DELETE

contract LevAaveStrategy is BaseLevFarmingStrategy, IFlashLoanReceiver {
    using SafeERC20 for ERC20;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // protocol address
    IPoolDataProvider private constant PROTOCOL_DATA_PROVIDER =
        IPoolDataProvider(0x41393e5e337606dc3821075Af65AeE84D7688CBD);
    IRewardsController private constant REWARDS_CONTROLLER =
        IRewardsController(0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb);

    IPool public constant POOL =
        IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IPoolAddressesProvider public constant ADDRESSES_PROVIDER =
        IPoolAddressesProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e);

    uint16 private constant REFERRAL = 0;

    // Supply and borrow tokens
    IAToken public aToken;
    IVariableDebtToken public debtToken;
    address[] private rewardTokens;

    bool public flashloanEnabled = true;

    constructor(
        address _asset,
        string memory _name
    ) BaseLevFarmingStrategy(_asset, _name) {
        _initStrategy(_asset);
    }

    function _initStrategy(address _asset) internal override {
        super._initStrategy(_asset);

        // Set lending+borrowing tokens
        (address _aToken, , address _debtToken) = PROTOCOL_DATA_PROVIDER
            .getReserveTokensAddresses(address(asset));

        require(address(aToken) == address(0), "!already initialized");
        aToken = IAToken(_aToken);
        debtToken = IVariableDebtToken(_debtToken);

        //_setEMode(true); // use emode if it's available
        // Set collateral targets
        _autoConfigureLTVs();

        // approve spend protocol spend
        ERC20(address(_asset)).safeApprove(address(POOL), type(uint256).max);
        ERC20(address(_aToken)).safeApprove(address(POOL), type(uint256).max);
    }

    function setCollatRatios(
        uint256 _targetCollatRatio,
        uint256 _maxBorrowCollatRatio,
        uint256 _maxCollatRatio
    ) external override onlyManagement {
        (uint256 ltv, uint256 liquidationThreshold) = getProtocolCollatRatios();
        require(_targetCollatRatio < liquidationThreshold);
        require(_maxCollatRatio < liquidationThreshold);
        require(_targetCollatRatio < _maxCollatRatio);
        require(_maxBorrowCollatRatio < ltv);

        targetCollatRatio = _targetCollatRatio;
        maxCollatRatio = _maxCollatRatio;
        maxBorrowCollatRatio = _maxBorrowCollatRatio;
    }

    function _deposit(uint256 _amount) internal override {
        if (_amount == 0) return;
        POOL.supply(address(asset), _amount, address(this), REFERRAL);
    }

    function _withdraw(uint256 _amount) internal override returns (uint256) {
        if (_amount == 0) return 0;
        return POOL.withdraw(address(asset), _amount, address(this));
    }

    function _borrow(uint256 _amount) internal override {
        if (_amount == 0) return;
        POOL.borrow(address(asset), _amount, 2, REFERRAL, address(this));
    }

    function _repay(uint256 _amount) internal override returns (uint256) {
        if (_amount == 0) return 0;
        return POOL.repay(address(asset), _amount, 2, address(this));
    }

    function _repayWithATokens(uint256 _amount) internal returns (uint256) {
        if (_amount == 0) return 0;
        return POOL.repayWithATokens(address(asset), _amount, 2);
    }

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
        _amounts[0] = Math.min(_amount, asset.balanceOf(address(aToken))); // max loanable is the _amount of asset held by aave
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

    function _setEMode(bool _enableEmode) internal {
        uint8 _emodeCategory = uint8(
            PROTOCOL_DATA_PROVIDER.getReserveEModeCategory(address(asset))
        );
        if (_emodeCategory == 0) return;
        POOL.setUserEMode(_enableEmode ? _emodeCategory : 0);
    }

    function _autoConfigureLTVs() internal {
        (uint256 ltv, uint256 liquidationThreshold) = getProtocolCollatRatios();
        targetCollatRatio = ltv - DEFAULT_COLLAT_TARGET_MARGIN;
        maxCollatRatio = liquidationThreshold - DEFAULT_COLLAT_MAX_MARGIN;
        maxBorrowCollatRatio = ltv - DEFAULT_COLLAT_MAX_MARGIN;
    }

    // flashloan callback

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata /* premiums */,
        address initiator,
        bytes calldata /* params */
    ) external returns (bool) {
        require(address(POOL) == msg.sender); // dev: callers must be the aave pool
        require(initiator == address(this)); // dev: initiator must be this strategy
        require(assets[0] == address(asset)); // dev: loan asset must be asset
        require(amounts.length == 1);
        _deposit(asset.balanceOf(address(this)));
        return true;
    }

    function _claimRewards() internal override {
        IRewardsController _rewardsController = REWARDS_CONTROLLER;
        address[] memory assets = new address[](2);
        assets[0] = address(aToken);
        assets[1] = address(debtToken);
        _rewardsController.claimAllRewards(assets, address(this));
    }

    function _sellRewards() internal override {
        // TODO: implement
    }

    function estimatedPosition()
        public
        view
        override
        returns (uint256 deposits, uint256 borrows)
    {
        (deposits, borrows) = _currentPosition();
    }

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
        deposits = aToken.balanceOf(address(this));
        borrows = ERC20(address(debtToken)).balanceOf(address(this));
    }

    function _estimateTokenToAsset(
        address _from,
        uint256 _amount
    ) internal view override returns (uint256) {
        // TODO: Implement
    }

    function estimatedRewardsInAsset()
        public
        view
        override
        returns (uint256 _rewardsInAsset)
    {
        // TODO: Implement
    }

    function getProtocolCollatRatios()
        internal
        view
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

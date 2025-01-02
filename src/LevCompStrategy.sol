// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseLevFarmingStrategy, BaseStrategy, ERC20, SafeERC20, Math} from "./BaseLevFarmingStrategy.sol";
import {ComptrollerI} from "./interfaces/compound/ComptrollerI.sol";
import {CErc20I, CTokenI} from "./interfaces/compound/CErc20I.sol";

/// @title Leveraged Compound V2 Strategy
/// @notice A strategy that uses Compound V2 for leveraged lending/borrowing to maximize yield
/// @dev Implements leveraged positions using Compound V2's lending/borrowing capabilities
///      Inherits from BaseLevFarmingStrategy for core leverage farming functionality
///      Uses cTokens to represent deposits and manage collateral/borrowing positions
/// @author Generic Leverage Farming Strategy Team
contract LevCompStrategy is BaseLevFarmingStrategy {
    using SafeERC20 for ERC20;

    /// @notice The Compound Comptroller contract that manages the money markets
    ComptrollerI public immutable COMPTROLLER;

    /// @notice The Compound cToken contract representing the supplied asset
    CErc20I public immutable C_TOKEN;

    /// @notice Flag to disable COMP rewards claiming
    /// @dev When true, _claimRewards() will not claim COMP tokens
    bool public dontClaimComp = false;

    /// @notice Initializes the strategy with required addresses and settings
    /// @param _cToken The Compound cToken contract address corresponding to the asset
    /// @param _name The name of the strategy for identification purposes
    /// @dev Validates that the cToken matches the asset, sets up the Comptroller,
    ///      configures LTV parameters, and approves token spending
    constructor(
        address _cToken,
        string memory _name
    ) BaseLevFarmingStrategy(CErc20I(_cToken).underlying(), _name) {
        C_TOKEN = CErc20I(_cToken);
        COMPTROLLER = ComptrollerI(CErc20I(_cToken).comptroller());

        if (asset.decimals() > ERC20(_cToken).decimals()) {
            minAsset = uint96(
                10 ** (asset.decimals() - ERC20(_cToken).decimals())
            );
        }

        _autoConfigureLTVs();

        ERC20(address(asset)).safeApprove(_cToken, type(uint256).max);
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _setLTVs(
        uint64 _targetLTV,
        uint64 _maxBorrowLTV,
        uint64 _maxLTV
    ) internal override {
        (uint256 ltv, uint256 liquidationThreshold) = getProtocolLTVs();
        require(_targetLTV < liquidationThreshold);
        require(_maxLTV < liquidationThreshold);
        require(_targetLTV < _maxLTV);
        require(_maxBorrowLTV < ltv);

        super._setLTVs(_targetLTV, _maxBorrowLTV, _maxLTV);
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _accrueInterest() internal override {
       require(C_TOKEN.accrueInterest() == 0); 
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _deposit(uint256 _amount) internal override {
        if (_amount == 0) return;
        require(C_TOKEN.mint(_amount) == 0);
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _withdraw(uint256 _amount) internal override returns (uint256) {
        if (_amount == 0) return 0;
        require(C_TOKEN.redeemUnderlying(_amount) == 0);
        return _amount;
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _borrow(uint256 _amount) internal override {
        if (_amount == 0) return;
        require(C_TOKEN.borrow(_amount) == 0);
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _repay(uint256 _amount) internal override returns (uint256) {
        if (_amount == 0) return 0;
        require(C_TOKEN.repayBorrow(_amount) == 0);
        return _amount;
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _maxWithdraw() internal override view returns (uint256) {
        return C_TOKEN.getCash();
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _claimRewards() internal virtual override {
        if (dontClaimComp) {
            return;
        }
        CTokenI[] memory tokens = new CTokenI[](1);
        tokens[0] = C_TOKEN;

        COMPTROLLER.claimComp(address(this), tokens);
    }

    /// @inheritdoc BaseLevFarmingStrategy
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
        ) = C_TOKEN.getAccountSnapshot(address(this));
        borrows = borrowBalance;
        deposits = (cTokenBalance * exchangeRate) / 1e18;
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function livePosition()
        public
        override
        returns (uint256 deposits, uint256 borrows)
    {
        deposits = C_TOKEN.balanceOfUnderlying(address(this));
        // can use non state changing now because we updated state with balanceOfUnderlying call
        borrows = C_TOKEN.borrowBalanceStored(address(this));
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function getProtocolLTVs()
        internal
        view
        virtual
        override
        returns (uint256 ltv, uint256 liquidationThreshold)
    {
        (, ltv, ) = COMPTROLLER.markets(address(C_TOKEN));
        liquidationThreshold = ltv;
    }
}

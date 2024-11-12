// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseLevFarmingStrategy, ERC20, SafeERC20, Math} from "./BaseLevFarmingStrategy.sol";
import {ComptrollerI} from "./interfaces/compound/ComptrollerI.sol";
import {CErc20I} from "./interfaces/compound/CErc20I.sol";
import {CTokenI} from "./interfaces/compound/CTokenI.sol";

/// @title Leveraged Compound V2 Strategy
/// @notice A strategy that uses Compound V2 for leveraged lending/borrowing
/// @dev Implements flash loans and leveraged positions using Aave V3 protocol
/// @author Generic Leverage Farming Strategy Team
contract LevCompStrategy is BaseLevFarmingStrategy {
    using SafeERC20 for ERC20;

    // protocol address
    ComptrollerI public immutable COMPTOLLER;
    CErc20I public immutable C_TOKEN;

    bool public dontClaimComp = false;

    /// @notice Initializes the strategy with required addresses and settings
    /// @param _asset The underlying asset token address
    /// @param _name The name of the strategy
    /// @param _cToken The ctoken to use
    constructor(
        address _asset,
        string memory _name,
        address _cToken
    ) BaseLevFarmingStrategy(_asset, _name) {
        require(CErc20I(_cToken).underlying() == _asset); // dev: not asset
        C_TOKEN = CErc20I(_cToken);
        COMPTOLLER = ComptrollerI(CErc20I(_cToken).comptroller());

        _autoConfigureLTVs();

        ERC20(address(_asset)).safeApprove(_cToken, type(uint256).max);
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
        require(C_TOKEN.borrow(_amount) == 0);
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _repay(uint256 _amount) internal override returns (uint256) {
        require(C_TOKEN.repayBorrow(_amount) == 0);
        return _amount;
    }

    /// @notice Automatically configures the LTV ratios based on protocol settings
    /// @dev Sets targetLTV, maxLTV and maxBorrowLTV using protocol values and safety margins
    function _autoConfigureLTVs() internal {
        (uint256 ltv, ) = getProtocolLTVs();
        require(ltv > DEFAULT_COLLAT_TARGET_MARGIN); // dev: !ltv
        targetLTV = uint64(ltv - DEFAULT_COLLAT_TARGET_MARGIN);
        maxBorrowLTV = uint64(ltv - DEFAULT_COLLAT_MAX_MARGIN);
        maxLTV = maxBorrowLTV;
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function _claimRewards() internal virtual override {
        if (dontClaimComp) {
            return;
        }
        CTokenI[] memory tokens = new CTokenI[](1);
        tokens[0] = C_TOKEN;

        COMPTOLLER.claimComp(address(this), tokens);
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
            uint256 C_TOKENBalance,
            uint256 borrowBalance,
            uint256 exchangeRate
        ) = C_TOKEN.getAccountSnapshot(address(this));
        borrows = borrowBalance;
        deposits = (C_TOKENBalance * exchangeRate) / 1e18;
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function livePosition()
        public
        override
        returns (uint256 deposits, uint256 borrows)
    {
        deposits = C_TOKEN.balanceOfUnderlying(address(this));
        //we can use non state changing now because we updated state with balanceOfUnderlying call
        borrows = C_TOKEN.borrowBalanceStored(address(this));
    }

    /// @inheritdoc BaseLevFarmingStrategy
    function getProtocolLTVs()
        internal
        view
        override
        returns (uint256 ltv, uint256 liquidationThreshold)
    {
        (, ltv, ) = COMPTOLLER.markets(address(C_TOKEN));
        liquidationThreshold = ltv;
    }
}

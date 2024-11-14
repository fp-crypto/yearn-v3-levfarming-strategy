// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.19;

import {CTokenI as MToken} from "../../interfaces/compound/CTokenI.sol";

// The commonly structures and events for the MultiRewardDistributor
interface MultiRewardDistributorCommon {
    struct MarketConfig {
        // The owner/admin of the emission config
        address owner;
        // The emission token
        address emissionToken;
        // Scheduled to end at this time
        uint endTime;
        // Supplier global state
        uint224 supplyGlobalIndex;
        uint32 supplyGlobalTimestamp;
        // Borrower global state
        uint224 borrowGlobalIndex;
        uint32 borrowGlobalTimestamp;
        uint supplyEmissionsPerSec;
        uint borrowEmissionsPerSec;
    }

    struct MarketEmissionConfig {
        MarketConfig config;
        mapping(address => uint) supplierIndices;
        mapping(address => uint) supplierRewardsAccrued;
        mapping(address => uint) borrowerIndices;
        mapping(address => uint) borrowerRewardsAccrued;
    }

    struct RewardInfo {
        address emissionToken;
        uint totalAmount;
        uint supplySide;
        uint borrowSide;
    }

    struct IndexUpdate {
        uint224 newIndex;
        uint32 newTimestamp;
    }

    struct MTokenData {
        uint mTokenBalance;
        uint borrowBalanceStored;
    }

    struct RewardWithMToken {
        address mToken;
        RewardInfo[] rewards;
    }

    // Global index updates
    event GlobalSupplyIndexUpdated(
        MToken mToken,
        address emissionToken,
        uint newSupplyIndex,
        uint32 newSupplyGlobalTimestamp
    );
    event GlobalBorrowIndexUpdated(
        MToken mToken,
        address emissionToken,
        uint newIndex,
        uint32 newTimestamp
    );

    // Reward Disbursal
    event DisbursedSupplierRewards(
        MToken indexed mToken,
        address indexed supplier,
        address indexed emissionToken,
        uint totalAccrued
    );
    event DisbursedBorrowerRewards(
        MToken indexed mToken,
        address indexed borrower,
        address indexed emissionToken,
        uint totalAccrued
    );

    // Admin update events
    event NewConfigCreated(
        MToken indexed mToken,
        address indexed owner,
        address indexed emissionToken,
        uint supplySpeed,
        uint borrowSpeed,
        uint endTime
    );
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);
    event NewEmissionCap(uint oldEmissionCap, uint newEmissionCap);
    event NewEmissionConfigOwner(
        MToken indexed mToken,
        address indexed emissionToken,
        address currentOwner,
        address newOwner
    );
    event NewRewardEndTime(
        MToken indexed mToken,
        address indexed emissionToken,
        uint currentEndTime,
        uint newEndTime
    );
    event NewSupplyRewardSpeed(
        MToken indexed mToken,
        address indexed emissionToken,
        uint oldRewardSpeed,
        uint newRewardSpeed
    );
    event NewBorrowRewardSpeed(
        MToken indexed mToken,
        address indexed emissionToken,
        uint oldRewardSpeed,
        uint newRewardSpeed
    );
    event FundsRescued(address token, uint amount);

    // Pause guardian stuff
    event RewardsPaused();
    event RewardsUnpaused();

    // Errors
    event InsufficientTokensToEmit(
        address payable user,
        address rewardToken,
        uint amount
    );
}

interface IMultiRewardDistributor is MultiRewardDistributorCommon {
    // Public views
    function getAllMarketConfigs(
        MToken _mToken
    ) external view returns (MarketConfig[] memory);

    function getConfigForMarket(
        MToken _mToken,
        address _emissionToken
    ) external view returns (MarketConfig memory);

    function getOutstandingRewardsForUser(
        address _user
    ) external view returns (RewardWithMToken[] memory);

    function getOutstandingRewardsForUser(
        MToken _mToken,
        address _user
    ) external view returns (RewardInfo[] memory);

    function getCurrentEmissionCap() external view returns (uint);

    // Administrative functions
    function _addEmissionConfig(
        MToken _mToken,
        address _owner,
        address _emissionToken,
        uint _supplyEmissionPerSec,
        uint _borrowEmissionsPerSec,
        uint _endTime
    ) external;

    function _rescueFunds(address _tokenAddress, uint _amount) external;

    function _setPauseGuardian(address _newPauseGuardian) external;

    function _setEmissionCap(uint _newEmissionCap) external;

    // Comptroller API
    function updateMarketSupplyIndex(MToken _mToken) external;

    function disburseSupplierRewards(
        MToken _mToken,
        address _supplier,
        bool _sendTokens
    ) external;

    function updateMarketSupplyIndexAndDisburseSupplierRewards(
        MToken _mToken,
        address _supplier,
        bool _sendTokens
    ) external;

    function updateMarketBorrowIndex(MToken _mToken) external;

    function disburseBorrowerRewards(
        MToken _mToken,
        address _borrower,
        bool _sendTokens
    ) external;

    function updateMarketBorrowIndexAndDisburseBorrowerRewards(
        MToken _mToken,
        address _borrower,
        bool _sendTokens
    ) external;

    // Pause guardian functions
    function _pauseRewards() external;

    function _unpauseRewards() external;

    // Emission schedule admin functions
    function _updateSupplySpeed(
        MToken _mToken,
        address _emissionToken,
        uint _newSupplySpeed
    ) external;

    function _updateBorrowSpeed(
        MToken _mToken,
        address _emissionToken,
        uint _newBorrowSpeed
    ) external;

    function _updateOwner(
        MToken _mToken,
        address _emissionToken,
        address _newOwner
    ) external;

    function _updateEndTime(
        MToken _mToken,
        address _emissionToken,
        uint _newEndTime
    ) external;
}

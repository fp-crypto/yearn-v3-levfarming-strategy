// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";

interface IStrategyInterface is IBaseHealthCheck {
    function targetLTV() external returns (uint64);

    function maxBorrowLTV() external returns (uint64);

    function maxLTV() external returns (uint64);

    function minAsset() external returns (uint96);

    function minAdjustRatio() external returns (uint64);

    function minRewardSell() external returns (uint96);

    function maxIterations() external returns (uint8);

    function maxTendBasefeeGwei() external returns (uint16);

    function estimatedPosition()
        external
        view
        returns (uint256 deposits, uint256 borrows);

    function livePosition()
        external
        returns (uint256 deposits, uint256 borrows);

    function estimatedLTV() external view returns (uint256 _estimatedLTV);

    function liveLTV() external returns (uint256 _liveLTV);

    function estimatedTotalAssets()
        external
        view
        returns (uint256 _totalAssets);

    function setLTVs(
        uint64 _targetLTV,
        uint64 _maxBorrowLTV,
        uint64 _maxLTV
    ) external;

    function setMaxTendBasefeeGwei(uint16 _maxTendBasefeeGwei) external;

    function setMaxIterations(uint8 _maxIterations) external;

    function setMinAdjustRatio(uint64 _minAdjustRatio) external;

    function setMinAsset(uint96 _minAsset) external;

    function setMinRewardSell(uint96 _minRewardSell) external;
}

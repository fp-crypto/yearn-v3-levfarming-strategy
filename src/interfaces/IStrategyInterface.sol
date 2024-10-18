// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";

interface IStrategyInterface is IBaseHealthCheck {
    function targetCollatRatio() external returns (uint256);

    function maxBorrowCollatRatio() external returns (uint256);

    function maxCollatRatio() external returns (uint256);

    function minAsset() external returns (uint256);

    function minRatio() external returns (uint256);

    function minRewardSell() external returns (uint256);

    function maxIterations() external returns (uint8);

    function initialized() external returns (bool);

    function estimatedPosition()
        external
        view
        returns (uint256 deposits, uint256 borrows);

    function livePosition()
        external
        returns (uint256 deposits, uint256 borrows);

    function estimatedCollatRatio()
        external
        view
        returns (uint256 _estimatedCollatRatio);

    function liveCollatRatio() external returns (uint256 _liveCollatRatio);

    function estimatedTotalAssets()
        external
        view
        returns (uint256 _totalAssets);

    function setCollatRatios(
        uint256 _targetCollatRatio,
        uint256 _maxBorrowCollatRatio,
        uint256 _maxCollatRatio
    ) external;
}

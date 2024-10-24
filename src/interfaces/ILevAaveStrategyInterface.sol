// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategyInterface} from "./IStrategyInterface.sol";

interface ILevAaveStrategyInterface is IStrategyInterface {
    function ADDRESSES_PROVIDER() external returns (address);

    function POOL() external returns (address);

    function flashloanEnabled() external returns (bool);

    function aToken() external returns (address);

    function debtToken() external returns (address);

    function setFlashloanEnabled(bool _flashloanEnabled) external;
}

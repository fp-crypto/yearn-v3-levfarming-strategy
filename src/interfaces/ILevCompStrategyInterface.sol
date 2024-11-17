// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategyInterface} from "./IStrategyInterface.sol";

interface ILevCompStrategyInterface is IStrategyInterface {
    function C_TOKEN() external view returns (address);

    function COMPTROLLER() external view returns (address);
}

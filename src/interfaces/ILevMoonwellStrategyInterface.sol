// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ILevCompStrategyInterface} from "./ILevCompStrategyInterface.sol";

interface ILevMoonwellStrategyInterface is ILevCompStrategyInterface {
    function wethToAssetSwapTickSpacing() external view returns (int24);

    function setWethToAssetSwapTickSpacing(int24) external;
}

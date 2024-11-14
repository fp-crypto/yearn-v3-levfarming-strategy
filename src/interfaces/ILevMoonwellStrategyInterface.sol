// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ILevCompStrategyInterface} from "./ILevCompStrategyInterface.sol";
import {IUniswapV3Swapper} from "@periphery/swappers/interfaces/IUniswapV3Swapper.sol";

interface ILevMoonwellStrategyInterface is
    ILevCompStrategyInterface,
    IUniswapV3Swapper
{}

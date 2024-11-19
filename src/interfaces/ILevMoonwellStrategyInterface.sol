// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ILevCompStrategyInterface} from "./ILevCompStrategyInterface.sol";

interface ILevMoonwellStrategyInterface is ILevCompStrategyInterface {
    function WETH() external returns (address);

    function WELL() external returns (address);

    function AERODROME_ROUTER() external returns (address);

    function SLIPSTREAM_ROUTER() external returns (address);

    function wethToAssetSwapTickSpacing() external view returns (int24);

    function usdcToAssetSwapTickSpacing() external view returns (int24);

    function setWethToAssetSwapTickSpacing(int24) external;

    function setUsdcToAssetSwapTickSpacing(int24) external;

    function sweep(address _token, uint256 _amount) external;
}

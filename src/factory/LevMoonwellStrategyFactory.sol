// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {LevMoonwellStrategy} from "../LevMoonwellStrategy.sol";
import {CErc20I} from "../interfaces/compound/CErc20I.sol";
import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";
import {BaseLevFarmingStrategyFactory} from "./BaseLevFarmingStrategyFactory.sol";

/// @title LevMoonwellStrategyFactory
/// @notice Factory contract for deploying new leveraged Moonwell strategies
/// @dev Creates and initializes new LevMoonwellStrategy instances with proper permissions
contract LevMoonwellStrategyFactory is BaseLevFarmingStrategyFactory {
    mapping(address => address) public deployments;

    /// @notice Creates a new factory instance
    /// @param _keeper The initial keeper address
    constructor(address _keeper) BaseLevFarmingStrategyFactory(_keeper) {}

    /// @notice Deploy a new strategy with a custom Moonwell addresses provider
    /// @dev This will initialize the strategy with proper permissions and settings
    /// @param _cToken The cToken address that matches the asset
    /// @param _name The name for the strategy
    /// @return Address of the newly deployed strategy
    function newStrategy(
        address _cToken,
        string memory _name
    ) public returns (address) {
        address _asset = CErc20I(_cToken).underlying();

        if (deployments[_asset] != address(0))
            revert AlreadyDeployed(deployments[_asset]);

        // We need to use the custom interface with the
        // tokenized strategies available setters.
        IStrategyInterface _newStrategy = IStrategyInterface(
            address(new LevMoonwellStrategy(_asset, _name, _cToken))
        );

        _newStrategy.setKeeper(keeper);
        _newStrategy.setPendingManagement(SMS);

        emit NewStrategy(address(_newStrategy), _asset);

        deployments[_asset] = address(_newStrategy);
        return address(_newStrategy);
    }

    /// @notice Check if a strategy has already been deployed for a given asset
    /// @param _asset The asset address to check
    /// @return bool True if a strategy exists for the asset, false otherwise
    function isDeployedAsset(
        address _asset
    ) external view override returns (bool) {
        return deployments[_asset] != address(0);
    }
}

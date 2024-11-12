// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {LevAaveStrategy} from "../LevAaveStrategy.sol";
import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";
import {BaseLevFarmingStrategyFactory} from "./BaseLevFarmingStrategyFactory.sol";

/// @title LevAaveStrategyFactory
/// @notice Factory contract for deploying new leveraged Aave strategies
/// @dev Creates and initializes new LevAaveStrategy instances with proper permissions
contract LevAaveStrategyFactory is BaseLevFarmingStrategyFactory {
    /// @notice Default Aave addresses provider used when no custom provider is specified
    /// @dev This is the main entry point to the Aave protocol
    address public constant AAVE_ADDRESSES_PROVDIER =
        0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    /// @notice Maps Aave addresses providers and assets to their deployed strategy addresses
    /// @dev First key is the addresses provider, second key is the asset address
    mapping(address => mapping(address => address)) public deployments;

    /// @notice Creates a new factory instance
    /// @param _keeper The initial keeper address
    constructor(address _keeper) BaseLevFarmingStrategyFactory(_keeper) {}

    /// @notice Deploy a new strategy with the default Aave addresses provider
    /// @param _asset The underlying asset address for the strategy
    /// @param _name The name for the strategy
    /// @return Address of the newly deployed strategy
    function newStrategy(
        address _asset,
        string memory _name
    ) external override returns (address) {
        return newStrategy(_asset, _name, AAVE_ADDRESSES_PROVDIER);
    }

    /// @notice Deploy a new strategy with a custom Aave addresses provider
    /// @dev This will initialize the strategy with proper permissions and settings
    /// @param _asset The underlying asset address for the strategy
    /// @param _name The name for the strategy
    /// @param _addressesProvider The custom Aave addresses provider to use
    /// @return Address of the newly deployed strategy
    function newStrategy(
        address _asset,
        string memory _name,
        address _addressesProvider
    ) public returns (address) {
        if (deployments[_addressesProvider][_asset] != address(0))
            revert AlreadyDeployed(deployments[_addressesProvider][_asset]);

        // We need to use the custom interface with the
        // tokenized strategies available setters.
        IStrategyInterface _newStrategy = IStrategyInterface(
            address(new LevAaveStrategy(_asset, _name, _addressesProvider))
        );

        _newStrategy.setKeeper(keeper);
        _newStrategy.setPendingManagement(SMS);

        emit NewStrategy(address(_newStrategy), _asset);

        deployments[_addressesProvider][_asset] = address(_newStrategy);
        return address(_newStrategy);
    }

    /// @notice Check if a strategy has already been deployed for a given asset
    /// @param _asset The asset address to check
    /// @return bool True if a strategy exists for the asset, false otherwise
    function isDeployedAsset(address _asset) external override view returns (bool) {
        return isDeployedAsset(AAVE_ADDRESSES_PROVDIER, _asset);
    }

    /// @notice Check if a strategy has already been deployed for a given asset and addresses provider
    /// @param _addressesProvider The Aave addresses provider to check
    /// @param _asset The asset address to check
    /// @return bool True if a strategy exists for the asset and provider combination, false otherwise
    function isDeployedAsset(
        address _addressesProvider,
        address _asset
    ) public view returns (bool) {
        return deployments[_addressesProvider][_asset] != address(0);
    }
}

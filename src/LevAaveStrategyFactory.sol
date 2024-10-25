// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {LevAaveStrategy} from "./LevAaveStrategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

/// @title LevAaveStrategyFactory
/// @notice Factory contract for deploying new leveraged Aave strategies
/// @dev Creates and initializes new LevAaveStrategy instances with proper permissions
contract LevAaveStrategyFactory {
    /// @notice Revert message for when a strategy has already been deployed.
    error AlreadyDeployed(address _strategy);
    
    /// @notice Thrown when a caller is not the SMS address
    /// @dev Used to restrict access to privileged functions
    error NotSMS();

    event NewStrategy(address indexed strategy, address indexed asset);

    /// @notice Address of SMS that controls strategy management
    /// @dev This address has privileged permissions to update keeper and manage strategies
    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;
    
    /// @notice Default Aave addresses provider used when no custom provider is specified
    /// @dev This is the main entry point to the Aave protocol
    address public constant AAVE_ADDRESSES_PROVDIER =
        0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    /// @notice Address of the strategy keeper that performs maintenance operations
    /// @dev The keeper can be updated by the SMS
    address public keeper;

    /// @notice Maps Aave addresses providers and assets to their deployed strategy addresses
    /// @dev First key is the addresses provider, second key is the asset address
    mapping(address => mapping(address => address)) public deployments;

    /// @notice Creates a new factory instance
    /// @param _keeper The initial keeper address
    constructor(address _keeper) {
        keeper = _keeper;
    }

    /// @notice Deploy a new strategy with the default Aave addresses provider
    /// @param _asset The underlying asset address for the strategy
    /// @param _name The name for the strategy
    /// @return Address of the newly deployed strategy
    function newStrategy(address _asset, string memory _name) external returns (address) {
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

    /// @notice Update the keeper address
    /// @dev Only callable by the SMS
    /// @param _keeper The new keeper address
    function setKeeper(address _keeper) external {
        if (msg.sender != SMS) revert NotSMS();
        keeper = _keeper;
    }

    /// @notice Check if a strategy has already been deployed for a given asset
    /// @param _asset The asset address to check
    /// @return bool True if a strategy exists for the asset, false otherwise
    function isDeployedAsset(address _asset) external view returns (bool) {
        return isDeployedAsset(AAVE_ADDRESSES_PROVDIER, _asset);
    }

    /// @notice Check if a strategy has already been deployed for a given asset and addresses provider
    /// @param _addressesProvider The Aave addresses provider to check
    /// @param _asset The asset address to check
    /// @return bool True if a strategy exists for the asset and provider combination, false otherwise
    function isDeployedAsset(address _addressesProvider, address _asset) public view returns (bool) {
        return deployments[_addressesProvider][_asset] != address(0);
    }
}

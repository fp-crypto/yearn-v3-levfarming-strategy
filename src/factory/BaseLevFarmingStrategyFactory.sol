// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";

/// @title LevAaveStrategyFactory
/// @notice Factory contract for deploying new leveraged Aave strategies
/// @dev Creates and initializes new LevAaveStrategy instances with proper permissions
contract BaseLevFarmingStrategyFactory {
    /// @notice Revert message for when a strategy has already been deployed.
    error AlreadyDeployed(address _strategy);

    /// @notice Thrown when a caller is not the SMS address
    /// @dev Used to restrict access to privileged functions
    error NotSMS();

    event NewStrategy(address indexed strategy, address indexed asset);

    /// @notice Address of SMS that controls strategy management
    /// @dev This address has privileged permissions to update keeper and manage strategies
    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;

    /// @notice Address of the strategy keeper that performs maintenance operations
    /// @dev The keeper can be updated by the SMS
    address public keeper;

    /// @notice Creates a new factory instance
    /// @param _keeper The initial keeper address
    constructor(address _keeper) {
        keeper = _keeper;
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
    /// @return _isDeployed True if a strategy exists for the asset, false otherwise
    function isDeployedAsset(
        address _asset
    ) external view virtual returns (bool _isDeployed) {}
}

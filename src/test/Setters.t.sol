// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20} from "./utils/Setup.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setters(
        uint64 _targetLTV,
        uint64 _maxBorrowLTV,
        uint64 _maxLTV,
        uint16 _maxTendBasefeeGwei,
        uint8 _maxIterations,
        uint64 _minAdjustRatio,
        uint96 _minAsset,
        uint96 _minRewardSell,
        bool _flashloanEnabled
    ) public {
        vm.expectRevert("!management");
        strategy.setLTVs(_targetLTV, _maxBorrowLTV, _maxLTV);
        //vm.startPrank(management);
        //if (_targetLTV > _maxLTV) vm.expectRevert();
        //strategy.setLTVs(
        //    _targetLTV,
        //    _maxBorrowLTV,
        //    _maxLTV
        //);
        //vm.stopPrank();
        //assertEq(_targetLTV, strategy.targetLTV());
        //assertEq(_maxBorrowLTV, strategy.maxBorrowLTV());
        //assertEq(_maxLTV, strategy.maxLTV());

        vm.expectRevert("!management");
        strategy.setMaxTendBasefeeGwei(_maxTendBasefeeGwei);
        vm.prank(management);
        strategy.setMaxTendBasefeeGwei(_maxTendBasefeeGwei);
        assertEq(_maxTendBasefeeGwei, strategy.maxTendBasefeeGwei());

        vm.expectRevert("!management");
        strategy.setMaxIterations(_maxIterations);
        vm.prank(management);
        strategy.setMaxIterations(_maxIterations);
        assertEq(_maxIterations, strategy.maxIterations());

        vm.expectRevert("!management");
        strategy.setMinAdjustRatio(_minAdjustRatio);
        vm.prank(management);
        strategy.setMinAdjustRatio(_minAdjustRatio);
        assertEq(_minAdjustRatio, strategy.minAdjustRatio());

        vm.expectRevert("!management");
        strategy.setMinAsset(_minAsset);
        vm.prank(management);
        strategy.setMinAsset(_minAsset);
        assertEq(_minAsset, strategy.minAsset());

        vm.expectRevert("!management");
        strategy.setMinRewardSell(_minRewardSell);
        vm.prank(management);
        strategy.setMinRewardSell(_minRewardSell);
        assertEq(_minRewardSell, strategy.minRewardSell());

        vm.expectRevert("!management");
        strategy.setFlashloanEnabled(_flashloanEnabled);
        vm.prank(management);
        strategy.setFlashloanEnabled(_flashloanEnabled);
        assertEq(_flashloanEnabled, strategy.flashloanEnabled());
    }
}

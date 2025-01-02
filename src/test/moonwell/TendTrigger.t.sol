// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract TendTriggerTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_tendTrigger(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "no assets"); // trigger should be false there are no assets

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "no time has passed");

        logStrategyInfo();

        uint64 _targetLtv = strategy.targetLTV();
        uint64 _maxLtv = strategy.maxLTV();

        // Set targetLTV so we surpass the minAdjustRatio
        vm.startPrank(management);
        strategy.setLTVs(
            uint64(strategy.liveLTV() - strategy.minAdjustRatio() - 1),
            strategy.maxBorrowLTV(),
            strategy.maxLTV()
        );
        vm.stopPrank();

        logStrategyInfo();

        // False due to fee too high
        vm.fee(uint256(strategy.maxTendBasefeeGwei()) * 1e9 + 1);
        (trigger, ) = strategy.tendTrigger();

        // True due to fee below max
        vm.fee(uint256(strategy.maxTendBasefeeGwei()) * 1e9 - 1);
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "fee okay");

        // Set maxLTV to below current
        vm.startPrank(management);
        strategy.setLTVs(
            uint64(strategy.liveLTV() - strategy.minAdjustRatio() - 1),
            strategy.maxBorrowLTV(),
            uint64(strategy.liveLTV() - 1)
        );
        vm.stopPrank();

        logStrategyInfo();

        // True because LTV is above emergency threshold
        vm.fee(uint256(strategy.maxTendBasefeeGwei()) * 1e9 + 1);
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "maxLTV");

        vm.prank(keeper);
        strategy.tend();
        checkLTV(false);
        logStrategyInfo();

        vm.fee(uint256(strategy.maxTendBasefeeGwei()) * 1e9 - 1);
        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "just tended");

        vm.startPrank(management);
        strategy.setLTVs(_targetLtv / 2, strategy.maxBorrowLTV(), _maxLtv);
        vm.stopPrank();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(keeper);
        strategy.tend();
        checkLTV(false);
        logStrategyInfo();

        vm.startPrank(management);
        strategy.setLTVs(
            _targetLtv,
            strategy.maxBorrowLTV(),
            strategy.maxLTV()
        );
        vm.stopPrank();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(management);
        strategy.shutdownStrategy();

        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger);

        vm.startPrank(management);
        strategy.setLTVs(0, strategy.maxBorrowLTV(), strategy.maxLTV());
        vm.stopPrank();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(keeper);
        strategy.tend();
        checkLTV(false);
        logStrategyInfo();

        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger);
    }
}

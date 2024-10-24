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
        // Skip some time until we surpass the minAdjustRatio
        for (
            ;
            strategy.estimatedLTV() < strategy.targetLTV() ||
                strategy.estimatedLTV() - strategy.targetLTV() <
                strategy.minAdjustRatio();

        ) {
            skip(1 days);
        }

        logStrategyInfo();

        // False due to fee too high
        vm.fee(uint256(strategy.maxTendBasefeeGwei()) * 1e9 + 1);
        (trigger, ) = strategy.tendTrigger();

        // True due to fee below max
        vm.fee(uint256(strategy.maxTendBasefeeGwei()) * 1e9 - 1);
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "fee okay");

        // Skip some time until we surpass the warning threshold
        for (
            ;
            strategy.estimatedLTV() < strategy.targetLTV() ||
                strategy.estimatedLTV() - strategy.targetLTV() < 0.01e18;

        ) {
            skip(7 days);
        }

        logStrategyInfo();

        // True because LTV is above emergency threshold
        vm.fee(uint256(strategy.maxTendBasefeeGwei()) * 1e9 + 1);
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(keeper);
        strategy.tend();
        checkLTV(false);
        logStrategyInfo();

        vm.fee(uint256(strategy.maxTendBasefeeGwei()) * 1e9 - 1);
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

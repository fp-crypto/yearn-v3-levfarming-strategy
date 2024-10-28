// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ManualFunctionsTest is Setup {
    /// @notice Set up the test environment with zero fees
    function setUp() public virtual override {
        super.setUp();
    }

    function test_manualGuards(uint256 _amount) public {
        vm.expectRevert("!emergency authorized");
        strategy.manualDeleverage(0);

        vm.expectRevert("!emergency authorized");
        strategy.manualReleaseWant(0);

        vm.expectRevert("!emergency authorized");
        strategy.manualClaimAndSellRewards();
    }

    /// @notice Test manual deleverage operations
    /// @param _amount The amount to deposit
    function test_manualDeleverage(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertApproxEq(
            strategy.estimatedTotalAssets(),
            _amount,
            strategy.minAsset(),
            "!eta"
        );
        checkStrategyTotals(strategy, _amount, _amount, 0);
        checkLTV(false);
        logStrategyInfo();

        // Lose money
        skip(1 days);

        (uint256 supply, uint256 borrow) = strategy.livePosition();

        for (
            ;
            borrow >= strategy.minAsset();
            (supply, borrow) = strategy.livePosition()
        ) {
            console.log("supply: %d", supply);
            console.log("borrow: %d", borrow);
            uint256 theoMinSupply = (borrow * 1e18) /
                (strategy.maxBorrowLTV() - 0.005e18);
            console.log("theoMinSupply: %d", theoMinSupply);
            uint256 stepSize = supply > theoMinSupply
                ? supply - theoMinSupply
                : borrow;
            console.log("stepSize: %d", stepSize);
            vm.prank(management);
            strategy.manualDeleverage(stepSize);
            logStrategyInfo();
        }

        assertLe(borrow, strategy.minAsset());
        assertRelApproxEq(strategy.liveLTV(), 0, 1);
        checkLTV(true, false, 0);

        vm.prank(management);
        strategy.manualReleaseWant(supply);
        logStrategyInfo();
        (supply, borrow) = strategy.livePosition();
        assertEq(supply, 0);
    }

    function test_manualClaimAndSell(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertApproxEq(
            strategy.estimatedTotalAssets(),
            _amount,
            strategy.minAsset(),
            "!eta"
        );
        checkStrategyTotals(strategy, _amount, _amount, 0);
        checkLTV(false);
        logStrategyInfo();

        skip(1 days);

        uint256 etaBefore = strategy.estimatedTotalAssets();

        vm.prank(management);
        strategy.manualClaimAndSellRewards();

        assertGt(strategy.estimatedTotalAssets(), etaBefore);
    }
}

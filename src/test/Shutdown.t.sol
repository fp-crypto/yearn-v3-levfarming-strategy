pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ShutdownTest is Setup {
    uint256 public constant REPORTING_PERIOD = 7 days;

    function setUp() public virtual override {
        super.setUp();
        setFees(0, 0); // set fees to 0 to make life easy
    }

    function test_shutdownCanWithdraw(uint256 _amount, bool profit) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Deploy funds
        vm.prank(keeper);
        strategy.tend();

        if (profit) {
            // Make money
            skip(REPORTING_PERIOD);
            vm.prank(keeper);
            (uint256 profit, uint256 loss) = strategy.report();
            // Expect a profit
            assertGe(profit, 0, "!profit");
            assertEq(loss, 0, "!loss");
        }

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        assertGe(strategy.totalAssets(), _amount, "!totalAssets");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);
        uint256 eta = strategy.estimatedTotalAssets();

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertRelApproxEq(
            asset.balanceOf(user),
            balanceBefore + eta,
            1,
            "!final balance"
        );
    }

    function test_shutdownEmergencyWithdraw_amount(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Deploy funds
        vm.prank(keeper);
        strategy.tend();

        skip(1 days);

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        vm.prank(management);
        strategy.emergencyWithdraw(_amount);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);
        uint256 eta = strategy.estimatedTotalAssets();

        assertEq(eta, totalIdle(strategy), "!idle");

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertRelApproxEq(
            asset.balanceOf(user),
            balanceBefore + eta,
            1,
            "!final balance"
        );
    }

    function test_shutdownEmergencyWithdraw_fuzz(
        uint256 _depositAmount,
        uint256 _withdrawAmount
    ) public {
        _depositAmount = bound(_depositAmount, minFuzzAmount, maxFuzzAmount);
        _withdrawAmount = bound(_withdrawAmount, 0.01e18, type(uint256).max);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _depositAmount);
        assertEq(strategy.totalAssets(), _depositAmount, "!totalAssets");

        // Deploy funds
        vm.prank(keeper);
        strategy.tend();

        skip(1 days);

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _depositAmount, "!totalAssets");

        vm.prank(management);
        strategy.emergencyWithdraw(_withdrawAmount);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);
        uint256 eta = strategy.estimatedTotalAssets();

        assertApproxEq(
            totalIdle(strategy),
            Math.min(eta, _withdrawAmount),
            (Math.min(_withdrawAmount, strategy.totalAssets()) * 500) / 10_000, // allow slippage
            "!idle"
        );

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_depositAmount, user, user);

        if (balanceBefore + eta > asset.balanceOf(user)) {
            assertApproxEq(
                asset.balanceOf(user),
                balanceBefore + eta,
                (_depositAmount * 667) / 10_000,
                "!final balance"
            );
        }
    }
}

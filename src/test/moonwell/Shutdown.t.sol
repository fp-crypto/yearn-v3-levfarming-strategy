pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ShutdownTest is Setup {
    function setUp() public virtual override {
        super.setUp();
        setFees(0, 0); // set fees to 0 to make life easy
    }

    function test_shutdownCanWithdraw(uint256 _amount, bool _profit) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Deploy funds
        vm.prank(keeper);
        strategy.tend();

        if (_profit) {
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
        (uint256 _deposits, uint256 _borrows) = strategy.livePosition();
        uint256 etaWithOutRewards = _deposits + totalIdle(strategy) - _borrows;

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertRelApproxEq(
            asset.balanceOf(user),
            balanceBefore + etaWithOutRewards,
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

        logStrategyInfo();
        vm.startPrank(management);
        strategy.emergencyWithdraw(_amount);
        vm.stopPrank();
        logStrategyInfo();

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);
        (uint256 _deposits, uint256 _borrows) = strategy.livePosition();
        uint256 etaWithOutRewards = _deposits + totalIdle(strategy) - _borrows;

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertRelApproxEq(
            asset.balanceOf(user),
            balanceBefore + etaWithOutRewards,
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
        (uint256 _deposits, uint256 _borrows) = strategy.livePosition();
        uint256 etaWithOutRewards = _deposits + totalIdle(strategy) - _borrows;

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_depositAmount, user, user);

        if (balanceBefore + etaWithOutRewards > asset.balanceOf(user)) {
            assertApproxEq(
                asset.balanceOf(user),
                balanceBefore + etaWithOutRewards,
                (_depositAmount * 667) / 10_000,
                "!final balance"
            );
        }
    }
}

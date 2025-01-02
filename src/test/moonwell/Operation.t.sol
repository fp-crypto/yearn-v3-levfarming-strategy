// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CTokenI, CErc20I} from "../../interfaces/compound/CErc20I.sol";
import {ComptrollerI as MoonwellComptrollerI} from "../../interfaces/moonwell/ComptrollerI.sol";

contract OperationTest is Setup {
    /// @notice Set up the test environment with zero fees
    function setUp() public virtual override {
        super.setUp();
        setFees(0, 0);

        // Verify initial state
        assertEq(strategy.totalAssets(), 0, "Initial total assets should be 0");
        assertEq(strategy.totalSupply(), 0, "Initial total supply should be 0");
    }

    /// @notice Test initial strategy setup and configuration
    function test_setupStrategyOK() public {
        console.log("address of strategy", address(strategy));
        assertTrue(
            address(0) != address(strategy),
            "Strategy address should not be zero"
        );
        assertEq(strategy.asset(), address(asset), "Wrong asset address");
        assertEq(strategy.management(), management, "Wrong management address");
        assertEq(
            strategy.performanceFeeRecipient(),
            performanceFeeRecipient,
            "Wrong fee recipient"
        );
        assertEq(strategy.keeper(), keeper, "Wrong keeper address");
    }

    /// @notice Test basic deposit and withdrawal flow
    /// @param _amount The amount to deposit
    function test_operation(uint256 _amount) public {
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

        logStrategyInfo();
        checkLTV(false);

        logStrategyInfo();

        skip(strategy.profitMaxUnlockTime());

        logStrategyInfo();

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // Expect a loss since no profit was created
        assertGt(asset.balanceOf(user), 0, "!final balance");
        assertLe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        logStrategyInfo();
    }

    /// @notice Test strategy reporting with profits
    /// @param _amount The amount to deposit
    function test_profitableReport(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        logStrategyInfo();
        checkStrategyTotals(strategy, _amount, _amount, 0);
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, 1, "!eta");
        checkLTV(false);

        // Make money
        skip(REPORTING_PERIOD);

        logStrategyInfo();

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();
        checkLTV(false);
        logStrategyInfo();

        // Expect a profit
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        logStrategyInfo();

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        logStrategyInfo();
        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        logStrategyInfo();
    }

    function test_withdrawSubset(
        uint256 _depositAmount,
        uint256 _withdrawAmount,
        bool _profit
    ) public {
        _depositAmount = bound(_depositAmount, minFuzzAmount, maxFuzzAmount);
        _withdrawAmount = bound(
            _withdrawAmount,
            minFuzzAmount / 2,
            _depositAmount - (minFuzzAmount / 2)
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _depositAmount);
        logStrategyInfo();

        // tend to deploy funds
        vm.prank(keeper);
        strategy.tend();
        checkLTV(false);
        logStrategyInfo();

        checkStrategyTotals(strategy, _depositAmount, _depositAmount, 0);

        if (_profit) {
            // Make money
            skip(REPORTING_PERIOD);
            vm.prank(keeper);
            (uint256 profit, uint256 loss) = strategy.report();
            // Expect a profit
            assertGe(profit, 0, "!profit");
            assertEq(loss, 0, "!loss");
        }

        uint256 balanceBefore = asset.balanceOf(user);
        uint256 totalAssetsBefore = Math.min(
            strategy.estimatedTotalAssets(),
            strategy.totalAssets()
        );
        logStrategyInfo();

        // Withdraw some funds
        console.log("Redeeming: %e", _withdrawAmount);
        vm.prank(user);
        strategy.redeem(_withdrawAmount, user, user);
        checkLTV(true, true);
        logStrategyInfo();

        assertLe(
            asset.balanceOf(user),
            balanceBefore + _withdrawAmount,
            "!final balance"
        );

        uint256 targetRatio = (uint256(_withdrawAmount) * 1e4) / _depositAmount;
        uint256 actualRatio = ((asset.balanceOf(user) - balanceBefore) * 1e4) /
            totalAssetsBefore;

        if (_profit) {
            assertLe(actualRatio, targetRatio, "!ratio");
        } else {
            assertApproxEq(
                actualRatio,
                targetRatio,
                100, // bp
                "!ratio"
            );
        }

        balanceBefore = asset.balanceOf(user);
        uint256 redeemAmount = strategy.balanceOf(user);
        console.log("redeemAmount: %s", redeemAmount);
        vm.prank(user);
        strategy.redeem(redeemAmount, user, user);

        if (_profit) {
            assertRelApproxEq(
                asset.balanceOf(user),
                balanceBefore + (_depositAmount - _withdrawAmount),
                1
            );
        }
    }

    function test_depositWhenPositionIsOpen(
        uint256 _initialAmount,
        uint256 _subsequentAmount
    ) public {
        _initialAmount = bound(
            _initialAmount,
            minFuzzAmount,
            maxFuzzAmount - strategy.minAsset()
        );
        _subsequentAmount = bound(
            _subsequentAmount,
            strategy.minAsset(),
            maxFuzzAmount - _initialAmount
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _initialAmount);

        // default check
        uint256 strategyTotalAssetsBefore = strategy.estimatedTotalAssets();
        assertRelApproxEq(strategyTotalAssetsBefore, _initialAmount, 1, "!eta");

        logStrategyInfo();

        // put funds into position
        vm.prank(keeper);
        strategy.tend();

        strategyTotalAssetsBefore = strategy.estimatedTotalAssets();

        logStrategyInfo();

        // do an another deposit when position is open, since the "priceIndex" is "0"
        uint256 balanceBefore = asset.balanceOf(user);
        deal(address(asset), user, balanceBefore + _subsequentAmount);

        vm.startPrank(user);
        asset.approve(address(strategy), _subsequentAmount);
        strategy.deposit(_subsequentAmount, user);
        vm.stopPrank();
        assertRelApproxEq(
            strategy.estimatedTotalAssets(),
            strategyTotalAssetsBefore + _subsequentAmount,
            1,
            "!eta"
        );
    }

    function test_ltvChanges(
        uint256 _amount,
        uint64 _startingLtv,
        uint64 _endingLtv
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        if (_startingLtv != 0) {
            _startingLtv = uint64(
                bound(
                    _startingLtv,
                    strategy.minAdjustRatio(),
                    strategy.targetLTV()
                )
            );
        }
        if (_endingLtv != 0) {
            _endingLtv = uint64(
                bound(
                    _endingLtv,
                    strategy.minAdjustRatio(),
                    strategy.targetLTV()
                )
            );
        }

        vm.startPrank(management);
        strategy.setLTVs(
            _startingLtv,
            strategy.maxBorrowLTV(),
            strategy.maxLTV()
        );
        vm.stopPrank();

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount, _amount, 0, false);
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, 1, "!eta");

        vm.prank(keeper);
        strategy.tend();
        logStrategyInfo();
        checkLTV(_startingLtv == 0);
        checkStrategyTotals(strategy, _amount, _amount, 0, true);

        // Lose money
        skip(1 days);

        vm.startPrank(management);
        strategy.setLTVs(
            _endingLtv,
            strategy.maxBorrowLTV(),
            strategy.maxLTV()
        );
        vm.stopPrank();

        // Tend to new LTV
        vm.prank(keeper);
        strategy.tend();
        logStrategyInfo();
        checkLTV(_endingLtv == 0);
        checkStrategyTotals(strategy, _amount, _amount, 0, true);
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, 1, "!eta");
    }

    /// @notice Test basic deposit and withdrawal flow
    /// @param _amount The amount to deposit
    function test_opsLtvZero(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        vm.startPrank(management);
        strategy.setLTVs(0, strategy.maxBorrowLTV(), strategy.maxLTV());
        vm.stopPrank();

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertApproxEq(
            strategy.estimatedTotalAssets(),
            _amount,
            strategy.minAsset(),
            "!eta"
        );
        checkStrategyTotals(strategy, _amount, _amount, 0);
        checkLTV(true);
        logStrategyInfo();

        skip(1 days);

        logStrategyInfo();
        checkLTV(true);

        logStrategyInfo();

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // Expect to get same amount out
        assertGt(asset.balanceOf(user), 0, "!final balance");
        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        logStrategyInfo();
    }

    /// @notice Test basic deposit and withdrawal flow
    /// @param _amount The amount to deposit
    function test_opsLtvRaised(uint256 _amount, uint256 _part) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _part = bound(_part, 2, 10);

        vm.startPrank(management);
        strategy.setLTVs(0.05e18, strategy.maxBorrowLTV(), strategy.maxLTV());
        vm.stopPrank();

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertApproxEq(
            strategy.estimatedTotalAssets(),
            _amount,
            strategy.minAsset(),
            "!eta"
        );
        checkStrategyTotals(strategy, _amount, _amount, 0);
        checkLTV(true);
        logStrategyInfo();

        skip(1 days);

        logStrategyInfo();
        checkLTV(true);

        vm.startPrank(management);
        strategy.setLTVs(0.25e18, strategy.maxBorrowLTV(), strategy.maxLTV());
        vm.stopPrank();

        logStrategyInfo();

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.startPrank(user);
        strategy.redeem(_amount / _part, user, user);
        logStrategyInfo();
        strategy.redeem(strategy.balanceOf(user), user, user);
        vm.stopPrank();

        // Expect to get same amount out
        assertGt(asset.balanceOf(user), 0, "!final balance");
        assertRelApproxEq(
            asset.balanceOf(user),
            balanceBefore + _amount,
            1,
            "!final balance"
        );

        logStrategyInfo();
    }

    /// @notice Test basic deposit and withdrawal flow
    /// @param _amount The amount to deposit
    function test_maxSupply(
        uint256 _amount,
        uint16 _initialDepositPartBps
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _initialDepositPartBps = uint16(bound(_initialDepositPartBps, 1, 9999));

        uint256 _initialAmount = (_amount * _initialDepositPartBps) / 10_000;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _initialAmount);

        assertApproxEq(
            strategy.estimatedTotalAssets(),
            _initialAmount,
            strategy.minAsset(),
            "!eta"
        );
        checkStrategyTotals(strategy, _initialAmount, _initialAmount, 0);
        checkLTV(false);
        logStrategyInfo();

        uint256 _remainingAmount = _amount - _initialAmount;

        CTokenI _cToken = CTokenI(strategy.C_TOKEN());

        uint256 _totalSupplied = _cToken.getCash() +
            _cToken.totalBorrows() -
            _cToken.totalReserves() +
            ((_remainingAmount * 1e18) / (1e18 - strategy.targetLTV()));

        vm.mockCall(
            address(strategy.COMPTROLLER()),
            abi.encodeWithSelector(
                MoonwellComptrollerI(strategy.COMPTROLLER())
                    .supplyCaps
                    .selector,
                address(cToken)
            ),
            abi.encode(_totalSupplied)
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _remainingAmount);

        assertApproxEq(
            strategy.estimatedTotalAssets(),
            _amount,
            strategy.minAsset(),
            "!eta"
        );
        checkStrategyTotals(strategy, _amount, _amount, 0);
        checkLTV(false);
        logStrategyInfo();

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // Expect a loss since no profit was created
        assertGt(asset.balanceOf(user), 0, "!final balance");
        assertLe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        logStrategyInfo();
    }

    function test_maxSupply_tapir() external {
        // first deposit some tokens to strategy to lever to targetlTV
        uint256 deposit = 100e18;
        mintAndDepositIntoStrategy(strategy, user, deposit);

        // log'em
        logStrategyInfo();

        // figure out whats the remaining supply
        address comptrollerAddr = address(strategy.COMPTROLLER());
        address cTokenAddr = address(strategy.C_TOKEN());
        uint256 _supplyCap = MoonwellComptrollerI(comptrollerAddr).supplyCaps(
            cTokenAddr
        );
        uint256 _totalSupplied = CTokenI(cTokenAddr).getCash() +
            CTokenI(cTokenAddr).totalBorrows() -
            CTokenI(cTokenAddr).totalReserves();
        uint256 _remainingSupply = _supplyCap - _totalSupplied;
        console.log("Remaining supply: %s", _remainingSupply);

        // enrich the tapir
        address _tapir = address(69);
        deal(address(asset), _tapir, type(uint256).max);

        // let tapir mint some tokens
        vm.startPrank(_tapir);
        asset.approve(cTokenAddr, type(uint256).max);
        CErc20I(cTokenAddr).mint(_remainingSupply - 10e18);

        // check whats left to supply
        _supplyCap = MoonwellComptrollerI(comptrollerAddr).supplyCaps(
            cTokenAddr
        );
        _totalSupplied =
            CTokenI(cTokenAddr).getCash() +
            CTokenI(cTokenAddr).totalBorrows() -
            CTokenI(cTokenAddr).totalReserves();
        _remainingSupply = _supplyCap - _totalSupplied;
        console.log("Remaining supply after mint: %s", _remainingSupply);
        vm.stopPrank();

        // deposit some more tokens, almost fulfill the supply cap, this will revert although
        // user deposits lesser than the max deposit. Because of leverage attempt.
        deal(address(asset), user, _remainingSupply - 1000);
        vm.startPrank(user);

        asset.approve(address(strategy), _remainingSupply - 1000);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(_remainingSupply - 1000, user);

        uint256 finalDepositToMake = Math.min(
            asset.balanceOf(user),
            strategy.maxDeposit(user)
        );
        if (finalDepositToMake >= strategy.minAsset()) {
            asset.approve(address(strategy), finalDepositToMake);
            strategy.deposit(finalDepositToMake, user);
        }
        vm.stopPrank();

        checkLTV(false);
    }
}

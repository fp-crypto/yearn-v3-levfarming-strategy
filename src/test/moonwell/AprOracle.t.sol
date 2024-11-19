// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20} from "./utils/Setup.sol";
import {LevMoonwellStrategyAprOracle} from "../../periphery/LevMoonwellStrategyAprOracle.sol";

contract AprOracleTest is Setup {
    LevMoonwellStrategyAprOracle aprOracle;

    /// @notice Set up the test environment with zero fees
    function setUp() public virtual override {
        super.setUp();
        aprOracle = new LevMoonwellStrategyAprOracle();
    }

    function test_aprOracle(uint256 _amount, uint256 _delta) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _delta = bound(_amount, minFuzzAmount / 2, _amount / 2);

        uint256 apr = aprOracle.aprAfterDebtChange(address(strategy), 0);
        assertEq(apr, 0);
        console.log("APR with no deposit: %e", apr);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        apr = aprOracle.aprAfterDebtChange(address(strategy), 0);
        assertGe(apr, 0);
        console.log("APR with no delta: %e", apr);

        uint256 aprPosDelta = aprOracle.aprAfterDebtChange(
            address(strategy),
            int256(_delta)
        );
        console.log("APR with positive delta: %e", aprPosDelta);
        assertLe(aprPosDelta, apr);

        uint256 aprNegDelta = aprOracle.aprAfterDebtChange(
            address(strategy),
            -int256(_delta)
        );
        console.log("APR with negative delta: %e", aprNegDelta);
        assertGe(aprNegDelta, apr);
    }
}

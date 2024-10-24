// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {ExtendedTest} from "./ExtendedTest.sol";

import {LevAaveStrategy as Strategy, ERC20} from "../../LevAaveStrategy.sol";
import {LevAaveStrategyFactory as StrategyFactory} from "../../LevAaveStrategyFactory.sol";
import {ILevAaveStrategyInterface} from "../../interfaces/ILevAaveStrategyInterface.sol";

import {IACLManager} from "../../interfaces/aave/v3/core/IACLManager.sol";
import {IPoolConfigurator} from "../../interfaces/aave/v3/core/IPoolConfigurator.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is ExtendedTest, IEvents {
    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    ILevAaveStrategyInterface public strategy;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management =
        address(0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7);
    address public performanceFeeRecipient = address(3);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    uint256 public maxFuzzAmount = 100_000e18;
    uint256 public minFuzzAmount = 1000e18;

    uint256 public profitMaxUnlockTime = 1 hours;

    uint256 public constant REPORTING_PERIOD = 7 days;

    function setUp() public virtual {
        _setTokenAddrs();

        // Set asset
        asset = ERC20(tokenAddrs["USDS"]);

        vm.prank(0x5300A1a15135EA4dc7aD5a167152C01EFc9b192A);
        IPoolConfigurator(0x64b761D848206f447Fe2dd461b0c635Ec39EbB27)
            .setSupplyCap(address(asset), 0);

        // Set decimals
        decimals = asset.decimals();

        // Deploy strategy and set variables
        strategy = ILevAaveStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(strategy.A_TOKEN(), "aToken");
        vm.label(strategy.DEBT_TOKEN(), "debtToken");
        vm.label(tokenAddrs["WETH"], "WETH");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {
        StrategyFactory _strategyFactory = new StrategyFactory(keeper);

        // we save the strategy as a ILevAaveStrategyInterface to give it the needed interface
        ILevAaveStrategyInterface _strategy = ILevAaveStrategyInterface(
            address(
                _strategyFactory.newStrategy(
                    address(asset),
                    "Tokenized Strategy"
                )
            )
        );

        vm.startPrank(management);
        _strategy.acceptManagement();
        // set keeper
        _strategy.setKeeper(keeper);
        // set treasury
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        // set management of the strategy
        _strategy.setPendingManagement(management);
        // set deposit limit
        // _strategy.setDepositLimit(2 ** 256 - 1);
        _strategy.setProfitMaxUnlockTime(profitMaxUnlockTime);
        vm.stopPrank();

        return address(_strategy);
    }

    function depositIntoStrategy(
        ILevAaveStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        ILevAaveStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    function totalIdle(
        ILevAaveStrategyInterface _strategy
    ) public view returns (uint256) {
        return ERC20(_strategy.asset()).balanceOf(address(_strategy));
    }

    function totalDebt(
        ILevAaveStrategyInterface _strategy
    ) public view returns (uint256) {
        uint256 _totalIdle = totalIdle(_strategy);
        uint256 _totalAssets = _strategy.totalAssets();
        if (_totalIdle >= _totalAssets) return 0;
        return _totalAssets - _totalIdle;
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        ILevAaveStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        assertEq(_strategy.totalAssets(), _totalAssets, "!totalAssets");
        assertEq(totalDebt(_strategy), _totalDebt, "!totalDebt");
        assertEq(totalIdle(_strategy), _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function checkLTV() public {
        checkLTV(true);
    }

    function checkLTV(uint64 targetLTV) public {
        checkLTV(true, false, targetLTV);
    }

    function checkLTV(bool canBeZero) public {
        checkLTV(canBeZero, false);
    }

    function checkLTV(bool canBeZero, bool onlyCheckTooHigh) public {
        checkLTV(canBeZero, onlyCheckTooHigh, strategy.targetLTV());
    }

    function checkLTV(
        bool canBeZero,
        bool onlyCheckTooHigh,
        uint64 targetLTV
    ) public {
        if (canBeZero && strategy.liveLTV() == 0) return;
        if (onlyCheckTooHigh) {
            assertLe(
                strategy.liveLTV(),
                targetLTV + strategy.minAdjustRatio(),
                "!LTV too high"
            );
        } else {
            assertApproxEq(
                strategy.liveLTV(),
                targetLTV,
                strategy.minAdjustRatio(),
                "!LTV not target"
            );
        }
    }

    function logStrategyInfo() internal {
        (uint256 _deposits, uint256 _borrows) = strategy.livePosition();
        console.log("\n");
        console.log("==== Strategy Info ====");
        console.log("Debt: %e", _deposits);
        console.log("Collateral: %e", _borrows);
        console.log(
            "LTV (actual/target): %e/%e",
            strategy.liveLTV(),
            strategy.targetLTV()
        );
        console.log("ETA: %e", strategy.estimatedTotalAssets());
        console.log("Total Assets: %e", strategy.totalAssets());
        console.log("Total Debt: %e", totalDebt(strategy));
        console.log("Total Idle: %e", totalIdle(strategy));
        console.log("\n");
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["USDS"] = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    }
}

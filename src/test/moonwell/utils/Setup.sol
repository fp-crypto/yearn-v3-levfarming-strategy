// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {ExtendedTest} from "./ExtendedTest.sol";

import {LevMoonwellStrategy as Strategy, ERC20} from "../../../LevMoonwellStrategy.sol";
import {LevMoonwellStrategyFactory as StrategyFactory} from "../../../factories/LevMoonwellStrategyFactory.sol";
import {ILevMoonwellStrategyInterface} from "../../../interfaces/ILevMoonwellStrategyInterface.sol";

import {IACLManager} from "../../../interfaces/aave/v3/core/IACLManager.sol";
import {IPoolConfigurator} from "../../../interfaces/aave/v3/core/IPoolConfigurator.sol";

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
    ERC20 public cToken;
    ILevMoonwellStrategyInterface public strategy;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management =
        address(0x01fE3347316b2223961B20689C65eaeA71348e93);
    address public performanceFeeRecipient = address(3);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    uint256 public maxFuzzAmount = 100e18;
    uint256 public minFuzzAmount = 1e18;

    uint256 public profitMaxUnlockTime = 1 hours;

    uint256 public constant REPORTING_PERIOD = 7 days;

    function setUp() public virtual {
        _setTokenAddrs();

        // Set asset
        asset = ERC20(tokenAddrs["WETH"]);
        cToken = ERC20(tokenAddrs["mWETH"]);

        // Set decimals
        decimals = asset.decimals();

        // Deploy strategy and set variables
        strategy = ILevMoonwellStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(strategy.C_TOKEN(), "acoken");
        vm.label(tokenAddrs["WETH"], "WETH");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {
        StrategyFactory _strategyFactory = new StrategyFactory(keeper);

        // we save the strategy as a ILevMoonwellStrategyInterface to give it the needed interface
        ILevMoonwellStrategyInterface _strategy = ILevMoonwellStrategyInterface(
            address(
                _strategyFactory.newStrategy(
                    address(cToken),
                    "Tokenized Strategy",
                    1, // wethToAssetSwapTickSpacing
                    0 // usdcToAssetSwapTickSpacing
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

        _strategy.setMinAsset(1e12);

        vm.stopPrank();

        return address(_strategy);
    }

    function depositIntoStrategy(
        ILevMoonwellStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        ILevMoonwellStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    function totalIdle(
        ILevMoonwellStrategyInterface _strategy
    ) public view returns (uint256) {
        return ERC20(_strategy.asset()).balanceOf(address(_strategy));
    }

    function totalDebt(
        ILevMoonwellStrategyInterface _strategy
    ) public view returns (uint256) {
        uint256 _totalIdle = totalIdle(_strategy);
        uint256 _totalAssets = _strategy.totalAssets();
        if (_totalIdle >= _totalAssets) return 0;
        return _totalAssets - _totalIdle;
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        ILevMoonwellStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        checkStrategyTotals(_strategy, _totalAssets, _totalDebt, _totalIdle, false);
    }

    function checkStrategyTotals(
        ILevMoonwellStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle,
        bool _approx
    ) public {
        if (_approx) {
            assertApproxEq(
                _strategy.totalAssets(),
                _totalAssets,
                _strategy.minAsset(),
                "!totalAssets"
            );
            assertApproxEq(
                totalDebt(_strategy),
                _totalDebt,
                _strategy.minAsset(),
                "!totalDebt"
            );
            assertApproxEq(
                totalIdle(_strategy),
                _totalIdle,
                _strategy.minAsset(),
                "!totalIdle"
            );
            assertApproxEq(
                _totalAssets,
                _totalDebt + _totalIdle,
                _strategy.minAsset(),
                "!Added"
            );
        } else {
            assertEq(_strategy.totalAssets(), _totalAssets, "!totalAssets");
            assertEq(totalDebt(_strategy), _totalDebt, "!totalDebt");
            assertEq(totalIdle(_strategy), _totalIdle, "!totalIdle");
            assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
        }
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
        console.log("Deposits: %e", _deposits);
        console.log("Borrows: %e", _borrows);
        console.log("Supply: %e", _deposits - _borrows);
        console.log(
            "LTV (actual/target): %e/%e",
            strategy.liveLTV(),
            strategy.targetLTV()
        );
        console.log("ETA: %e", strategy.estimatedTotalAssets());
        console.log("ETR: %e", strategy.estimatedRewardsInAsset());
        console.log("Total Assets: %e", strategy.totalAssets());
        console.log("Total Debt: %e", totalDebt(strategy));
        console.log("Total Idle: %e", totalIdle(strategy));
        console.log("\n");
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WETH"] = 0x4200000000000000000000000000000000000006;
        tokenAddrs["mWETH"] = 0x628ff693426583D9a7FB391E54366292F509D457;
        tokenAddrs["cbBTC"] = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
        tokenAddrs["mcbBTC"] = 0xF877ACaFA28c19b96727966690b2f44d35aD5976;
        tokenAddrs["cbETH"] = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
        tokenAddrs["mcbETH"] = 0x3bf93770f2d4a794c3d9EBEfBAeBAE2a8f09A5E5;
        tokenAddrs["USDC"] = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        tokenAddrs["mUSDC"] = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    }
}

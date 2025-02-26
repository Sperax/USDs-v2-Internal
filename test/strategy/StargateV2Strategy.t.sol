// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {BaseStrategy} from "./BaseStrategy.t.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {UpgradeUtil} from "../utils/UpgradeUtil.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StargateStrategyV2} from "../../contracts/strategies/stargateV2/StargateStrategyV2.sol";
import {VmSafe} from "forge-std/Vm.sol";

address constant DUMMY_ADDRESS = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

contract StargateStrategyV2Test is BaseStrategy, BaseTest {
    struct AssetData {
        string name;
        address asset;
        address pToken;
    }

    AssetData[] public assetData;

    // Strategy configuration:
    address public constant STARGATE_REWARDER = 0x957b12606690C7692eF92bb5c34a0E63baED99C7;
    address public constant E_TOKEN = 0x6694340fc020c5E6B96567843da2df01b2CE1eb6;
    address public constant STARGATE_FARM = 0x3da4f8E456AC648c489c286B99Ca37B666be7C4C;
    uint16 public constant BASE_DEPOSIT_SLIPPAGE = 20;
    uint16 public constant BASE_WITHDRAW_SLIPPAGE = 20;

    // Test variables
    UpgradeUtil internal upgradeUtil;
    StargateStrategyV2 internal impl;
    StargateStrategyV2 internal strategy;
    address internal proxyAddress;

    // event FarmUpdated(address _newFarm);

    // // Test errors
    // error IncorrectPoolId(address asset, uint16 pid);
    // error IncorrectRewardPoolId(address asset, uint256 rewardPid);
    // error InsufficientRewardFundInFarm();

    function setUp() public virtual override {
        super.setUp();
        setArbitrumFork();

        vm.startPrank(USDS_OWNER);
        // Setup the upgrade params
        impl = new StargateStrategyV2();
        upgradeUtil = new UpgradeUtil();
        proxyAddress = upgradeUtil.deployErc1967Proxy(address(impl));

        // Load strategy object and initialize
        strategy = StargateStrategyV2(proxyAddress);
        _configAsset();
        vm.stopPrank();
    }

    function _initializeStrategy() internal {
        strategy.initialize(STARGATE_REWARDER, VAULT, STARGATE_FARM, BASE_DEPOSIT_SLIPPAGE, BASE_WITHDRAW_SLIPPAGE);
    }

    function _setAssetData() internal {
        for (uint8 i = 0; i < assetData.length; ++i) {
            strategy.setPTokenAddress(assetData[i].asset, assetData[i].pToken);
        }
    }

    function _createDeposits() internal {
        _setAssetData();
        changePrank(VAULT);
        for (uint8 i = 0; i < assetData.length; ++i) {
            uint256 amount = 100;
            amount *= 10 ** ERC20(assetData[i].asset).decimals();
            deal(assetData[i].asset, VAULT, amount, true);
            ERC20(assetData[i].asset).approve(address(strategy), amount);
            strategy.deposit(assetData[i].asset, amount);
        }
    }

    // // Mock Utils:
    // function _mockInsufficientRwd(address asset) internal {
    //     // Do a time travel & mine dummy blocks for accumulating some rewards
    //     vm.warp(block.timestamp + 10 days);
    //     vm.roll(block.number + 1000);

    //     uint256 pendingRewards = strategy.checkPendingRewards(asset);
    //     assert(pendingRewards > 0);

    //     // MOCK: Withdraw rewards from the farm.
    //     changePrank(strategy.farm());
    //     ERC20(E_TOKEN).transfer(actors[0], ERC20(E_TOKEN).balanceOf(strategy.farm()));
    //     changePrank(currentActor);
    // }

    function _configAsset() internal {
        assetData.push(
            AssetData({
                name: "USDT",
                asset: 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9,
                pToken: 0xcE8CcA271Ebc0533920C83d39F417ED6A0abB7D0
            })
        );

        assetData.push(
            AssetData({
                name: "USDC",
                asset: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
                pToken: 0xe8CDF27AcD73a434D661C84887215F7598e7d0d3
            })
        );
    }
}

contract Test_Initialization is StargateStrategyV2Test {
    function test_ValidInitialization() public {
        // Test state variables pre initialization
        assertEq(impl.owner(), address(0));
        assertEq(strategy.owner(), address(0));

        // Initialize strategy
        _initializeStrategy();

        // Test state variables post initialization
        assertEq(impl.owner(), address(0));
        assertEq(strategy.owner(), USDS_OWNER);
        assertEq(strategy.vault(), VAULT);
        assertEq(strategy.rewarder(), STARGATE_REWARDER);
        assertEq(strategy.farm(), STARGATE_FARM);
        assertEq(strategy.depositSlippage(), BASE_DEPOSIT_SLIPPAGE);
        assertEq(strategy.withdrawSlippage(), BASE_WITHDRAW_SLIPPAGE);
        // assertEq(strategy.rewardTokenAddress(0), E_TOKEN); TODO: uncomment after the bug is fixed
    }

    function test_UpdateVaultCore() public useKnownActor(USDS_OWNER) {
        _initializeStrategy();
        address newVault = address(1);
        vm.expectEmit(address(strategy));
        emit VaultUpdated(newVault);
        strategy.updateVault(newVault);
    }
    //updateHarvestIncentiveRate
    //recoverERC20
}

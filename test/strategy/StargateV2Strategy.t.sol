// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {BaseStrategy} from "./BaseStrategy.t.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {UpgradeUtil} from "../utils/UpgradeUtil.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StargateStrategyV2, ILPToken_V2, Helpers} from "../../contracts/strategies/stargateV2/StargateStrategyV2.sol";
import {VmSafe} from "forge-std/Vm.sol";

address constant DUMMY_ADDRESS = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

contract StargateStrategyV2Test is BaseStrategy, BaseTest {
    struct AssetData {
        string name;
        address asset;
        address pool;
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
            strategy.setPTokenAddress(assetData[i].asset, assetData[i].pool);
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
                pool: 0x8D66Ff1845b1baCC6E87D867CA4680d05A349cA8
            })
        );

        assetData.push(
            AssetData({
                name: "USDC",
                asset: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
                pool: 0x6Ea313859A5D9F6fF2a68f529e6361174bFD2225
            })
        );
    }
}

contract Test_Initialization is StargateStrategyV2Test {
    function test_ValidInitialization() public useKnownActor(USDS_OWNER) {
        // Test state variables pre initialization
        assertEq(impl.owner(), address(0));
        assertEq(strategy.owner(), address(0));

        // Initialize strategy
        _initializeStrategy();

        // Test state variables post initialization
        assertEq(impl.owner(), address(0), "Implementation has a valid owner");
        assertEq(strategy.owner(), USDS_OWNER, "Owner is not set correctly");
        assertEq(strategy.vault(), VAULT, "Vault not correct");
        assertEq(strategy.rewarder(), STARGATE_REWARDER, "Rewarder not correct");
        assertEq(strategy.farm(), STARGATE_FARM, "Farm not correct");
        assertEq(strategy.depositSlippage(), BASE_DEPOSIT_SLIPPAGE, "Deposit slippage not correct");
        assertEq(strategy.withdrawSlippage(), BASE_WITHDRAW_SLIPPAGE, "Withdraw slippage not correct");
    }

    function test_InvalidInitialization() public useKnownActor(USDS_OWNER) {
        vm.expectRevert(abi.encodeWithSelector(Helpers.InvalidAddress.selector));
        strategy.initialize(address(0), address(0), STARGATE_FARM, BASE_DEPOSIT_SLIPPAGE, BASE_WITHDRAW_SLIPPAGE);
    }

    function test_UpdateVaultCore() public useKnownActor(USDS_OWNER) {
        _initializeStrategy();

        address newVault = address(1);
        vm.expectEmit(address(strategy));
        emit VaultUpdated(newVault);
        strategy.updateVault(newVault);
    }

    function test_UpdateHarvestIncentiveRate() public useKnownActor(USDS_OWNER) {
        uint16 newRate = 100;
        _initializeStrategy();

        vm.expectEmit(address(strategy));
        emit HarvestIncentiveRateUpdated(newRate);
        strategy.updateHarvestIncentiveRate(newRate);

        newRate = 10001;
        vm.expectRevert(abi.encodeWithSelector(Helpers.GTMaxPercentage.selector, newRate));
        strategy.updateHarvestIncentiveRate(newRate);
    }
}

contract Test_SetPToken is StargateStrategyV2Test {
    function setUp() public override {
        super.setUp();
        vm.startPrank(USDS_OWNER);
        _initializeStrategy();
        vm.stopPrank();
    }

    function test_SetPTokenAddress() public useKnownActor(USDS_OWNER) {
        for (uint8 i = 0; i < assetData.length; ++i) {
            assertEq(strategy.assetToPToken(assetData[i].asset), address(0));
            assertFalse(strategy.supportsCollateral(assetData[i].asset));

            vm.expectEmit(address(strategy));
            emit PTokenAdded(assetData[i].asset, assetData[i].pool);
            strategy.setPTokenAddress(assetData[i].asset, assetData[i].pool);

            assertEq(strategy.assetToPToken(assetData[i].asset), assetData[i].pool);
            assertTrue(strategy.supportsCollateral(assetData[i].asset));
            (uint256 allocatedAmt, address poolAddress) = strategy.assetInfo(assetData[i].asset);
            assertEq(allocatedAmt, 0);
            assertEq(poolAddress, ILPToken_V2(assetData[i].pool).stargate());
        }
    }

    function test_RevertWhen_NotOwner() public {
        AssetData memory data = assetData[0];

        vm.expectRevert("Ownable: caller is not the owner");
        strategy.setPTokenAddress(data.asset, data.pool);
    }

    function test_RevertWhen_InvalidLpToken() public useKnownActor(USDS_OWNER) {
        AssetData memory data = assetData[0];
        data.pool = actors[3];

        vm.expectRevert(abi.encodeWithSelector(StargateStrategyV2.InvalidLpToken.selector, data.pool));
        strategy.setPTokenAddress(data.asset, data.pool);
    }

    function test_RevertWhen_InvalidAssetLpPair() public useKnownActor(USDS_OWNER) {
        AssetData memory data = assetData[0];
        data.pool = assetData[1].pool;

        vm.expectRevert(abi.encodeWithSelector(InvalidAssetLpPair.selector, data.asset, data.pool));
        strategy.setPTokenAddress(data.asset, data.pool);
    }

    function test_RevertWhen_DuplicateAsset() public useKnownActor(USDS_OWNER) {
        AssetData memory data = assetData[0];
        strategy.setPTokenAddress(data.asset, data.pool);

        vm.expectRevert(abi.encodeWithSelector(PTokenAlreadySet.selector, data.asset, data.pool));
        strategy.setPTokenAddress(data.asset, data.pool);
    }
}

contract Test_RemovePToken is StargateStrategyV2Test {
    using stdStorage for StdStorage;

    function setUp() public override {
        super.setUp();
        vm.startPrank(USDS_OWNER);
        _initializeStrategy();
        _setAssetData();
        vm.stopPrank();
    }

    function test_RemovePToken() public useKnownActor(USDS_OWNER) {
        AssetData memory data = assetData[0];
        assertTrue(strategy.supportsCollateral(data.asset));
        vm.expectEmit(address(strategy));
        emit PTokenRemoved(data.asset, data.pool);
        strategy.removePToken(0);
        assertFalse(strategy.supportsCollateral(data.asset));
    }

    function test_RevertWhen_NotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        strategy.removePToken(0);
    }

    function test_RevertWhen_CollateralAllocated() public useKnownActor(USDS_OWNER) {
        AssetData memory data = assetData[0];

        // Mock asset allocation!
        stdstore.target(address(strategy)).sig("assetInfo(address)").with_key(data.asset).depth(0).checked_write(1e18);

        (uint256 allocatedAmt,) = strategy.assetInfo(data.asset);

        assert(allocatedAmt > 0);
        vm.expectRevert(abi.encodeWithSelector(CollateralAllocated.selector, data.asset));
        strategy.removePToken(0);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {IVault} from "contracts/interfaces/IVault.sol";
import {BaseStrategy} from "./BaseStrategy.t.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {UpgradeUtil} from "../utils/UpgradeUtil.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    InitializableAbstractStrategy,
    StargateStrategyV2,
    ILPStaking_V2,
    ILPToken_V2,
    Helpers
} from "../../contracts/strategies/stargateV2/StargateStrategyV2.sol";

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

    event FarmUpdated(address newFarm);
    event RewarderUpdated(address newRewarder);

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
            uint256 amount = 1000;
            amount *= 10 ** ERC20(assetData[i].asset).decimals();
            deal(assetData[i].asset, VAULT, amount, true);
            ERC20(assetData[i].asset).approve(address(strategy), amount);
            strategy.deposit(assetData[i].asset, amount);
        }
    }

    // Mock Utils:
    function _mockInsufficientRwd(address asset) internal {
        // Do a time travel & mine dummy blocks for accumulating some rewards
        vm.warp(block.timestamp + 10 days);
        vm.roll(block.number + 1000);

        (, uint256[] memory pendingRewards) = strategy.checkPendingRewards(asset);
        assert(pendingRewards[0] > 0);

        // MOCK: Withdraw rewards from the farm.
        changePrank(STARGATE_REWARDER);
        ERC20(E_TOKEN).transfer(actors[0], ERC20(E_TOKEN).balanceOf(STARGATE_REWARDER));
        changePrank(currentActor);
    }

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

contract Test_ChangeSlippage is StargateStrategyV2Test {
    uint16 public updatedDepositSlippage = 100;
    uint16 public updatedWithdrawSlippage = 200;

    function setUp() public override {
        super.setUp();
        vm.startPrank(USDS_OWNER);
        _initializeStrategy();
        vm.stopPrank();
    }

    function test_UpdateSlippage() public useKnownActor(USDS_OWNER) {
        vm.expectEmit(address(strategy));
        emit SlippageUpdated(updatedDepositSlippage, updatedWithdrawSlippage);
        strategy.updateSlippage(updatedDepositSlippage, updatedWithdrawSlippage);
        assertEq(strategy.depositSlippage(), updatedDepositSlippage);
        assertEq(strategy.withdrawSlippage(), updatedWithdrawSlippage);
    }

    function test_RevertWhen_NotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        strategy.updateSlippage(updatedDepositSlippage, updatedWithdrawSlippage);
    }

    function test_RevertWhen_slippageExceedsMax() public useKnownActor(USDS_OWNER) {
        vm.expectRevert(abi.encodeWithSelector(Helpers.GTMaxPercentage.selector, 10001));
        strategy.updateSlippage(10001, 10001);
    }
}

contract Test_Deposit is StargateStrategyV2Test {
    function setUp() public override {
        super.setUp();
        vm.startPrank(USDS_OWNER);
        _initializeStrategy();
        _setAssetData();
        vm.stopPrank();
    }

    function testFuzz_Deposit(uint256 amount) public useKnownActor(VAULT) {
        amount = uint256(bound(amount, 1, 1e16));
        for (uint8 i = 0; i < assetData.length; ++i) {
            deal(assetData[i].asset, VAULT, amount, true);
            ERC20(assetData[i].asset).approve(address(strategy), amount);

            vm.expectEmit(address(strategy));
            emit Deposit(assetData[i].asset, amount);
            strategy.deposit(assetData[i].asset, amount);

            assertEq(strategy.checkBalance(assetData[i].asset), amount);
            assertApproxEqAbs(ERC20(assetData[i].asset).balanceOf(address(strategy)), 0, 1);
        }
    }

    function test_RevertWhen_InvalidAmount() public useKnownActor(VAULT) {
        AssetData memory data = assetData[0];
        vm.expectRevert(abi.encodeWithSelector(Helpers.InvalidAmount.selector));
        strategy.deposit(data.asset, 0);
    }

    function test_RevertWhen_UnsupportedCollateral() public useKnownActor(VAULT) {
        AssetData memory data = assetData[0];
        uint256 amount = 1000000;

        // Remove the asset for testing unsupported collateral.
        changePrank(USDS_OWNER);
        strategy.removePToken(0);

        changePrank(VAULT);
        amount *= 10 ** ERC20(data.asset).decimals();
        deal(data.asset, VAULT, amount, true);
        ERC20(data.asset).approve(address(strategy), amount);

        vm.expectRevert(abi.encodeWithSelector(CollateralNotSupported.selector, data.asset));
        strategy.deposit(data.asset, amount);
    }
}

contract Test_Harvest is StargateStrategyV2Test {
    address public yieldReceiver;

    function setUp() public override {
        super.setUp();
        vm.startPrank(USDS_OWNER);
        _initializeStrategy();
        yieldReceiver = IVault(VAULT).yieldReceiver();
        // Mock Vault yieldReceiver function
        vm.mockCall(VAULT, abi.encodeWithSignature("yieldReceiver()"), abi.encode(yieldReceiver));
        _createDeposits();
        vm.stopPrank();
    }
}

contract Test_CollectReward is Test_Harvest {
    function test_CollectReward(uint16 _harvestIncentiveRate) public {
        _harvestIncentiveRate = uint16(bound(_harvestIncentiveRate, 0, 10000));
        vm.prank(USDS_OWNER);
        strategy.updateHarvestIncentiveRate(_harvestIncentiveRate);

        // Do a time travel & mine dummy blocks for accumulating some rewards
        vm.warp(block.timestamp + 10 days);
        vm.roll(block.number + 1000);

        StargateStrategyV2.RewardData[] memory currentRewards = strategy.checkRewardEarned();
        assertTrue(currentRewards[0].amount > 0, "Rewards not accrued");
        uint256 incentiveAmt = (currentRewards[0].amount * _harvestIncentiveRate) / Helpers.MAX_PERCENTAGE;
        uint256 harvestAmt = currentRewards[0].amount - incentiveAmt;
        address caller = actors[1];

        if (incentiveAmt > 0) {
            vm.expectEmit(address(strategy));
            emit HarvestIncentiveCollected(E_TOKEN, caller, incentiveAmt);
        }
        vm.expectEmit(address(strategy));
        emit RewardTokenCollected(E_TOKEN, yieldReceiver, harvestAmt);
        vm.prank(caller);
        strategy.collectReward();

        assertEq(ERC20(E_TOKEN).balanceOf(yieldReceiver), harvestAmt, "Yield receiver didn't receive rewards");
        assertEq(ERC20(E_TOKEN).balanceOf(caller), incentiveAmt, "Caller didn't receive rewards");

        currentRewards = strategy.checkRewardEarned();
        assert(currentRewards[0].amount == 0);
    }
}

contract Test_CollectInterest is Test_Harvest {
    using stdStorage for StdStorage;

    function test_CollectInterest() public {
        for (uint8 i = 0; i < assetData.length; ++i) {
            uint256 initialLPBal = strategy.checkLPTokenBalance(assetData[i].asset);
            uint256 interestAmt = 10 * 10 ** ERC20(assetData[i].pool).decimals();
            uint256 mockBal = initialLPBal + interestAmt;

            uint256 initialBal = strategy.checkBalance(assetData[i].asset);
            uint256 initialAvailableBal = strategy.checkAvailableBalance(assetData[i].asset);

            // Mock asset allocation!
            vm.mockCall(
                assetData[i].pool,
                abi.encodeWithSignature("redeemable(address)", address(strategy)),
                abi.encode(mockBal)
            );
            vm.mockCall(
                STARGATE_FARM,
                abi.encodeWithSignature("balanceOf(address,address)", assetData[i].pool, address(strategy)),
                abi.encode(mockBal)
            );

            assertEq(
                strategy.checkAvailableBalance(assetData[i].asset), initialAvailableBal, "Initial balance mismatch"
            );
            uint256 interestEarned = strategy.checkInterestEarned(assetData[i].asset);
            assertEq(strategy.checkBalance(assetData[i].asset), initialBal, "Initial balance mismatch");
            assertEq(strategy.checkLPTokenBalance(assetData[i].asset), mockBal, "LP token bal not mocked");
            assertTrue(interestEarned > 0, "No interest earned");

            uint256 incentiveAmt = (interestEarned * strategy.harvestIncentiveRate()) / 10000;
            interestEarned = interestEarned - incentiveAmt;

            vm.expectEmit(true, true, true, true, address(strategy));
            emit InterestCollected(assetData[i].asset, yieldReceiver, interestEarned); // used vm.recordLogs to test the interestEarned part due to precision error

            vm.recordLogs();

            strategy.collectInterest(assetData[i].asset);
            vm.clearMockedCalls();
            assertApproxEqAbs(strategy.checkInterestEarned(assetData[i].asset), 0, 1);

            // @note Subtracting interest amount because of mocked call used earlier.
            assertApproxEqAbs(strategy.checkLPTokenBalance(assetData[i].asset), initialLPBal - interestAmt, 1);
        }
    }

    function test_RevertWhen_UnsupportedAsset() public {
        vm.expectRevert(abi.encodeWithSelector(CollateralNotSupported.selector, address(0)));
        strategy.collectInterest(address(0));
    }
}

contract Test_Withdraw is StargateStrategyV2Test {
    using stdStorage for StdStorage;

    function setUp() public override {
        super.setUp();
        vm.startPrank(USDS_OWNER);
        _initializeStrategy();
        _createDeposits();
        vm.stopPrank();
    }

    function test_Withdraw() public useKnownActor(VAULT) {
        for (uint8 i = 0; i < assetData.length; ++i) {
            ERC20 collateral = ERC20(assetData[i].asset);
            uint256 initialBal = strategy.checkBalance(assetData[i].asset);
            uint256 initialVaultBal = collateral.balanceOf(VAULT);

            vm.expectEmit(true, true, true, true);
            emit Withdrawal(assetData[i].asset, initialBal);

            uint256 amt = strategy.withdraw(VAULT, assetData[i].asset, initialBal);

            assertEq(amt, initialBal);

            assertEq(collateral.balanceOf(VAULT), initialVaultBal + initialBal);
        }
    }

    function test_RevertWhen_CallerNotVault() public useActor(0) {
        vm.expectRevert(abi.encodeWithSelector(CallerNotVault.selector, actors[0]));
        strategy.withdraw(VAULT, assetData[0].asset, 1);
    }

    function test_withdraw_InvalidAddress() public useKnownActor(VAULT) {
        vm.expectRevert(abi.encodeWithSelector(Helpers.InvalidAddress.selector));
        strategy.withdraw(address(0), assetData[0].asset, 1);
    }

    function test_RevertWhen_CollateralNotSupported() public useKnownActor(VAULT) {
        vm.expectRevert(abi.encodeWithSelector(CollateralNotSupported.selector, actors[4]));
        strategy.withdraw(VAULT, actors[4], 1); // invalid asset
    }

    function test_WithdrawToVault() public useKnownActor(USDS_OWNER) {
        for (uint8 i = 0; i < assetData.length; ++i) {
            ERC20 collateral = ERC20(assetData[i].asset);
            uint256 initialBal = strategy.checkBalance(assetData[i].asset);
            uint256 initialVaultBal = collateral.balanceOf(VAULT);

            vm.expectEmit(true, true, true, true);
            emit Withdrawal(assetData[i].asset, initialBal);

            uint256 amt = strategy.withdrawToVault(assetData[i].asset, initialBal);

            assertEq(amt, initialBal);

            assertEq(collateral.balanceOf(VAULT), initialVaultBal + initialBal);
        }
    }

    function test_RevertWhen_Withdraw0() public useKnownActor(USDS_OWNER) {
        AssetData memory data = assetData[0];
        vm.expectRevert(abi.encodeWithSelector(Helpers.InvalidAmount.selector));
        strategy.withdrawToVault(data.asset, 0);
    }

    function test_RevertWhen_InsufficientRwdInFarm() public useKnownActor(USDS_OWNER) {
        AssetData memory data = assetData[0];
        uint256 initialBal = strategy.checkBalance(data.asset);

        _mockInsufficientRwd(data.asset);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        strategy.withdrawToVault(data.asset, initialBal);
    }

    function test_RevertWhen_EnoughFundsNotAvailable() public useKnownActor(USDS_OWNER) {
        AssetData memory data = assetData[0];
        uint256 initialBal = strategy.checkBalance(data.asset);

        vm.warp(block.timestamp + 10 days);
        vm.roll(block.number + 1000);

        uint256 initialAvailableBal = strategy.checkAvailableBalance(data.asset);

        address _pool = ILPToken_V2(data.pool).stargate();
        // mock scenario for stargate pool reverting with not enough funds redeemable
        vm.mockCall(
            _pool, abi.encodeWithSignature("redeem(uint256,address)", initialBal, strategy.vault()), abi.encode(0)
        );
        vm.mockCall(_pool, abi.encodeWithSignature("redeemable(address)", address(0)), abi.encode(0));

        assertTrue(strategy.checkAvailableBalance(data.asset) < initialAvailableBal);

        vm.expectRevert(
            abi.encodeWithSelector(
                Helpers.MinSlippageError.selector,
                0,
                (initialBal * (Helpers.MAX_PERCENTAGE - uint128(strategy.withdrawSlippage()))) / Helpers.MAX_PERCENTAGE
            )
        );
        strategy.withdrawToVault(data.asset, initialBal);
    }
}

contract Test_EmergencyWithdrawToVault is StargateStrategyV2Test {
    function setUp() public override {
        super.setUp();
        vm.startPrank(USDS_OWNER);
        _initializeStrategy();
        _createDeposits();
        vm.stopPrank();
    }

    function test_emergencyWithdrawToVault() public useKnownActor(USDS_OWNER) {
        for (uint8 i = 0; i < assetData.length; ++i) {
            uint256 initialBal = strategy.checkBalance(assetData[i].asset);
            uint256 initialVaultBal = ERC20(assetData[i].asset).balanceOf(VAULT);

            (uint256 allocatedAmtBeforeEmergencyWithdraw,) = strategy.assetInfo(assetData[i].asset);

            vm.expectEmit(address(strategy));
            emit Withdrawal(assetData[i].asset, initialBal);
            strategy.emergencyWithdrawToVault(assetData[i].asset);

            (uint256 allocatedAmtAfterEmergencyWithdraw,) = strategy.assetInfo(assetData[i].asset);

            assertEq(strategy.checkLPTokenBalance(assetData[i].asset), 0);
            assertEq(strategy.checkBalance(assetData[i].asset), 0);
            assertEq(allocatedAmtAfterEmergencyWithdraw, allocatedAmtBeforeEmergencyWithdraw - initialBal);
            assertEq(ERC20(assetData[i].asset).balanceOf(VAULT), initialVaultBal + initialBal);
        }
    }
}

contract Test_RecoverERC20 is StargateStrategyV2Test {
    address token;
    address receiver;
    uint256 amount;

    function setUp() public override {
        super.setUp();
        vm.startPrank(USDS_OWNER);
        _initializeStrategy();
        _createDeposits();
        vm.stopPrank();
        token = DAI;
        receiver = actors[1];
        amount = 1000 * 10 ** ERC20(token).decimals();
    }

    function test_RevertWhen_CallerIsNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        strategy.recoverERC20(token, receiver, amount);
    }

    function test_RevertWhen_AmountMoreThanBalance() public useKnownActor(USDS_OWNER) {
        vm.expectRevert();
        strategy.recoverERC20(token, receiver, amount);
    }

    function test_RecoverERC20() public useKnownActor(USDS_OWNER) {
        deal(token, address(strategy), amount);
        uint256 balBefore = ERC20(token).balanceOf(receiver);
        strategy.recoverERC20(token, receiver, amount);
        uint256 balAfter = ERC20(token).balanceOf(receiver);
        assertEq(balAfter - balBefore, amount);
    }
}

contract Test_UpdateFarm is StargateStrategyV2Test {
    address _newFarm;

    function setUp() public override {
        super.setUp();
        vm.startPrank(USDS_OWNER);
        _initializeStrategy();
        _createDeposits();
        vm.stopPrank();
        _newFarm = STARGATE_FARM; // As there is only one farm to test
    }

    function test_RevertWhen_CallerIsNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        strategy.updateFarm(_newFarm);
    }

    function test_RevertWhen_InvalidAddress() public useKnownActor(USDS_OWNER) {
        vm.expectRevert(Helpers.InvalidAddress.selector);
        strategy.updateFarm(address(0));
    }

    function test_UpdateFarm() public useKnownActor(USDS_OWNER) {
        uint256 _length = assetData.length;
        uint256[] memory oldFarmBalances = new uint256[](_length);
        uint256[] memory newFarmBalances = new uint256[](_length);
        for (uint8 i = 0; i < _length; ++i) {
            oldFarmBalances[i] = ILPStaking_V2(STARGATE_FARM).balanceOf(assetData[i].pool, address(strategy));
        }
        vm.expectEmit(address(strategy));
        emit FarmUpdated(_newFarm);
        strategy.updateFarm(_newFarm);

        assertEq(strategy.farm(), STARGATE_FARM);
        for (uint8 i = 0; i < assetData.length; ++i) {
            newFarmBalances[i] = ILPStaking_V2(STARGATE_FARM).balanceOf(assetData[i].pool, address(strategy));
            assertEq(oldFarmBalances[i], newFarmBalances[i], "Mismatch in balance");
        }
    }
}

contract Test_UpdateRewarder is StargateStrategyV2Test {
    address _newRewarder;

    function setUp() public override {
        super.setUp();
        vm.startPrank(USDS_OWNER);
        _initializeStrategy();
        _createDeposits();
        vm.stopPrank();
        _newRewarder = actors[1]; // Setting another address
    }

    function test_RevertWhen_CallerIsNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        strategy.updateFarm(_newRewarder);
    }

    function test_RevertWhen_InvalidAddress() public useKnownActor(USDS_OWNER) {
        vm.expectRevert(Helpers.InvalidAddress.selector);
        strategy.updateRewarder(address(0));
    }

    function test_UpdateRewarder() public useKnownActor(USDS_OWNER) {
        vm.expectEmit(address(strategy));
        emit RewarderUpdated(_newRewarder);
        strategy.updateRewarder(_newRewarder);

        assertEq(strategy.rewarder(), _newRewarder);
    }
}

contract Test_Miscellaneous is StargateStrategyV2Test {
    function test_checkPendingRewards_revertWhen_UnsupportedCollateral() public {
        vm.expectRevert(
            abi.encodeWithSelector(InitializableAbstractStrategy.CollateralNotSupported.selector, actors[2])
        );
        strategy.checkPendingRewards(actors[2]);
    }

    function test_checkBalance_lpTokenBal_lt_allocatedAmt() public {
        _initializeStrategy();
        _createDeposits();
        AssetData memory data = assetData[0];
        uint256 initialBal = strategy.checkBalance(data.asset);
        uint256 mockBal = initialBal - 1e6;
        vm.mockCall(
            STARGATE_FARM,
            abi.encodeWithSignature("balanceOf(address,address)", data.pool, address(strategy)),
            abi.encode(mockBal)
        );
        uint256 mockedBal = strategy.checkBalance(data.asset);
        assertEq(mockBal, mockedBal, "Balance not mocked");
        assertTrue(mockedBal < initialBal, "mocked balance is greater");
    }
}

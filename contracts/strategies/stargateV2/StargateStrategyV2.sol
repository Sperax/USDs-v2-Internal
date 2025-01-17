pragma solidity 0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {InitializableAbstractStrategy, Helpers, IStrategyVault} from "../InitializableAbstractStrategy.sol";
import {ILPool} from "./interfaces/ILPool.sol";
import {ILPStaking} from "./interfaces/ILPStaking.sol";
import {ILPToken} from "./interfaces/ILPToken.sol";
import {ILPRewarder} from "./interfaces/ILPRewarder.sol";

contract StargateStrategyV2 is InitializableAbstractStrategy {
    using SafeERC20 for IERC20;

    struct AssetInfo {
        uint256 allocatedAmt; // tracks the allocated amount for an asset.
        address poolAddress; // maps pool address of a specific asset
    }

    address public rewarder; // Address of the Stargate rewarder contract
    address public farm; // Address of the Stargate staking contract (LPStaking)
    mapping(address => AssetInfo) public assetInfo;

    // Custom errors
    error InvalidLpToken(address lpToken);

    function initialize(
        address _rewarder,
        address _vault,
        address _farm,
        uint16 _depositSlippage, // 200 = 2%
        uint16 _withdrawSlippage // 200 = 2%
    ) external initializer {
        Helpers._isNonZeroAddr(_rewarder);
        Helpers._isNonZeroAddr(_farm);
        rewarder = _rewarder;
        farm = _farm;

        InitializableAbstractStrategy._initialize(_vault, _depositSlippage, _withdrawSlippage);
    }

    /// @notice Provide support for asset by passing its pToken address.
    ///      This method can only be called by the system owner
    /// @param _asset    Address for the asset
    /// @param _lpToken   Address for the corresponding platform token

    function setPTokenAddress(address _asset, address _lpToken) external onlyOwner {
        if (!ILPStaking(farm).isPool(_lpToken)) {
            revert InvalidLpToken(_lpToken);
        }
        // Save the pool address for the asset
        assetInfo[_asset] = AssetInfo({allocatedAmt: 0, poolAddress: ILPToken(_lpToken).stargate()});

        address pool = assetInfo[_asset].poolAddress;
        if (ILPool(pool).token() != _asset && ILPool(pool).lpToken() != _lpToken) {
            revert InvalidAssetLpPair(_asset, _lpToken);
        }
        _setPTokenAddress(_asset, _lpToken);
    }

    /// @dev Remove a supported asset by passing its index.
    ///       This method can only be called by the system owner
    ///  @param _assetIndex Index of the asset to be removed
    function removePToken(uint256 _assetIndex) external onlyOwner {
        address asset = _removePTokenAddress(_assetIndex);
        if (assetInfo[asset].allocatedAmt != 0) {
            revert CollateralAllocated(asset);
        }
        delete assetInfo[asset];
    }

    /// @inheritdoc InitializableAbstractStrategy
    function deposit(address _asset, uint256 _amount) external override onlyVault nonReentrant {
        Helpers._isNonZeroAmt(_amount);
        if (!supportsCollateral(_asset)) revert CollateralNotSupported(_asset);

        AssetInfo storage asset = assetInfo[_asset];
        address lpToken = assetToPToken[_asset];
        address pool = asset.poolAddress;
        IERC20(_asset).forceApprove(pool, _amount);
        ILPool(pool).deposit(msg.sender, _amount);

        // Checking the slippage
        uint256 minDepositAmt = (_amount * (Helpers.MAX_PERCENTAGE - depositSlippage)) / Helpers.MAX_PERCENTAGE;
        if (_amount < minDepositAmt) {
            revert Helpers.MinSlippageError(_amount, minDepositAmt);
        }
        // Update the allocated amount in the strategy
        asset.allocatedAmt += _amount;
        // Deposit the generated lpToken in the farm.
        // @dev We are assuming that the 100% of lpToken is deposited in the farm and LPToken = Asset Price
        IERC20(lpToken).forceApprove(farm, _amount);
        ILPStaking(farm).deposit(lpToken, _amount);
        emit Deposit(_asset, _amount);
    }

    /// @inheritdoc InitializableAbstractStrategy
    function withdraw(address _recipient, address _asset, uint256 _amount)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256)
    {
        return _withdraw(false, _recipient, _asset, _amount);
    }

    /// @inheritdoc InitializableAbstractStrategy
    function withdrawToVault(address _asset, uint256 _amount)
        external
        override
        onlyOwner
        nonReentrant
        returns (uint256)
    {
        return _withdraw(false, vault, _asset, _amount);
    }

    /// @notice Function to withdraw position from LPStaking
    /// @dev Useful when there are not enough rewards in the pool
    /// @param _asset Asset to withdraw
    //! There is an emergencyWithdraw function on staking contract but it sends the funds to the owner
    function emergencyWithdrawToVault(address _asset) external onlyOwner nonReentrant {
        uint256 lpTokenAmt = checkLPTokenBalance(_asset);
        ILPStaking(farm).emergencyWithdraw(assetToPToken[_asset]);
        assetInfo[_asset].allocatedAmt -= lpTokenAmt;
        emit Withdrawal(_asset, lpTokenAmt);
    }

    /// @inheritdoc InitializableAbstractStrategy
    function collectInterest(address _asset) external override nonReentrant {
        address yieldReceiver = IStrategyVault(vault).yieldReceiver();
        uint256 earnedInterest = checkInterestEarned(_asset);
        if (earnedInterest != 0) {
            uint256 interestCollected = _withdraw(true, address(this), _asset, earnedInterest);
            uint256 harvestAmt = _splitAndSendReward(_asset, yieldReceiver, msg.sender, interestCollected);
            emit InterestCollected(_asset, yieldReceiver, harvestAmt);
        }
    }

    /// @inheritdoc InitializableAbstractStrategy
    function collectReward() external override nonReentrant {
        address yieldReceiver = IStrategyVault(vault).yieldReceiver();
        uint256 numAssets = assetsMapped.length;
        for (uint256 i; i < numAssets;) {
            address asset = assetsMapped[i];
            (address[] memory rewardTokens, uint256[] memory pendingRewards) = checkPendingRewards(asset);
            rewardTokenAddress = rewardTokens;
            uint256 rewardAmt = pendingRewards[0];
            if (rewardAmt != 0) {
                ILPStaking(farm).claim(assetToPToken[asset]);
            }
            for (uint256 j; j < rewardTokens.length; j++) {
                uint256 rewardEarned = IERC20(rewardTokens[j]).balanceOf(address(this));
                if (rewardEarned != 0) {
                    uint256 harvestAmt = _splitAndSendReward(rewardTokens[j], yieldReceiver, msg.sender, rewardEarned);
                    emit RewardTokenCollected(rewardTokens[j], yieldReceiver, harvestAmt);
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }
    /// @inheritdoc InitializableAbstractStrategy
    // TODO update the logic with multiple reward tokens

    function checkRewardEarned() external view override returns (RewardData[] memory) {
        // uint256 pendingRewards = 0;
        // uint256 numAssets = assetsMapped.length;
        // for (uint256 i; i < numAssets;) {
        //     address asset = assetsMapped[i];
        //     pendingRewards += ILPStaking(farm).pendingEmissionToken(assetInfo[asset].rewardPID, address(this));
        //     unchecked {
        //         ++i;
        //     }
        // }
        // // uint256 claimedRewards = IERC20(rewardTokenAddress[0]).balanceOf(address(this));
        // RewardData[] memory rewardData = new RewardData[](1);
        // rewardData[0] = RewardData(rewardTokenAddress[0], claimedRewards + pendingRewards);
        // return rewardData;
    }

    /// @inheritdoc InitializableAbstractStrategy
    function supportsCollateral(address _asset) public view override returns (bool) {
        return assetToPToken[_asset] != address(0);
    }

    /// @notice Get the amount pending Rewards to be collected.
    /// @param _asset Address for the asset
    /// @return Amount of pending Rewards to be collected.
    function checkPendingRewards(address _asset) public view returns (address[] memory, uint256[] memory) {
        if (!supportsCollateral(_asset)) revert CollateralNotSupported(_asset);
        (address[] memory rewardAddresses, uint256[] memory rewardAmounts) =
            ILPRewarder(rewarder).getRewards(assetToPToken[_asset], address(this));
        return (rewardAddresses, rewardAmounts);
    }

    /// @inheritdoc InitializableAbstractStrategy
    //TODO  @dev lpTokenBal = Asset balance since it's 1:1
    function checkInterestEarned(address _asset) public view override returns (uint256) {
        uint256 lpTokenBal = checkLPTokenBalance(_asset);
        uint256 allocatedAmt = assetInfo[_asset].allocatedAmt;
        if (lpTokenBal <= allocatedAmt) {
            return 0;
        }
        return lpTokenBal - allocatedAmt;
    }

    /// @inheritdoc InitializableAbstractStrategy
    function checkBalance(address _asset) public view override returns (uint256) {
        uint256 lpTokenBal = checkLPTokenBalance(_asset);
        uint256 allocatedAmt = assetInfo[_asset].allocatedAmt;
        if (allocatedAmt <= lpTokenBal) {
            return allocatedAmt;
        }
        return lpTokenBal;
    }

    /// @inheritdoc InitializableAbstractStrategy
    // TODO Check the logic behind LP token withdrawal from the pool
    function checkAvailableBalance(address _asset) public view override returns (uint256) {
        address pool = assetInfo[_asset].poolAddress;
        uint256 availableFunds = ILPool(pool).redeemable(address(this));
        uint256 allocatedAmt = assetInfo[_asset].allocatedAmt;
        if (availableFunds <= allocatedAmt) {
            return availableFunds;
        }
        return allocatedAmt;
    }

    /// @inheritdoc InitializableAbstractStrategy
    function checkLPTokenBalance(address _asset) public view override returns (uint256) {
        if (!supportsCollateral(_asset)) revert CollateralNotSupported(_asset);
        uint256 lpTokenStaked = ILPStaking(farm).balanceOf(assetToPToken[_asset], address(this));
        return lpTokenStaked;
    }

    /// @inheritdoc InitializableAbstractStrategy
    /* solhint-disable no-empty-blocks */
    function _abstractSetPToken(address _asset, address _pToken) internal override {}

    /* solhint-enable no-empty-blocks */

    /// @notice Helper function for withdrawal.
    /// @param _withdrawInterest Withdraws interest as well if this is set to `true`
    /// @param _recipient Recipient of the amount
    /// @param _asset Address of the asset token
    /// @param _amount Amount to be withdrawn
    /// @return Amount withdrawn
    /// @dev Validate if the farm has enough STG to withdraw as rewards.
    /// @dev It is designed to be called from functions with the `nonReentrant` modifier to ensure reentrancy protection.
    function _withdraw(bool _withdrawInterest, address _recipient, address _asset, uint256 _amount)
        private
        returns (uint256)
    {
        Helpers._isNonZeroAddr(_recipient);
        Helpers._isNonZeroAmt(_amount, "Must withdraw something");
        if (!supportsCollateral(_asset)) revert CollateralNotSupported(_asset);

        AssetInfo storage asset = assetInfo[_asset];
        address lpToken = assetToPToken[_asset];
        ILPStaking(farm).withdraw(lpToken, _amount);

        uint256 minRecvAmt = (_amount * (Helpers.MAX_PERCENTAGE - withdrawSlippage)) / Helpers.MAX_PERCENTAGE;
        if (_amount < minRecvAmt) {
            revert Helpers.MinSlippageError(_amount, minRecvAmt);
        }
        ILPool(asset.poolAddress).redeem(_amount, _recipient);
        if (!_withdrawInterest) {
            asset.allocatedAmt -= _amount;
            emit Withdrawal(_asset, _amount);
        }

        return _amount;
    }
}

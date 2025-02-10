pragma solidity 0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {InitializableAbstractStrategy, Helpers, IStrategyVault} from "../InitializableAbstractStrategy.sol";
import {ILPool_V2} from "./interfaces/ILPool_V2.sol";
import {ILPStaking_V2} from "./interfaces/ILPStaking_V2.sol";
import {ILPToken_V2} from "./interfaces/ILPToken_V2.sol";
import {ILPRewarder_V2} from "./interfaces/ILPRewarder_V2.sol";

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

    /**
     * @notice Initializes the StargateStrategyV2 contract with the given parameters.
     * @dev This function is an initializer and can only be called once.
     * @param _rewarder The address of the rewarder contract.
     * @param _vault The address of the vault contract.
     * @param _farm The address of the farm contract.
     * @param _depositSlippage The slippage percentage for deposits (e.g., 200 = 2%).
     * @param _withdrawSlippage The slippage percentage for withdrawals (e.g., 200 = 2%).
     */
    function initialize(
        address _rewarder,
        address _vault,
        address _farm,
        address _eToken,
        uint16 _depositSlippage, // 200 = 2%
        uint16 _withdrawSlippage // 200 = 2%
    ) external initializer {
        Helpers._isNonZeroAddr(_rewarder);
        Helpers._isNonZeroAddr(_farm);
        rewarder = _rewarder;
        farm = _farm;
        // register reward token
        rewardTokenAddress.push(_eToken);

        InitializableAbstractStrategy._initialize(_vault, _depositSlippage, _withdrawSlippage);
    }

    /// @notice Provide support for asset by passing its pToken address.
    ///      This method can only be called by the system owner
    /// @param _asset    Address for the asset
    /// @param _lpToken   Address for the corresponding platform token
    function setPTokenAddress(address _asset, address _lpToken) external onlyOwner {
        if (!ILPStaking_V2(farm).isPool(_lpToken)) {
            revert InvalidLpToken(_lpToken);
        }
        // Save the pool address for the asset
        _setPTokenAddress(_asset, _lpToken);
        assetInfo[_asset] = AssetInfo({allocatedAmt: 0, poolAddress: ILPToken_V2(_lpToken).stargate()});
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

        AssetInfo storage assetPointer = assetInfo[_asset];
        address lpToken = _getPTokenFor(_asset);
        address pool = assetPointer.poolAddress;
        IERC20(_asset).forceApprove(pool, _amount);
        ILPool_V2(pool).deposit(msg.sender, _amount);
        //*check redeemable function need to check it with LPToken Balance and allocatedAmt
        // Update the allocated amount in the strategy
        assetPointer.allocatedAmt += _amount;
        // Deposit the generated lpToken in the farm.
        // @dev We are assuming that the 100% of lpToken is deposited in the farm and LPToken = Asset Price
        IERC20(lpToken).forceApprove(farm, _amount);
        ILPStaking_V2(farm).deposit(lpToken, _amount);
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
    function emergencyWithdrawToVault(address _asset) external onlyOwner nonReentrant {
        uint256 lpTokenAmt = checkLPTokenBalance(_asset);
        ILPStaking_V2(farm).emergencyWithdraw(_getPTokenFor(_asset));

        assetInfo[_asset].allocatedAmt -= lpTokenAmt;

        ILPool_V2(assetInfo[_asset].poolAddress).redeem(lpTokenAmt, vault);

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
        uint256 rwdTokenLength = rewardTokenAddress.length;

        for (uint256 i; i < numAssets;) {
            address asset = assetsMapped[i];
            address[] memory pTokenAddress = new address[](1);
            pTokenAddress[0] = _getPTokenFor(asset);
            (address[] memory rewardTokens, uint256[] memory pendingRewards) = checkPendingRewards(asset);
            uint256 rewardAmt = pendingRewards[0];
            if (rewardAmt != 0) {
                ILPStaking_V2(farm).claim(pTokenAddress);
            }
            for (uint256 j; j < rwdTokenLength;) {
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
        uint256 pendingRewards = 0;
        uint256 numAssets = assetsMapped.length;
        for (uint256 i; i < numAssets;) {
            address asset = assetsMapped[i];
            (, uint256[] memory rewardAmounts) = ILPRewarder_V2(rewarder).getRewards(asset, address(this));
            pendingRewards += rewardAmounts[0];
            unchecked {
                ++i;
            }
        }
        uint256 claimedRewards = IERC20(rewardTokenAddress[0]).balanceOf(address(this));
        RewardData[] memory rewardData = new RewardData[](1);
        rewardData[0] = RewardData(rewardTokenAddress[0], claimedRewards + pendingRewards);
        return rewardData;
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
            ILPRewarder_V2(rewarder).getRewards(_getPTokenFor(_asset), address(this));
        return (rewardAddresses, rewardAmounts);
    }

    /// @inheritdoc InitializableAbstractStrategy
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
    function checkAvailableBalance(address _asset) public view override returns (uint256) {
        address pool = assetInfo[_asset].poolAddress;
        uint256 availableFunds = ILPool_V2(pool).redeemable(address(this));
        uint256 allocatedAmt = assetInfo[_asset].allocatedAmt;
        if (availableFunds <= allocatedAmt) {
            return availableFunds;
        }
        return allocatedAmt;
    }

    /// @inheritdoc InitializableAbstractStrategy
    function checkLPTokenBalance(address _asset) public view override returns (uint256) {
        if (!supportsCollateral(_asset)) revert CollateralNotSupported(_asset);
        uint256 lpTokenStaked = ILPStaking_V2(farm).balanceOf(assetToPToken[_asset], address(this));
        return lpTokenStaked;
    }

    /// @inheritdoc InitializableAbstractStrategy
    /* solhint-disable no-empty-blocks */
    function _abstractSetPToken(address _asset, address _pToken) internal view override {
        address pool = ILPToken_V2(_pToken).stargate();
        if (ILPool_V2(pool).token() != _asset && ILPool_V2(pool).lpToken() != _pToken) {
            revert InvalidAssetLpPair(_asset, _pToken);
        }
    }

    function _getPTokenFor(address _asset) internal view returns (address) {
        address lpToken = assetToPToken[_asset];
        if (lpToken == address(0)) revert CollateralNotSupported(_asset);
        return lpToken;
    }

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
        ILPStaking_V2(farm).withdraw(lpToken, _amount);

        uint256 lpTokenBurned = ILPool_V2(asset.poolAddress).redeem(_amount, _recipient);

        uint256 minRecvAmt = (_amount * (Helpers.MAX_PERCENTAGE - withdrawSlippage)) / Helpers.MAX_PERCENTAGE;
        if (lpTokenBurned < minRecvAmt) {
            revert Helpers.MinSlippageError(lpTokenBurned, minRecvAmt);
        }
        if (!_withdrawInterest) {
            asset.allocatedAmt -= _amount;
            emit Withdrawal(_asset, lpTokenBurned);
        }

        return lpTokenBurned;
    }
}

pragma solidity 0.8.19;

interface ILPRewarder_V2 {
    function getRewards(address lpToken, address user) external view returns (address[] memory, uint256[] memory);
    function rewardTokens() external view returns (address[] memory);
}
